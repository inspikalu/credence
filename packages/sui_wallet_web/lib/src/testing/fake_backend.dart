import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../backend.dart';
import '../errors.dart';
import '../models.dart';
import 'mock_wallet_api.dart';

/// Signs a personal message for [address]; returns the base64 Sui
/// signature. Use `TestSuiSigner` from `package:sui_auth/testing.dart` to
/// produce signatures a server will accept.
typedef FakeSigner =
    FutureOr<String> Function(Uint8List message, String address);

/// Executes a serialized transaction for [address] on [chain] and returns
/// its digest. Tests can record the JSON, or really execute it.
typedef FakeExecutor =
    FutureOr<String> Function(String transaction, String address, String chain);

/// A wallet inside [FakeSuiWalletBackend].
class FakeSuiWallet {
  FakeSuiWallet({
    required this.name,
    required List<String> addresses,
    this.icon = '',
    this.chains = const ['sui:mainnet', 'sui:testnet', 'sui:devnet'],
    List<String>? features,
    this.connectBehavior = MockWalletBehavior.approve,
    this.signBehavior = MockWalletBehavior.approve,
    this.signer,
    this.transactionBehavior = MockWalletBehavior.approve,
    this.executor,
    this.transactionSigner,
    this.authorized = false,
  }) : addresses = List.of(addresses),
       features =
           features ??
           const [
             SuiWalletFeatures.connect,
             SuiWalletFeatures.disconnect,
             SuiWalletFeatures.events,
             SuiWalletFeatures.signPersonalMessage,
             SuiWalletFeatures.signAndExecuteTransaction,
           ];

  final String name;
  final String icon;
  final List<String> chains;
  final List<String> features;
  final List<String> addresses;
  MockWalletBehavior connectBehavior;
  MockWalletBehavior signBehavior;
  FakeSigner? signer;
  MockWalletBehavior transactionBehavior;

  /// Runs approved transactions; without one, approvals fail.
  FakeExecutor? executor;
  Future<SignedSuiTransaction> Function(String, String, String)?
  transactionSigner;
  bool authorized;
  bool locked = false;
  int active = 0;
  late final String id;
}

/// A pure-Dart [SuiWalletBackend] for widget tests that run on the VM.
///
/// ```dart
/// final backend = FakeSuiWalletBackend([
///   FakeSuiWallet(name: 'Slush', addresses: [signer.address],
///       signer: (m, _) => signer.signPersonalMessage(m)),
/// ]);
/// final controller = SuiWalletController(backend: backend,
///     storage: MemorySuiWalletStorage());
/// ```
class FakeSuiWalletBackend implements SuiWalletBackend {
  FakeSuiWalletBackend([List<FakeSuiWallet> wallets = const []]) {
    wallets.forEach(addWallet);
  }

  final _wallets = <FakeSuiWallet>[];
  final _events = StreamController<SuiWalletBackendEvent>.broadcast(sync: true);
  int _nextId = 1;

  /// Every call, for assertions: `connect`, `connect(silent)`, `sign`, ...
  final calls = <String>[];

  List<FakeSuiWallet> get wallets => List.unmodifiable(_wallets);

  void addWallet(FakeSuiWallet wallet) {
    wallet.id = 'fake${_nextId++}';
    _wallets.add(wallet);
    _events.add(SuiWalletBackendEvent('register', walletId: wallet.id));
  }

  void removeWallet(FakeSuiWallet wallet) {
    _wallets.remove(wallet);
    _events.add(SuiWalletBackendEvent('unregister', walletId: wallet.id));
  }

  /// Makes another account active, like switching accounts in the wallet.
  void switchAccount(FakeSuiWallet wallet, int index) {
    wallet.active = index;
    _change(wallet);
  }

  void lock(FakeSuiWallet wallet) {
    wallet.locked = true;
    _change(wallet);
  }

  void unlock(FakeSuiWallet wallet) {
    wallet.locked = false;
    _change(wallet);
  }

