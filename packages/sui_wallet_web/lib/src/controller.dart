import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'errors.dart';
import 'models.dart';
import 'platform/platform.dart';
import 'transaction_executor.dart';
import 'transaction_journal.dart';

bool _validTransactionDigest(String value) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  if (value.length < 32 || value.length > 44) return false;
  var number = BigInt.zero;
  var leadingZeros = 0;
  for (var i = 0; i < value.length; i++) {
    final digit = alphabet.indexOf(value[i]);
    if (digit < 0) return false;
    if (number == BigInt.zero && digit == 0) leadingZeros++;
    number = number * BigInt.from(58) + BigInt.from(digit);
  }
  return leadingZeros + (number.bitLength + 7) ~/ 8 == 32;
}

/// Headless Sui wallet connection for Flutter web.
///
/// ```dart
/// final wallet = SuiWalletController(chain: 'sui:testnet');
/// await wallet.init();                       // discovery + silent reconnect
/// wallet.wallets;                            // installed Sui wallets
/// await wallet.connect(wallet.wallets.first);
/// final signed = await wallet.signPersonalMessage(utf8.encode(text));
/// wallet.changes.listen((change) { ... });   // account switches, etc.
/// await wallet.disconnect();
/// ```
///
/// It is also a [ChangeNotifier], so widgets can rebuild with
/// `ListenableBuilder`.
class SuiWalletController extends ChangeNotifier {
  SuiWalletController({
    this.chain = 'sui:testnet',
    SuiWalletBackend? backend,
    SuiWalletStorage? storage,
    SuiTransactionExecutor? transactionExecutor,
    SuiWalletTransactionLock? transactionLock,
    this.autoConnect = true,
    this.connectTimeout = const Duration(minutes: 2),
    this.signTimeout = const Duration(minutes: 2),
    this.networkTimeout = const Duration(seconds: 30),
    this.silentConnectTimeout = const Duration(seconds: 5),
    this.reconnectWait = const Duration(seconds: 3),
    this.discoveryGrace = const Duration(milliseconds: 600),
    this.storageKey = 'sui_wallet_web.connection',
  }) : backend = backend ?? createDefaultBackend(),
       _ownsBackend = backend == null,
       storage = storage ?? createDefaultStorage(),
       transactionExecutor =
           transactionExecutor ?? GrpcSuiTransactionExecutor(),
       transactionLock = transactionLock ?? createDefaultTransactionLock();

  /// Chain passed to `sui:signPersonalMessage` (when the wallet lists it)
  /// and to `sui:signAndExecuteTransaction`.
  final String chain;
  final SuiWalletBackend backend;
  final SuiWalletStorage storage;
  final SuiTransactionExecutor transactionExecutor;
  final SuiWalletTransactionLock transactionLock;
  late final _transactionJournal = SuiTransactionJournal(
    storage,
    transactionExecutor,
    storageKey,
  );
  final bool _ownsBackend;

  /// Reconnect silently on start-up when the person connected before.
  final bool autoConnect;
  final Duration connectTimeout;
  final Duration signTimeout;
  final Duration networkTimeout;
  final Duration silentConnectTimeout;

  /// How long start-up waits for the last-used wallet to register.
  final Duration reconnectWait;

  /// How long to wait for extensions before reporting "no wallet".
  final Duration discoveryGrace;
  final String storageKey;

  SuiWalletStatus _status = SuiWalletStatus.initializing;
  List<SuiWalletInfo> _wallets = const [];
  bool _discoveryComplete = false;
  SuiWalletInfo? _wallet;
  SuiWalletAccount? _account;
  String? _pausedWalletId;
  bool _busy = false;
  bool _transactionInFlight = false;
  bool _transactionUnresolved = false;
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _initFuture;
  StreamSubscription<SuiWalletBackendEvent>? _subscription;
  Timer? _discoveryTimer;
  final _changes = StreamController<SuiWalletChange>.broadcast();

  SuiWalletState get state => SuiWalletState(
    status: _status,
    wallets: _wallets,
    discoveryComplete: _discoveryComplete,
    wallet: _wallet,
    account: _status == SuiWalletStatus.connected ? _account : null,
    busy: _busy,
  );

  /// Every change: wallets found, connected, account switched, and so on.
  Stream<SuiWalletChange> get changes => _changes.stream;

