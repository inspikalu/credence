import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'controller.dart';
import 'errors.dart';
import 'models.dart';

/// The signed-in owner, as the server reports it.
class SuiSessionInfo {
  const SuiSessionInfo({
    required this.address,
    required this.chain,
    required this.expiresAt,
    this.scheme,
  });

  /// Verified Sui address (owner of uploaded blobs).
  final String address;
  final String chain;
  final DateTime expiresAt;

  /// Signature scheme used to sign in (`ED25519`, `ZkLogin`, ...), when known.
  final String? scheme;

  String get shortAddress => shortenSuiAddress(address);

  factory SuiSessionInfo.fromJson(Map<String, dynamic> json) => SuiSessionInfo(
    address: json['address'] as String,
    chain: '${json['chain'] ?? ''}',
    expiresAt:
        DateTime.tryParse('${json['expiresAt']}')?.toUtc() ??
        DateTime.now().toUtc(),
    scheme: json['scheme'] as String?,
  );

  @override
  String toString() => 'SuiSessionInfo($shortAddress, $chain)';
}

/// Where [SuiSignInClient.signIn] is, for progress UI.
enum SuiSignInStep {
  /// Waiting for the wallet to approve the connection.
  connecting,

  /// Asking the server for a nonce and the message to sign.
  requestingChallenge,

  /// Waiting for the person to sign in the wallet.
  signing,

  /// The server is checking the signature.
  verifying,

  /// Signed in; the session cookie is set.
  done,
}

enum SuiSignInErrorKind {
  /// The wallet refused, timed out, etc. See [SuiSignInException.walletError].
  wallet,

  /// The server refused the sign-in (expired request, bad signature, ...).
  server,

  /// The server could not be reached.
  network,
}

class SuiSignInException implements Exception {
  const SuiSignInException(
    this.kind,
    this.message, {
    this.status,
    this.code,
    this.walletError,
  });

  final SuiSignInErrorKind kind;

  /// Plain text for people.
  final String message;

  /// HTTP status for [SuiSignInErrorKind.server].
  final int? status;

  /// Server error code, e.g. `NONCE_INVALID`, `MESSAGE_EXPIRED`.
  final String? code;
  final SuiWalletException? walletError;

  @override
  String toString() =>
      'SuiSignInException(${kind.name}${code == null ? '' : ', $code'}): '
      '$message';
}

/// Runs the browser half of Sign in with Sui against a `sui_auth` server:
/// connect → `POST nonce` → sign → `POST verify` (sets the session cookie).
///
/// The cookie is `HttpOnly`, so this class never sees the token; the
/// browser sends it with every same-origin request (including Dartus
/// uploads through the app's `/walrus` proxy).
class SuiSignInClient {
  SuiSignInClient({
    required this.wallet,
    Uri? authBase,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : authBase = authBase ?? Uri.base.resolve('/api/auth/'),
       _http = httpClient ?? http.Client();

  final SuiWalletController wallet;

  /// Where `SuiAuthHandlers` is mounted (ends with `/`).
  final Uri authBase;
  final Duration requestTimeout;
  final http.Client _http;

  /// The current session, or null when signed out.
  Future<SuiSessionInfo?> currentSession() async {
    final response = await _send(() => _http.get(authBase.resolve('session')));
    if (response.statusCode == 401) return null;
    return SuiSessionInfo.fromJson(_decode(response));
  }

  /// Signs in with the connected wallet (connecting [connectWith] first if
  /// no wallet is connected). Returns the new session.
  ///
  /// Throws [SuiSignInException].
  ///
  /// [onProgress] reports each step, with the message text once known (so
  /// the app can show what the wallet is asking the person to sign).
  Future<SuiSessionInfo> signIn({
    SuiWalletInfo? connectWith,
    void Function(SuiSignInStep step, {String? message})? onProgress,
  }) async {
    try {
      if (!wallet.isConnected) {
        final target = connectWith;
        if (target == null) {
          throw SuiWalletException.of(SuiWalletErrorKind.notConnected);
        }
        onProgress?.call(SuiSignInStep.connecting);
        await wallet.connect(target);
      }
      final address = wallet.account!.address;
      onProgress?.call(SuiSignInStep.requestingChallenge);

      final challenge = _decode(
        await _send(
          () => _http.post(
            authBase.resolve('nonce'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'address': address}),
          ),
        ),
      );
      final message = challenge['message'];
      if (message is! String) {
        throw const SuiSignInException(
          SuiSignInErrorKind.server,
          'The server did not send a message to sign.',
        );
      }

      onProgress?.call(SuiSignInStep.signing, message: message);
      final signed = await wallet.signPersonalMessage(utf8.encode(message));
      onProgress?.call(SuiSignInStep.verifying, message: message);

      final session = _decode(
        await _send(
          () => _http.post(
            authBase.resolve('verify'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'message': message,
              'signature': signed.signature,
            }),
          ),
        ),
      );
      final info = SuiSessionInfo.fromJson(session);
      onProgress?.call(SuiSignInStep.done, message: message);
      return info;
    } on SuiWalletException catch (e) {
      throw SuiSignInException(
        SuiSignInErrorKind.wallet,
        e.message,
        code: e.kind.name,
        walletError: e,
      );
    }
  }

  /// Ends the session on the server (clears the cookie). With
  /// [disconnectWallet], also forgets the wallet connection.
  Future<void> signOut({bool disconnectWallet = false}) async {
    final response = await _send(
      () => _http.post(
        authBase.resolve('sign-out'),
        headers: const {'content-type': 'application/json'},
        body: '{}',
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
    }
    if (disconnectWallet) await wallet.disconnect();
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(requestTimeout);
    } on TimeoutException {
      throw const SuiSignInException(
        SuiSignInErrorKind.network,
        'The server took too long to answer. Try again.',
      );
    } on http.ClientException {
      throw const SuiSignInException(
        SuiSignInErrorKind.network,
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      json = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (json is Map<String, dynamic>) return json;
      throw SuiSignInException(
        SuiSignInErrorKind.server,
        'The server sent an unreadable answer.',
        status: response.statusCode,
      );
    }
    final error = json is Map ? json['error'] : null;
    throw SuiSignInException(
      SuiSignInErrorKind.server,
      error is Map && error['message'] is String
          ? error['message'] as String
          : 'Sign-in failed (HTTP ${response.statusCode}).',
      status: response.statusCode,
      code: error is Map ? error['status'] as String? : null,
    );
  }

  void close() => _http.close();
}