  void _change(FakeSuiWallet wallet) => _events.add(
    SuiWalletBackendEvent(
      'change',
      walletId: wallet.id,
      changed: const ['accounts'],
    ),
  );

  List<SuiWalletAccount> _exposed(FakeSuiWallet w) =>
      !w.authorized || w.locked || w.addresses.isEmpty
      ? const []
      : [
          SuiWalletAccount(
            address: w.addresses[w.active],
            publicKey: Uint8List(0),
            chains: w.chains,
          ),
        ];

  FakeSuiWallet _find(String id) {
    for (final w in _wallets) {
      if (w.id == id) return w;
    }
    throw SuiWalletException.of(SuiWalletErrorKind.walletNotFound);
  }

  Future<void> _behave(MockWalletBehavior behavior, String name) async {
    switch (behavior) {
      case MockWalletBehavior.approve:
        return;
      case MockWalletBehavior.reject:
        throw classifyWalletError(
          name: 'UserRejectedRequestError',
          message: 'The user rejected the request.',
          code: '4001',
          walletName: name,
        );
      case MockWalletBehavior.locked:
        throw SuiWalletException.of(
          SuiWalletErrorKind.locked,
          walletName: name,
        );
      case MockWalletBehavior.hang:
        await Completer<void>().future;
    }
  }

  @override
  bool get isSupported => true;

  @override
  void start() {}

  @override
  Stream<SuiWalletBackendEvent> get events => _events.stream;

  @override
  List<SuiWalletInfo> listWallets() => [
    for (final w in _wallets)
      SuiWalletInfo(
        id: w.id,
        name: w.name,
        icon: w.icon,
        chains: w.chains,
        features: w.features,
        accounts: _exposed(w),
      ),
  ];

  @override
  Future<List<SuiWalletAccount>> connect(
    String walletId, {
    required bool silent,
  }) async {
    final w = _find(walletId);
    calls.add(silent ? 'connect(silent)' : 'connect');
    if (silent) return _exposed(w);
    if (w.locked) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.locked,
        walletName: w.name,
      );
    }
    await _behave(w.connectBehavior, w.name);
    w.authorized = true;
    return _exposed(w);
  }

  @override
  Future<void> disconnect(String walletId) async {
    calls.add('disconnect');
    _find(walletId).authorized = false;
  }

  @override
  Future<SignedPersonalMessage> signPersonalMessage(
    String walletId, {
    required String address,
    required Uint8List message,
    String? chain,
  }) async {
    final w = _find(walletId);
    calls.add('sign');
    if (_exposed(w).every((a) => a.address != address)) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.accountNotFound,
        walletName: w.name,
      );
    }
    await _behave(w.signBehavior, w.name);
    final signature =
        await w.signer?.call(message, address) ??
        base64.encode(Uint8List(97)); // Not a valid signature.
    return SignedPersonalMessage(
      bytes: base64.encode(message),
      signature: signature,
    );
  }

  @override
  Future<ExecutedSuiTransaction> signAndExecuteTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) async {
    final w = _find(walletId);
    calls.add('execute');
    if (_exposed(w).every((a) => a.address != address)) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.accountNotFound,
        walletName: w.name,
      );
    }
    await _behave(w.transactionBehavior, w.name);
    final executor = w.executor;
    if (executor == null) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.unknown,
        walletName: w.name,
        detail: 'FakeSuiWallet has no executor',
      );
    }
    return ExecutedSuiTransaction(
      digest: await executor(transaction, address, chain),
    );
  }

  @override
  void dispose() => _events.close();

  @override
  Future<SignedSuiTransaction> signTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) async {
    final w = _find(walletId);
    calls.add('signTransaction');
    if (_exposed(w).every((a) => a.address != address)) {
      throw SuiWalletException.of(SuiWalletErrorKind.accountNotFound);
    }
    await _behave(w.transactionBehavior, w.name);
    if (w.transactionSigner == null) {
      throw StateError('FakeSuiWallet has no transaction signer');
    }
    return w.transactionSigner!(transaction, address, chain);
  }
}