  /// Installed wallets that support Sui (others are left out).
  List<SuiWalletInfo> get wallets => _wallets;
  SuiWalletStatus get status => _status;
  bool get isConnected => _status == SuiWalletStatus.connected;
  bool get busy => _busy;

  /// A transaction request may have executed without returning a result.
  /// New transactions stay blocked even after disconnecting/reconnecting.
  /// The pending marker survives a page reload in the default storage.
  bool get hasUnresolvedTransaction =>
      _transactionUnresolved ||
      storage.read(_pendingKey) != null ||
      pendingRecoverableRequestId != null;

  String? get pendingRecoverableRequestId => _account == null
      ? null
      : _transactionJournal.pendingRequestId(chain, _account!.address);

  String get _pendingKey => '$storageKey.$chain.pendingTransaction';

  /// The last wallet response, retained for reconciling an interrupted upload.
  String? get lastTransactionReceipt => storage.read('$_pendingKey.receipt');

  void _persistPending(SuiWalletInfo wallet, SuiWalletAccount account) {
    final value = jsonEncode({
      'wallet': wallet.name,
      'address': account.address,
      'chain': chain,
      'requestedAt': DateTime.now().toUtc().toIso8601String(),
    });
    var saved = false;
    try {
      storage.write(_pendingKey, value);
      saved = storage.read(_pendingKey) == value;
    } catch (_) {
      // No wallet request has started yet.
    }
    if (!saved) {
      throw const SuiWalletException(
        SuiWalletErrorKind.unavailable,
        'Allow this site to save browser data before paying for storage.',
        definitelyNotSubmitted: true,
      );
    }
  }

  void _clearPending() {
    storage.write(_pendingKey, null);
    _transactionUnresolved = storage.read(_pendingKey) != null;
  }

  /// Explicitly confirms that the caller checked the original request in
  /// the wallet and on-chain, and recovered its result or established that
  /// it cannot execute. This does not cancel a request still in the wallet.
  /// Resolve the corresponding Dartus flow before starting another write.
  void confirmTransactionResolved() {
    _checkAlive();
    if (_busy || _transactionInFlight) {
      throw StateError('A wallet request is still open');
    }
    _clearPending();
    _notify();
  }

  /// The connected wallet, or null.
  SuiWalletInfo? get wallet => isConnected ? _wallet : null;

  /// The connected account, or null.
  SuiWalletAccount? get account => isConnected ? _account : null;

  /// Starts discovery and, if the person connected before, reconnects
  /// without a prompt. Safe to call more than once.
  Future<void> init() => _initFuture ??= _start();

  Future<void> _start() async {
    backend.start();
    _subscription = backend.events.listen(_onBackendEvent);
    _refreshWallets(emit: false);
    _discoveryTimer = Timer(discoveryGrace, () {
      _discoveryComplete = true;
      _emit(SuiWalletChangeType.walletsChanged);
    });

    final saved = _readSaved();
    if (!autoConnect || saved == null || !backend.isSupported) {
      _status = SuiWalletStatus.disconnected;
      _emit(SuiWalletChangeType.walletsChanged);
      return;
    }

    _status = SuiWalletStatus.reconnecting;
    final generation = ++_generation;
    _notify();
    final wallet = await _waitForWallet(saved.wallet, reconnectWait);
    if (_stale(generation)) return;
    if (wallet != null) {
      try {
        final accounts =
            (await backend
                    .connect(wallet.id, silent: true)
                    .timeout(silentConnectTimeout))
                .where((a) => a.supportsSui)
                .toList();
        if (_stale(generation)) return;
        if (accounts.isNotEmpty) {
          final account = accounts.firstWhere(
            (a) => a.address == saved.address,
            orElse: () => accounts.first,
          );
          _setConnected(
            _latest(wallet),
            account,
            SuiWalletChangeType.reconnected,
          );
          return;
        }
      } catch (_) {
        // Silent reconnect is best effort.
      }
    }
    if (_stale(generation)) return;
    _forget();
    _wallet = null;
    _status = SuiWalletStatus.disconnected;
    _emit(SuiWalletChangeType.disconnected);
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  Future<SuiWalletInfo?> _waitForWallet(String name, Duration timeout) async {
    SuiWalletInfo? find() {
      for (final w in backend.listWallets()) {
        if (w.supportsSui && w.name == name) return w;
      }
      return null;
    }

    final now = find();
    if (now != null || timeout == Duration.zero) return now;
    final completer = Completer<SuiWalletInfo?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final sub = backend.events.listen((_) {
      final found = find();
      if (found != null && !completer.isCompleted) completer.complete(found);
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }

  /// Asks [wallet] to connect (the wallet shows its approval prompt).
  ///
  /// Throws [SuiWalletException]: `rejected`, `locked`, `noAccounts`,
  /// `timeout`, `busy`, `walletNotFound`, `unsupported` or `unknown`.
  Future<SuiWalletAccount> connect(
    SuiWalletInfo wallet, {
    Duration? timeout,
  }) async {
    _checkAlive();
    if (_busy) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.busy,
        walletName: _wallet?.name,
      );
    }
    if (!backend.isSupported) {
      throw SuiWalletException.of(SuiWalletErrorKind.unavailable);
    }
    if (!wallet.supportsSui) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.unsupported,
        walletName: wallet.name,
      );
    }
    final generation = ++_generation;
    final previous = (_status, _wallet, _account);
    _busy = true;
    _status = SuiWalletStatus.connecting;
    _wallet = wallet;
    _pausedWalletId = null;
    _emit(SuiWalletChangeType.connecting);

