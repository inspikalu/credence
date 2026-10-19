import 'dart:typed_data';

import 'models.dart';
import 'errors.dart';

/// Something happened in the wallet registry.
class SuiWalletBackendEvent {
  const SuiWalletBackendEvent(
    this.type, {
    this.walletId,
    this.changed = const [],
  });

  /// `register`, `unregister` or `change`.
  final String type;
  final String? walletId;

  /// For `change`: which properties changed (`accounts`, `chains`, ...).
  final List<String> changed;
}

/// The low-level wallet transport. [SuiWalletController] is built on it.
///
/// The default implementation talks to the Wallet Standard in the browser;
/// `FakeSuiWalletBackend` (in `testing.dart`) is a pure-Dart stand-in for
/// widget tests that run outside a browser.
abstract interface class SuiWalletBackend {
  /// False where there are no wallets at all (not on the web).
  bool get isSupported;

  /// Starts discovery. Safe to call more than once.
  void start();

  /// Every registered wallet, Sui or not.
  List<SuiWalletInfo> listWallets();

  Stream<SuiWalletBackendEvent> get events;

  /// `standard:connect`. Throws `SuiWalletException`.
  Future<List<SuiWalletAccount>> connect(
    String walletId, {
    required bool silent,
  });

  /// `standard:disconnect` when the wallet has it.
  Future<void> disconnect(String walletId);

  /// `sui:signPersonalMessage`. Throws `SuiWalletException`.
  Future<SignedPersonalMessage> signPersonalMessage(
    String walletId, {
    required String address,
    required Uint8List message,
    String? chain,
  });

  /// `sui:signAndExecuteTransaction` with a serialized [transaction] (the
  /// JSON `@mysten/sui`'s `Transaction.toJSON()` produces). Throws
  /// `SuiWalletException`.
  Future<ExecutedSuiTransaction> signAndExecuteTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  });

  /// Signs without broadcasting. The application controls submission.
  Future<SignedSuiTransaction> signTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  });

  void dispose();
}

/// Serializes approvals and submissions across controllers and browser tabs.
abstract interface class SuiWalletTransactionLock {
  Future<T> run<T>(String name, Future<T> Function() action);
}

class MemorySuiWalletTransactionLock implements SuiWalletTransactionLock {
  static final _held = <String>{};

  @override
  Future<T> run<T>(String name, Future<T> Function() action) async {
    if (!_held.add(name)) {
      throw const SuiWalletException(
        SuiWalletErrorKind.busy,
        'A transaction for this account is already in progress.',
      );
    }
    try {
      return await action();
    } finally {
      _held.remove(name);
    }
  }
}

/// Remembers which wallet and account to reconnect to.
abstract interface class SuiWalletStorage {
  String? read(String key);
  void write(String key, String? value);
}

class MemorySuiWalletStorage implements SuiWalletStorage {
  final _values = <String, String>{};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}
