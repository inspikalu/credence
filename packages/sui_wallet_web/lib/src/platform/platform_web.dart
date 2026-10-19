import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import '../backend.dart';
import '../errors.dart';
import '../generated/js_sources.g.dart';
import '../models.dart';
import 'dom_web.dart';

@JS('__suiWalletWeb')
external _Bridge? get _bridge;

extension type _Bridge._(JSObject _) implements JSObject {
  external JSArray<JSAny?> list();
  external JSFunction subscribe(JSFunction listener);
  external JSPromise<_Result> connect(String id, bool silent);
  external JSPromise<_Result> disconnect(String id);
  external JSPromise<_Result> signPersonalMessage(
    String id,
    String address,
    JSUint8Array message,
    String? chain,
  );

  /// Absent from bridges older than version 2 that a page may still load
  /// through a script tag.
  external JSFunction? get signAndExecuteTransaction;
  external JSFunction? get signTransaction;
  external JSPromise<_Result> withTransactionLock(
    String name,
    JSFunction action,
  );
}

extension type _Result._(JSObject _) implements JSObject {
  external bool get ok;
  external JSAny? get value;
  external _ErrorInfo? get error;
}

extension type _ErrorInfo._(JSObject _) implements JSObject {
  external String? get name;
  external String? get message;
  external String? get code;
}

const _bridgeScriptId = 'sui-wallet-web-bridge';

/// Path of the bridge inside the app's assets (for CSP-friendly loading).
const bridgeAssetKey = 'packages/sui_wallet_web/js/sui_wallet_standard.js';

/// Loads the Wallet Standard bridge if the page has not already.
///
/// Inline injection runs synchronously. If a Content-Security-Policy blocks
/// inline scripts, the bundled asset is loaded instead (or include it in
/// `web/index.html` yourself).
void ensureBridgeLoaded({void Function()? onLateLoad}) {
  if (_bridge != null) return;
  try {
    injectInlineScript(suiWalletStandardJs, id: _bridgeScriptId);
  } catch (_) {
    // Fall through to the asset.
  }
  if (_bridge != null) return;
  try {
    injectScriptUrl(
      ui_web.assetManager.getAssetUrl(bridgeAssetKey),
      id: '$_bridgeScriptId-asset',
      onLoad: onLateLoad,
    );
  } catch (_) {
    // No wallets then; the picker shows the install link.
  }
}

SuiWalletBackend createDefaultBackend() => WalletStandardBackend();

SuiWalletStorage createDefaultStorage() => LocalStorageSuiWalletStorage();

SuiWalletTransactionLock createDefaultTransactionLock() =>
    BrowserSuiWalletTransactionLock();

class BrowserSuiWalletTransactionLock implements SuiWalletTransactionLock {
  @override
  Future<T> run<T>(String name, Future<T> Function() action) async {
    ensureBridgeLoaded();
    final bridge = _bridge;
    if (bridge == null) {
      throw const SuiWalletException(
        SuiWalletErrorKind.unavailable,
        'Reload this page before approving a transaction.',
        definitelyNotSubmitted: true,
      );
    }
    late T value;
    Object? failure;
    StackTrace? stack;
    Future<JSAny?> invoke() async {
      try {
        value = await action();
      } catch (error, trace) {
        failure = error;
        stack = trace;
      }
      return null;
    }

    final result = await bridge
        .withTransactionLock(name, (() => invoke().toJS).toJS)
        .toDart;
    if (!result.ok) {
      throw SuiWalletException(
        result.error?.code == 'TRANSACTION_BUSY'
            ? SuiWalletErrorKind.busy
            : SuiWalletErrorKind.unavailable,
        result.error?.message ?? 'Cannot safely coordinate this transaction.',
        definitelyNotSubmitted: result.error?.code != 'TRANSACTION_BUSY',
      );
    }
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
    return value;
  }
}

void openExternalUrl(String url) => openInNewTab(url);

/// Talks to wallets through the Wallet Standard in this browser window.
class WalletStandardBackend implements SuiWalletBackend {
  final _events = StreamController<SuiWalletBackendEvent>.broadcast();
  JSFunction? _unsubscribe;
  bool _started = false;

  @override
  bool get isSupported => true;

  @override
  Stream<SuiWalletBackendEvent> get events => _events.stream;

  @override
  void start() {
    if (_started) return;
    _started = true;
    ensureBridgeLoaded(onLateLoad: _attach);
    _attach();
  }

  void _attach() {
    final bridge = _bridge;
    if (bridge == null || _unsubscribe != null) return;
    _unsubscribe = bridge.subscribe(
      ((JSString type, JSString? id, JSArray<JSAny?>? changed) {
        if (_events.isClosed) return;
        _events.add(
          SuiWalletBackendEvent(
            type.toDart,
            walletId: id?.toDart,
            changed: [
              for (final c in changed?.toDart ?? const <JSAny?>[])
                if (c != null) '${c.dartify()}',
            ],
          ),
        );
      }).toJS,
    );
    // Wallets may have registered before we subscribed.
    _events.add(const SuiWalletBackendEvent('register'));
  }