    try {
      final accounts = await backend
          .connect(wallet.id, silent: false)
          .timeout(timeout ?? connectTimeout);
      final sui = accounts.where((a) => a.supportsSui).toList();
      if (sui.isEmpty) {
        throw SuiWalletException.of(
          SuiWalletErrorKind.noAccounts,
          walletName: wallet.name,
        );
      }
      final saved = _readSaved();
      final account = sui.firstWhere(
        (a) => saved?.wallet == wallet.name && a.address == saved?.address,
        orElse: () => sui.first,
      );
      _busy = false;
      if (!_stale(generation)) {
        _setConnected(_latest(wallet), account, SuiWalletChangeType.connected);
      }
      return account;
    } on TimeoutException {
      throw _failConnect(
        SuiWalletException.of(
          SuiWalletErrorKind.timeout,
          walletName: wallet.name,
        ),
        previous,
        generation,
      );
    } on SuiWalletException catch (e) {
      throw _failConnect(e, previous, generation);
    } finally {
      _busy = false;
    }
  }

  SuiWalletException _failConnect(
    SuiWalletException error,
    (SuiWalletStatus, SuiWalletInfo?, SuiWalletAccount?) previous,
    int generation,
  ) {
    _busy = false;
    if (!_stale(generation)) {
      final (status, wallet, account) = previous;
      final wasConnected = status == SuiWalletStatus.connected;
      _status = wasConnected
          ? SuiWalletStatus.connected
          : SuiWalletStatus.disconnected;
      _wallet = wasConnected ? wallet : null;
      _account = wasConnected ? account : null;
      _emit(SuiWalletChangeType.failed, error: error);
    }
    return error;
  }

  /// Signs [message] with the connected account (`sui:signPersonalMessage`).
  ///
  /// Throws [SuiWalletException]: `notConnected`, `rejected`, `locked`,
  /// `accountNotFound`, `timeout`, `busy` or `unknown`.
  Future<SignedPersonalMessage> signPersonalMessage(
    List<int> message, {
    Duration? timeout,
  }) => _request(
    timeout ?? signTimeout,
    (wallet, account) => backend.signPersonalMessage(
      wallet.id,
      address: account.address,
      message: Uint8List.fromList(message),
      chain: wallet.supportsChain(chain) ? chain : null,
    ),
  );

  /// Asks the wallet to approve, sign and execute [transaction] on [chain]
  /// (`sui:signAndExecuteTransaction`).
  ///
  /// [transaction] is a serialized transaction: the JSON `@mysten/sui`'s
  /// `Transaction.toJSON()` produces, such as Dartus's
  /// `WalletTransaction.json`. The wallet adds gas and shows the person
  /// what they are approving.
  ///
  /// Throws [SuiWalletException]: `unsupported` when the wallet cannot
  /// execute transactions, plus the same kinds as [signPersonalMessage].
  Future<ExecutedSuiTransaction> signAndExecuteTransaction(
    String transaction, {
    Duration? timeout,
  }) {
    if (_wallet?.features.contains(SuiWalletFeatures.signTransaction) ??
        false) {
      final random = Random.secure();
      final requestId = List.generate(
        24,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      return signAndExecuteRecoverable(
        transaction,
        requestId: requestId,
        timeout: timeout,
      );
    }
    return transactionLock.run(
      'sui-wallet-transaction:$chain:${_account?.address.toLowerCase()}',
      () => _legacySignAndExecuteTransaction(transaction, timeout: timeout),
    );
  }

  /// Signs without broadcasting, saves the exact signed transaction, then
  /// submits it. Reusing [requestId] reconciles or resubmits those same bytes;
  /// it never asks the wallet to authorize a replacement payment.
  Future<ExecutedSuiTransaction> signAndExecuteRecoverable(
    String transaction, {
    required String requestId,
    bool resume = false,
    Duration? timeout,
  }) async {
    _checkAlive();
    final firstAttempt = !resume && !_transactionJournal.hasRequest(requestId);
    final wallet = _wallet;
    final account = _account;
    if (!isConnected || wallet == null || account == null) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.notConnected,
        definitelyNotSubmitted: firstAttempt,
      );
    }
    if (_busy || _transactionInFlight) {
      throw SuiWalletException.of(SuiWalletErrorKind.busy);
    }
    if (_transactionUnresolved || storage.read(_pendingKey) != null) {
      throw SuiWalletException(
        SuiWalletErrorKind.unknown,
        walletSubmissionUnknownMessage,
        definitelyNotSubmitted: firstAttempt,
      );
    }
    if (!wallet.features.contains(SuiWalletFeatures.signTransaction)) {
      throw SuiWalletException(
        SuiWalletErrorKind.unsupported,
        'This wallet cannot safely resume uploads. Use a wallet that supports '
        'signing transactions without submitting them, such as Slush.',
        definitelyNotSubmitted: firstAttempt,
      );
    }
    final generation = _generation;
    _busy = true;
    _transactionInFlight = true;
    _notify();
    try {
      return await transactionLock.run(
        '$storageKey.request:$requestId',
        () => transactionLock.run(
          'sui-wallet-transaction:$chain:${account.address.toLowerCase()}',
          () async {
            // The other tab may have installed a legacy marker while this tab
            // was opening. Never silently replace an older uncertain payment.
            if (storage.read(_pendingKey) != null) {
              throw const SuiWalletException(
                SuiWalletErrorKind.unknown,
                walletSubmissionUnknownMessage,
                definitelyNotSubmitted: true,
              );
            }
            return _transactionJournal.run(
              transaction: transaction,
              requestId: requestId,
              chain: chain,
              address: account.address,
              walletName: wallet.name,
              sign: () => backend.signTransaction(
                wallet.id,
                address: account.address,
                transaction: transaction,
                chain: chain,
              ),
              isCurrentAccount: () =>
                  !_stale(generation) &&
                  isConnected &&
                  _wallet?.id == wallet.id &&
                  _account?.address == account.address,
              signTimeout: timeout ?? signTimeout,
              networkTimeout: networkTimeout,
              resume: resume,
            );
          },
        ),
      );
    } on SuiWalletException catch (error) {
      final reported = !firstAttempt && error.definitelyNotSubmitted
          ? SuiWalletException(
              error.kind,
              error.message,
              detail: error.detail,
              walletName: error.walletName,
              transactionDigest: error.transactionDigest,
            )
          : error;
      _emit(SuiWalletChangeType.failed, error: reported);
      throw reported;
    } finally {
      _transactionInFlight = false;
      _busy = false;
      _notify();
    }
  }

  Future<ExecutedSuiTransaction> _legacySignAndExecuteTransaction(
    String transaction, {
    Duration? timeout,
  }) => _request(timeout ?? signTimeout, (wallet, account) async {
    if (!wallet.features.contains(
      SuiWalletFeatures.signAndExecuteTransaction,
    )) {
      throw SuiWalletException(
        SuiWalletErrorKind.unsupported,
        '${wallet.name} cannot approve transactions. Try another wallet, '
        'such as Slush.',
        walletName: wallet.name,
        definitelyNotSubmitted: true,
      );
    }
    final result = await backend.signAndExecuteTransaction(
      wallet.id,
      address: account.address,
      transaction: transaction,
      chain: chain,
    );
    if (!_validTransactionDigest(result.digest)) {
      throw SuiWalletException(
        SuiWalletErrorKind.unknown,
        walletSubmissionUnknownMessage,
        walletName: wallet.name,
      );
    }
    storage.write(
      '$_pendingKey.receipt',
      jsonEncode({
        'digest': result.digest,
        'address': account.address,
        'chain': chain,
        'receivedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    return result;
  }, submitsTransaction: true);

  /// Runs one wallet request for the connected account: one at a time,
  /// with a timeout, reporting failures on [changes].
  Future<T> _request<T>(
    Duration timeout,
    Future<T> Function(SuiWalletInfo wallet, SuiWalletAccount account) call, {
    bool submitsTransaction = false,
  }) async {
    _checkAlive();
    if (submitsTransaction &&
        !_transactionInFlight &&
        hasUnresolvedTransaction) {
      throw SuiWalletException(
        SuiWalletErrorKind.unknown,
        walletSubmissionUnknownMessage,
        definitelyNotSubmitted: true,
      );
    }
    final wallet = _wallet;
    final account = _account;
    if (!isConnected || wallet == null || account == null) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.notConnected,
        definitelyNotSubmitted: true,
      );
    }
    if (_busy || _transactionInFlight) {
      throw SuiWalletException.of(
        SuiWalletErrorKind.busy,
        walletName: wallet.name,
        definitelyNotSubmitted: true,
      );
    }
    if (submitsTransaction) _persistPending(wallet, account);
    _busy = true;
    if (submitsTransaction) _transactionInFlight = true;
    _notify();
    try {
      final result = await call(wallet, account).timeout(timeout);
      if (submitsTransaction) _clearPending();
      return result;
    } on TimeoutException {
      if (submitsTransaction) _transactionUnresolved = true;
      final error = SuiWalletException(
        SuiWalletErrorKind.timeout,
        submitsTransaction
            ? walletSubmissionUnknownMessage
            : SuiWalletException.defaultMessage(
                SuiWalletErrorKind.timeout,
                wallet.name,
              ),
        walletName: wallet.name,
      );
      _busy = false;
      _emit(SuiWalletChangeType.failed, error: error);
      throw error;
    } on SuiWalletException catch (error) {
      if (submitsTransaction && !error.definitelyNotSubmitted) {
        _transactionUnresolved = true;
      } else if (submitsTransaction) {
        _clearPending();
      }
      _busy = false;
      _emit(SuiWalletChangeType.failed, error: error);
      rethrow;
    } catch (_) {
      if (submitsTransaction) _transactionUnresolved = true;
      rethrow;
    } finally {
      if (submitsTransaction) _transactionInFlight = false;
      if (_busy) {
        _busy = false;
        _notify();
      }
    }
  }

  /// Disconnects and forgets the wallet, so the next visit does not
  /// reconnect silently.
  Future<void> disconnect() async {
    _checkAlive();
    final wallet = _wallet;
    final previous = _account;
    _generation++;
    _forget();
    _status = SuiWalletStatus.disconnected;
    _wallet = null;
    _account = null;
    _pausedWalletId = null;
    _busy = false;
    _emit(SuiWalletChangeType.disconnected, previousAccount: previous);
    if (wallet != null) {
      try {
        await backend.disconnect(wallet.id).timeout(const Duration(seconds: 5));
      } catch (_) {
        // The site has already forgotten the wallet; that is what matters.
      }
    }
  }

  void _onBackendEvent(SuiWalletBackendEvent event) {
    if (_disposed) return;
    _refreshWallets();

    final pausedId = _pausedWalletId;
    if (pausedId != null && event.walletId == pausedId) {
      // The wallet was locked while connected; resume when it shares
      // accounts again.
      final wallet = _byId(pausedId);
      final accounts = wallet?.accounts.where((a) => a.supportsSui).toList();
      if (wallet != null && accounts != null && accounts.isNotEmpty) {
        final previous = _account;
        _pausedWalletId = null;
        _setConnected(
          wallet,
          accounts.firstWhere(
            (a) => a.address == previous?.address,
            orElse: () => accounts.first,
          ),
          previous != null &&
                  accounts.every((a) => a.address != previous.address)
              ? SuiWalletChangeType.accountChanged
              : SuiWalletChangeType.reconnected,
          previousAccount: previous,
        );
      }
      return;
    }

    final current = _wallet;
    if (current == null || _status != SuiWalletStatus.connected) return;
    final updated = _byId(current.id);
    if (updated == null) {
      _generation++;
      final previous = _account;
      _status = SuiWalletStatus.disconnected;
      _wallet = null;
      _account = null;
      _emit(
        SuiWalletChangeType.disconnected,
        previousAccount: previous,
        error: SuiWalletException.of(
          SuiWalletErrorKind.walletNotFound,
          walletName: current.name,
        ),
      );
      return;
    }
    final chainsChanged = !listEquals(updated.chains, current.chains);
    if (chainsChanged) _generation++;
    _wallet = updated;
    if (event.type == 'change' && event.walletId == current.id) {
      if (event.changed.isEmpty || event.changed.contains('accounts')) {
        _onAccountsChanged(updated);
      }
      if (chainsChanged || event.changed.contains('chains')) {
        _emit(SuiWalletChangeType.chainsChanged);
      }
    }
  }

  void _onAccountsChanged(SuiWalletInfo wallet) {
    final accounts = wallet.accounts.where((a) => a.supportsSui).toList();
    final previous = _account;
    if (accounts.isEmpty) {
      _generation++;
      // Locked, or the person revoked the site. Keep the saved hint so a
      // reload can still reconnect silently once the wallet is unlocked.
      _status = SuiWalletStatus.disconnected;
      _pausedWalletId = wallet.id;
      _emit(
        SuiWalletChangeType.disconnected,
        previousAccount: previous,
        error: SuiWalletException.of(
          SuiWalletErrorKind.locked,
          walletName: wallet.name,
        ),
      );
      return;
    }
    final same = accounts.where((a) => a.address == previous?.address);
    if (same.isNotEmpty) {
      _account = same.first;
      _notify();
      return;
    }
    _account = accounts.first;
    _generation++;
    _save(wallet.name, accounts.first.address);
    _emit(SuiWalletChangeType.accountChanged, previousAccount: previous);
  }

  void _setConnected(
    SuiWalletInfo wallet,
    SuiWalletAccount account,
    SuiWalletChangeType type, {
    SuiWalletAccount? previousAccount,
  }) {
    _status = SuiWalletStatus.connected;
    _wallet = wallet;
    _account = account;
    _save(wallet.name, account.address);
    _emit(type, previousAccount: previousAccount);
  }

  SuiWalletInfo? _byId(String id) {
    for (final w in _wallets) {
      if (w.id == id) return w;
    }
    return null;
  }

  SuiWalletInfo _latest(SuiWalletInfo wallet) => _byId(wallet.id) ?? wallet;

  void _refreshWallets({bool emit = true}) {
    final next = [
      for (final w in backend.listWallets())
        if (w.supportsSui) w,
    ];
    if (listEquals(next, _wallets)) return;
    _wallets = List.unmodifiable(next);
    if (emit) _emit(SuiWalletChangeType.walletsChanged);
  }

  ({String wallet, String address})? _readSaved() {
    final raw = storage.read(storageKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is Map &&
          json['wallet'] is String &&
          json['address'] is String) {
        return (
          wallet: json['wallet'] as String,
          address: json['address'] as String,
        );
      }
    } on FormatException {
      // Ignore a damaged entry.
    }
    return null;
  }

  void _save(String wallet, String address) => storage.write(
    storageKey,
    jsonEncode({'wallet': wallet, 'address': address}),
  );

  void _forget() => storage.write(storageKey, null);

  void _emit(
    SuiWalletChangeType type, {
    SuiWalletAccount? previousAccount,
    SuiWalletException? error,
  }) {
    if (_disposed) return;
    notifyListeners();
    _changes.add(
      SuiWalletChange(
        type,
        state,
        previousAccount: previousAccount,
        error: error,
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkAlive() {
    if (_disposed) throw StateError('SuiWalletController was disposed');
  }

  /// Safe to call more than once.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _discoveryTimer?.cancel();
    _subscription?.cancel();
    _changes.close();
    if (_ownsBackend) backend.dispose();
    super.dispose();
  }
}
