import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../generated/js_sources.g.dart';
import '../platform/dom_web.dart';
import 'mock_wallet_api.dart';

@JS('__suiMockWallet')
external _MockApi? get _api;

extension type _MockApi._(JSObject _) implements JSObject {
  external _Handle register(JSAny? options);
}

extension type _Handle._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;
  external String? get address;
  external JSArray<JSAny?> get addresses;
  external String? get publicKey;
  external bool get authorized;
  external bool get locked;
  external JSArray<JSAny?> get calls;
  external void setBehavior(JSAny? next);
  external JSPromise<JSString> switchAccount(int index);
  external JSPromise<JSString> addAccount(String? seedHex);
  external void lock();
  external void unlock();
  external void revoke();
  external void forget();
  external void unregister();
}

/// Injects `js/mock_wallet.js` into the page (once).
void installMockWalletScript() {
  if (_api != null) return;
  injectInlineScript(mockWalletJs, id: 'sui-wallet-web-mock');
}

Future<MockSuiWallet> registerMockWallet(MockWalletOptions options) async {
  installMockWalletScript();
  final api = _api;
  if (api == null) {
    throw StateError('Could not load the mock wallet script.');
  }
  final config = options.toJson().jsify()! as JSObject;
  final execute = options.execute;
  if (execute != null) {
    config.setProperty(
      'execute'.toJS,
      ((JSString transaction, JSString address, JSString chain) => execute(
        transaction.toDart,
        address.toDart,
        chain.toDart,
      ).then((digest) => digest.toJS).toJS).toJS,
    );
  }
  final transactionSigner = options.transactionSigner;
  if (transactionSigner != null) {
    config.setProperty(
      'transactionSigner'.toJS,
      ((JSString transaction, JSString address, JSString chain) =>
              transactionSigner(
                    transaction.toDart,
                    address.toDart,
                    chain.toDart,
                  )
                  .then(
                    (signed) => {
                      'bytes': signed.bytes,
                      'signature': signed.signature,
                    }.jsify(),
                  )
                  .toJS)
          .toJS,
    );
  }
  final handle = api.register(config);
  await handle.ready.toDart;
  return _WebMockSuiWallet(handle, options.name);
}

class _WebMockSuiWallet implements MockSuiWallet {
  _WebMockSuiWallet(this._handle, this.name);

  final _Handle _handle;

  @override
  final String name;

  @override
  String get address => _handle.address ?? '';

  @override
  List<String> get addresses => [
    for (final a in _handle.addresses.toDart) '${a.dartify()}',
  ];

  @override
  String get publicKeyBase64 => _handle.publicKey ?? '';

  @override
  bool get authorized => _handle.authorized;

  @override
  bool get locked => _handle.locked;

  @override
  List<Map<String, Object?>> get calls => [
    for (final c in _handle.calls.toDart)
      if (c.dartify() case final Map<Object?, Object?> m)
        {for (final e in m.entries) '${e.key}': e.value},
  ];

  @override
  void setBehavior({
    MockWalletBehavior? connect,
    MockWalletBehavior? sign,
    MockWalletBehavior? transaction,
  }) {
    _handle.setBehavior(
      {
        'connect': ?connect?.name,
        'sign': ?sign?.name,
        'transaction': ?transaction?.name,
      }.jsify(),
    );
  }

  @override
  Future<String> switchAccount(int index) async =>
      (await _handle.switchAccount(index).toDart).toDart;

  @override
  Future<String> addAccount([String? seedHex]) async =>
      (await _handle.addAccount(seedHex).toDart).toDart;

  @override
  void lock() => _handle.lock();

  @override
  void unlock() => _handle.unlock();

  @override
  void revoke() => _handle.revoke();

  @override
  void forget() => _handle.forget();

  @override
  void unregister() => _handle.unregister();
}