  @override
  List<SuiWalletInfo> listWallets() {
    final bridge = _bridge;
    if (bridge == null) return const [];
    final raw = bridge.list().dartify();
    if (raw is! List) return const [];
    return [
      for (final w in raw)
        if (w is Map) SuiWalletInfo.fromJson(w),
    ];
  }

  String? _nameOf(String id) {
    for (final w in listWallets()) {
      if (w.id == id) return w.name;
    }
    return null;
  }

  Future<Object?> _call(
    String walletId,
    JSPromise<_Result> Function(_Bridge) f,
  ) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.notInstalled,
        definitelyNotSubmitted: true,
      );
    }
    final name = _nameOf(walletId);
    final result = await f(bridge).toDart;
    if (result.ok) return result.value.dartify();
    final error = result.error;
    throw classifyWalletError(
      name: error?.name,
      message: error?.message,
      code: error?.code,
      walletName: name,
    );
  }

  @override
  Future<List<SuiWalletAccount>> connect(
    String walletId, {
    required bool silent,
  }) async {
    final value = await _call(walletId, (b) => b.connect(walletId, silent));
    return [
      for (final a in (value as List<Object?>? ?? const []))
        if (a is Map) SuiWalletAccount.fromJson(a),
    ];
  }

  @override
  Future<void> disconnect(String walletId) async {
    await _call(walletId, (b) => b.disconnect(walletId));
  }

  @override
  Future<SignedPersonalMessage> signPersonalMessage(
    String walletId, {
    required String address,
    required Uint8List message,
    String? chain,
  }) async {
    final value = await _call(
      walletId,
      (b) => b.signPersonalMessage(walletId, address, message.toJS, chain),
    );
    if (value is! Map) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.unknown,
        walletName: _nameOf(walletId),
        detail: 'Wallet returned no signature',
      );
    }
    return SignedPersonalMessage(
      bytes: '${value['bytes']}',
      signature: '${value['signature']}',
    );
  }

  @override
  Future<ExecutedSuiTransaction> signAndExecuteTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) async {
    final value = await _call(walletId, (b) {
      final execute = b.signAndExecuteTransaction;
      if (execute == null) {
        throw SuiWalletException(
          SuiWalletErrorKind.unsupported,
          'This page loads an old wallet bridge. Update '
          'sui_wallet_standard.js and reload.',
          walletName: _nameOf(walletId),
          definitelyNotSubmitted: true,
        );
      }
      return execute.callAsFunction(
            b,
            walletId.toJS,
            address.toJS,
            transaction.toJS,
            chain.toJS,
          )!
          as JSPromise<_Result>;
    });
    if (value is! Map || value['digest'] is! String) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.unknown,
        walletName: _nameOf(walletId),
        detail: 'Wallet returned no transaction digest',
      );
    }
    return ExecutedSuiTransaction(
      digest: value['digest'] as String,
      effects: '${value['effects'] ?? ''}',
      bytes: '${value['bytes'] ?? ''}',
      signature: '${value['signature'] ?? ''}',
    );
  }

  @override
  void dispose() {
    final off = _unsubscribe;
    _unsubscribe = null;
    off?.callAsFunction();
    _events.close();
  }

  @override
  Future<SignedSuiTransaction> signTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) async {
    final value = await _call(walletId, (bridge) {
      final sign = bridge.signTransaction;
      if (sign == null) {
        throw const SuiWalletException(
          SuiWalletErrorKind.unsupported,
          'Reload this page to update its wallet connection.',
          definitelyNotSubmitted: true,
        );
      }
      return sign.callAsFunction(
            bridge,
            walletId.toJS,
            address.toJS,
            transaction.toJS,
            chain.toJS,
          )!
          as JSPromise<_Result>;
    });
    if (value is! Map ||
        value['bytes'] is! String ||
        value['signature'] is! String) {
      throw const FormatException('Wallet returned no signed transaction');
    }
    return SignedSuiTransaction(
      bytes: value['bytes'] as String,
      signature: value['signature'] as String,
    );
  }
}

/// Keeps the reconnect hint in `localStorage`.
class LocalStorageSuiWalletStorage implements SuiWalletStorage {
  @override
  String? read(String key) {
    try {
      return localStorageOrNull?.getItem(key);
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String key, String? value) {
    try {
      final storage = localStorageOrNull;
      if (storage == null) return;
      if (value == null) {
        storage.removeItem(key);
      } else {
        storage.setItem(key, value);
      }
    } catch (_) {
      // Private mode or blocked storage: no silent reconnect, nothing else.
    }
  }
}
