import '../models.dart';

/// How the mock wallet answers a request.
enum MockWalletBehavior {
  /// Approves (after `delay`, if set).
  approve,

  /// Throws a user-rejection error (code 4001), like pressing "Reject".
  reject,

  /// Throws "The wallet is locked".
  locked,

  /// Never answers (to test timeouts).
  hang,
}

class MockWalletOptions {
  const MockWalletOptions({
    this.name = 'Mock Wallet',
    this.seeds,
    this.connect = MockWalletBehavior.approve,
    this.sign = MockWalletBehavior.approve,
    this.transaction = MockWalletBehavior.approve,
    this.execute,
    this.transactionSigner,
    this.delay = Duration.zero,
    this.remember = true,
    this.chains,
    this.omitFeatures = const [],
    this.icon,
    this.locked = false,
  });

  final String name;

  /// 32-byte Ed25519 seeds as hex, one per account. Default: one random key.
  final List<String>? seeds;
  final MockWalletBehavior connect;
  final MockWalletBehavior sign;

  /// How `sui:signAndExecuteTransaction` is answered.
  final MockWalletBehavior transaction;

  /// Runs an approved transaction (serialized JSON) for an address on a
  /// chain and returns its digest. The mock cannot execute transactions
  /// itself; without this, approvals fail.
  final Future<String> Function(
    String transaction,
    String address,
    String chain,
  )?
  execute;
  final Future<SignedSuiTransaction> Function(String, String, String)?
  transactionSigner;
  final Duration delay;

  /// Keep the site authorised across reloads (enables silent reconnect).
  final bool remember;

  /// Defaults to mainnet, testnet, devnet and localnet.
  final List<String>? chains;

  /// Leave out Wallet Standard features, e.g. `sui:signPersonalMessage`.
  final List<String> omitFeatures;

  /// A `data:image/...` URI. Default: a small purple "M".
  final String? icon;
  final bool locked;

  Map<String, Object?> toJson() => {
    'name': name,
    'seeds': ?seeds,
    'connect': connect.name,
    'sign': sign.name,
    'transaction': transaction.name,
    'delayMs': delay.inMilliseconds,
    'remember': remember,
    'chains': ?chains,
    'omitFeatures': omitFeatures,
    'icon': ?icon,
    'locked': locked,
  };
}

/// A Sui wallet for tests that registers through the Wallet Standard, holds
/// throwaway Ed25519 keys and makes real personal-message signatures.
///
/// Browser only (`flutter test --platform chrome`, or a real page). For
/// Playwright, load `js/mock_wallet.js` with `page.addInitScript` instead.
abstract interface class MockSuiWallet {
  String get name;

  /// Active account address.
  String get address;
  List<String> get addresses;
  String get publicKeyBase64;

  /// The site is authorised (connect approved, not revoked).
  bool get authorized;
  bool get locked;

  /// Every request the wallet received, oldest first.
  List<Map<String, Object?>> get calls;

  void setBehavior({
    MockWalletBehavior? connect,
    MockWalletBehavior? sign,
    MockWalletBehavior? transaction,
  });

  /// Makes another account active and emits a Wallet Standard change event.
  Future<String> switchAccount(int index);

  /// Adds an account (random key if [seedHex] is null). Returns its address.
  Future<String> addAccount([String? seedHex]);

  /// Locks the wallet: it shares no accounts and refuses requests.
  void lock();
  void unlock();

  /// Withdraws the site's authorisation.
  void revoke();

  /// Clears remembered authorisation from localStorage.
  void forget();

  /// Removes the wallet from the page.
  void unregister();
}
