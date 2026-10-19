import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';

/// Who is signed in, if anyone.
///
/// Vault owners sign in with a Sui wallet (Sign in with Sui: the wallet signs
/// a short message, the server sets an `HttpOnly` session cookie). People
/// checking a document never need this.
class Account extends ChangeNotifier {
  Account({required this.wallet, required this.client});

  final SuiWalletController wallet;
  final SuiSignInClient client;

  SuiSessionInfo? _session;
  bool _checked = false;
  String? _switchedTo;
  StreamSubscription<SuiWalletChange>? _changes;
  bool _disposed = false;
  String? signOutError;

  /// The signed-in owner, or null.
  SuiSessionInfo? get session => _session;

  /// The signed-in Sui address, or null.
  String? get address => _session?.address;

  bool get signedIn => _session != null;

  /// False until the first session check has answered.
  bool get checked => _checked;

  /// Set when the wallet switched to an address other than the signed-in
  /// one. The session still belongs to the old address.
  String? get switchedTo => _switchedTo;

  /// Whether the signed-in address is [owner].
  bool owns(String? owner) =>
      owner != null && _session != null && _session!.address == owner;

  /// Finds wallets (and silently reconnects a remembered one) and asks the
  /// server whether a session cookie is already in place.
  Future<void> start() async {
    _changes ??= wallet.changes.listen(_onWalletChange);
    unawaited(wallet.init());
    await refresh();
  }

  /// Asks the server for the current session again, for example after an
  /// owner-only request answered 401.
  Future<void> refresh() async {
    SuiSessionInfo? session;
    try {
      session = await client.currentSession();
    } on SuiSignInException {
      session = null;
    }
    _session = session;
    _checked = true;
    _switchedTo = _mismatch();
    _notify();
  }

  /// Signs in with the connected wallet. Throws [SuiSignInException].
  Future<SuiSessionInfo> signIn({
    void Function(SuiSignInStep step, {String? message})? onProgress,
  }) async {
    final session = await client.signIn(onProgress: onProgress);
    _session = session;
    _checked = true;
    _switchedTo = null;
    _notify();
    return session;
  }

  Future<bool> signOut() async {
    signOutError = null;
    try {
      await client.signOut();
    } on SuiSignInException catch (e) {
      signOutError = e.message;
      _notify();
      return false;
    }
    _session = null;
    _switchedTo = null;
    _notify();
    return true;
  }

  /// The server no longer accepts the session (expired or signed out
  /// elsewhere).
  void sessionEnded() {
    if (_session == null) return;
    _session = null;
    _switchedTo = null;
    _notify();
  }

  void dismissSwitch() {
    _switchedTo = null;
    _notify();
  }

  /// The wallet's active address when it differs from the signed-in one.
  String? _mismatch() {
    final session = _session;
    final now = wallet.account?.address;
    if (session == null || now == null || now == session.address) return null;
    return now;
  }

  void _onWalletChange(SuiWalletChange change) {
    // A switch while the page is open, or a wallet that reconnects on
    // another account than the one signed in (switched while away).
    const relevant = {
      SuiWalletChangeType.accountChanged,
      SuiWalletChangeType.reconnected,
      SuiWalletChangeType.connected,
    };
    if (!relevant.contains(change.type)) return;
    final switched = _mismatch();
    if (switched == _switchedTo) return;
    _switchedTo = switched;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    wallet.dispose();
    client.close();
    super.dispose();
  }
}

/// `0x1234…abcd`.
String shortAddress(String address) => shortenSuiAddress(address);
