import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'address.dart';
import 'chain.dart';
import 'cookies.dart';
import 'message.dart';
import 'signature/graphql.dart';
import 'signature/scheme.dart';
import 'signature/verifier.dart';
import 'store.dart';

/// Settings for one site's sign-in.
class SuiAuthConfig {
  SuiAuthConfig({
    required this.domain,
    required this.uri,
    this.chain = SuiChain.testnet,
    this.statement = defaultStatement,
    this.challengeTtl = const Duration(minutes: 10),
    this.sessionTtl = const Duration(days: 30),
    this.clockSkew = const Duration(minutes: 1),
    this.cookieName = 'sui_session',
    bool? secureCookies,
    this.maxOutstandingNonces = 10000,
    List<String>? allowedOrigins,
  }) : secureCookies = secureCookies ?? !isLocalHost(uri.host),
       allowedOrigins = List.unmodifiable(allowedOrigins ?? [uri.origin]) {
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'must be an absolute URL');
    }
  }

  /// Builds a config from the site's public URL, for example
  /// `https://lectern.example` or `http://localhost:8091`.
  factory SuiAuthConfig.fromBaseUrl(
    String publicBaseUrl, {
    SuiChain chain = SuiChain.testnet,
    String? statement = defaultStatement,
    Duration challengeTtl = const Duration(minutes: 10),
    Duration sessionTtl = const Duration(days: 30),
    String cookieName = 'sui_session',
    bool? secureCookies,
    List<String>? allowedOrigins,
  }) {
    final base = Uri.parse(publicBaseUrl);
    final origin = Uri.parse(base.origin);
    return SuiAuthConfig(
      domain: origin.authority,
      uri: origin,
      chain: chain,
      statement: statement,
      challengeTtl: challengeTtl,
      sessionTtl: sessionTtl,
      cookieName: cookieName,
      secureCookies: secureCookies,
      allowedOrigins: allowedOrigins,
    );
  }

  static const defaultStatement =
      'Sign in with your Sui account. This does not send a transaction '
      'or cost any gas.';

  /// `host[:port]` shown at the top of the message.
  final String domain;

  /// The site's origin, shown as `URI:`.
  final Uri uri;
  final SuiChain chain;
  final String? statement;

  /// How long a nonce (and the message carrying it) stays valid.
  final Duration challengeTtl;
  final Duration sessionTtl;

  /// Allowance for clocks that run slightly ahead.
  final Duration clockSkew;

  /// Use a different name per app when several apps share a host (cookies
  /// ignore ports, so `localhost:8091` and `localhost:8092` share cookies).
  final String cookieName;

  /// Defaults to true unless [uri] is on localhost.
  final bool secureCookies;
  final int maxOutstandingNonces;

  /// Origins allowed to POST to the auth endpoints.
  final List<String> allowedOrigins;
}

enum SuiAuthErrorCode {
  invalidRequest(400, 'INVALID_ARGUMENT'),
  invalidMessage(400, 'INVALID_MESSAGE'),
  wrongDomain(400, 'WRONG_DOMAIN'),
  wrongUri(400, 'WRONG_URI'),
  wrongChain(400, 'WRONG_CHAIN'),
  messageExpired(401, 'MESSAGE_EXPIRED'),
  messageNotYetValid(401, 'MESSAGE_NOT_YET_VALID'),
  unknownNonce(401, 'NONCE_INVALID'),
  nonceAddressMismatch(401, 'NONCE_ADDRESS_MISMATCH'),
  invalidSignature(401, 'INVALID_SIGNATURE'),
  addressMismatch(401, 'ADDRESS_MISMATCH'),
  unsupportedScheme(400, 'UNSUPPORTED_SIGNATURE_SCHEME'),
  verifierUnavailable(503, 'VERIFIER_UNAVAILABLE'),
  tooManyRequests(429, 'RESOURCE_EXHAUSTED'),
  notSignedIn(401, 'UNAUTHENTICATED'),
  originNotAllowed(403, 'ORIGIN_NOT_ALLOWED');

  const SuiAuthErrorCode(this.httpStatus, this.status);

  final int httpStatus;

  /// Machine-readable code sent to clients as `error.status`.
  final String status;
}

class SuiAuthException implements Exception {
  const SuiAuthException(this.code, this.message, {this.detail});

  final SuiAuthErrorCode code;

  /// Plain text that can be shown to the person signing in.
  final String message;

  /// Technical detail for logs (never secret, may be null).
  final String? detail;

  @override
  String toString() =>
      'SuiAuthException(${code.name}): $message'
      '${detail == null ? '' : ' [$detail]'}';
}

/// A fresh nonce, and the message to sign when the address was known.
class SignInChallenge {
  const SignInChallenge({
    required this.nonce,
    required this.issuedAt,
    required this.expirationTime,
    required this.config,
    this.message,
  });

  final String nonce;
  final DateTime issuedAt;
  final DateTime expirationTime;
  final SuiAuthConfig config;
  final SuiSignInMessage? message;

  Map<String, Object?> toJson() => {
    'nonce': nonce,
    'domain': config.domain,
    'uri': config.uri.toString(),
    'chain': config.chain.id,
    'version': '1',
    'statement': config.statement,
    'issuedAt': SuiSignInMessage.formatTimestamp(issuedAt),
    'expirationTime': SuiSignInMessage.formatTimestamp(expirationTime),
    if (message != null) 'address': message!.address,
    if (message != null) 'message': message!.toMessage(),
  };
}

class SignInResult {
  const SignInResult({
    required this.token,
    required this.session,
    required this.scheme,
  });

  /// The raw session token. Put it in the cookie; never store it.
  final String token;
  final SuiSession session;
  final SuiSignatureScheme scheme;

  String get address => session.address;
}

/// Sign in with Sui: challenges, verification and sessions.
class SuiAuth {
  SuiAuth({
    required this.config,
    required this.nonces,
    required this.sessions,
    SuiSignatureVerifier? verifier,
    DateTime Function()? clock,
    Random? random,
  }) : verifier =
           verifier ??
           SuiSignatureVerifier(
             remote: SuiGraphQLVerifier.forChain(config.chain),
           ),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final SuiAuthConfig config;
  final NonceStore nonces;
  final SessionStore sessions;
  final SuiSignatureVerifier verifier;
  final DateTime Function() _clock;
  final Random _random;
  int _issued = 0;

  /// Current time in UTC, truncated to milliseconds (what messages carry).
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(
    _clock().millisecondsSinceEpoch,
    isUtc: true,
  );

  /// Issues a single-use nonce. With [address], the nonce is bound to it and
  /// the full message to sign is returned.
  Future<SignInChallenge> createChallenge({String? address}) async {
    String? normalized;
    if (address != null) {
      normalized = tryNormalizeSuiAddress(address);
      if (normalized == null) {
        throw const SuiAuthException(
          SuiAuthErrorCode.invalidRequest,
          'That is not a Sui address.',
        );
      }
    }
    final now = this.now();
    if (_issued++ % 32 == 0) await nonces.deleteExpiredNonces(now);
    if (await nonces.countNonces() >= config.maxOutstandingNonces) {
      await nonces.deleteExpiredNonces(now);
      if (await nonces.countNonces() >= config.maxOutstandingNonces) {
        throw const SuiAuthException(
          SuiAuthErrorCode.tooManyRequests,
          'Too many sign-in attempts right now. Try again in a few minutes.',
        );
      }
    }
    final nonce = generateNonce(_random);
    final expires = now.add(config.challengeTtl);
    await nonces.saveNonce(
      NonceRecord(
        nonce: nonce,
        address: normalized,
        createdAt: now,
        expiresAt: expires,
      ),
    );
    return SignInChallenge(
      nonce: nonce,
      issuedAt: now,
      expirationTime: expires,
      config: config,
      message: normalized == null
          ? null
          : SuiSignInMessage(
              domain: config.domain,
              address: normalized,
              statement: config.statement,
              uri: config.uri,
              chainId: config.chain.id,
              nonce: nonce,
              issuedAt: now,
              expirationTime: expires,
            ),
    );
  }

  /// Checks a signed sign-in message and starts a session.
  ///
  /// [message] is the exact bytes the wallet signed (UTF-8 text);
  /// [signature] is the wallet's base64 serialized signature.
  Future<SignInResult> verifySignIn({
    required List<int> message,
    required String signature,
  }) async {
    final now = this.now();
    final SuiSignInMessage parsed;
    try {
      parsed = SuiSignInMessage.parse(utf8.decode(message));
    } on FormatException {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidMessage,
        'The signed message is not valid text.',
      );
    } on SuiSignInMessageFormatException catch (e) {
      throw SuiAuthException(
        SuiAuthErrorCode.invalidMessage,
        'The signed message is not a sign-in request from this site.',
        detail: e.message,
      );
    }

    if (parsed.domain != config.domain) {
      throw SuiAuthException(
        SuiAuthErrorCode.wrongDomain,
        'This sign-in request is for a different site.',
        detail: 'domain ${parsed.domain}',
      );
    }
    if (parsed.uri.toString() != config.uri.toString()) {
      throw SuiAuthException(
        SuiAuthErrorCode.wrongUri,
        'This sign-in request is for a different site.',
        detail: 'uri ${parsed.uri}',
      );
    }
    if (parsed.chainId != config.chain.id) {
      throw SuiAuthException(
        SuiAuthErrorCode.wrongChain,
        'This sign-in request is for a different Sui network.',
        detail: 'chain ${parsed.chainId}',
      );
    }
    final expiration = parsed.expirationTime;
    if (expiration == null) {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidMessage,
        'The sign-in request has no expiry time.',
      );
    }
    if (!now.isBefore(expiration) ||
        parsed.issuedAt.isBefore(
          now.subtract(config.challengeTtl + config.clockSkew),
        )) {
      throw const SuiAuthException(
        SuiAuthErrorCode.messageExpired,
        'This sign-in request has expired. Start again.',
      );
    }
    if (parsed.issuedAt.isAfter(now.add(config.clockSkew)) ||
        (parsed.notBefore != null &&
            now.add(config.clockSkew).isBefore(parsed.notBefore!))) {
      throw const SuiAuthException(
        SuiAuthErrorCode.messageNotYetValid,
        'This sign-in request is not valid yet. Check your clock.',
      );
    }

    // Single use: the nonce is spent whatever happens next.
    final record = await nonces.takeNonce(parsed.nonce);
    if (record == null || !now.isBefore(record.expiresAt)) {
      throw const SuiAuthException(
        SuiAuthErrorCode.unknownNonce,
        'This sign-in request was already used or has expired. Start again.',
      );
    }
    if (record.address != null && record.address != parsed.address) {
      throw const SuiAuthException(
        SuiAuthErrorCode.nonceAddressMismatch,
        'This sign-in request was made for a different account. Start again.',
      );
    }

    final VerifiedSignature verified;
    try {
      verified = await verifier.verifyPersonalMessage(
        message: message,
        signature: signature,
        address: parsed.address,
      );
    } on SuiSignatureException catch (e) {
      throw _fromSignatureError(e);
    }

    final token = generateSessionToken(_random);
    final session = SuiSession(
      tokenHash: hashSessionToken(token),
      address: verified.address,
      chainId: config.chain.id,
      createdAt: now,
      expiresAt: now.add(config.sessionTtl),
    );
    await sessions.saveSession(session);
    return SignInResult(
      token: token,
      session: session,
      scheme: verified.scheme,
    );
  }

  /// [verifySignIn] for a message given as text.
  Future<SignInResult> verifySignInText({
    required String message,
    required String signature,
  }) => verifySignIn(
    message: Uint8List.fromList(utf8.encode(message)),
    signature: signature,
  );

  /// The live session for a raw cookie token, or null.
  Future<SuiSession?> sessionForToken(String? token) async {
    if (token == null || token.isEmpty || token.length > 256) return null;
    final session = await sessions.findSession(hashSessionToken(token));
    if (session == null) return null;
    if (!now().isBefore(session.expiresAt)) {
      await sessions.deleteSession(session.tokenHash);
      return null;
    }
    return session;
  }

  /// Ends the session for [token] (if any).
  Future<void> signOut(String? token) async {
    if (token == null || token.isEmpty || token.length > 256) return;
    await sessions.deleteSession(hashSessionToken(token));
  }

  /// Ends every session of [address], on every device.
  Future<int> signOutEverywhere(String address) =>
      sessions.deleteSessionsForAddress(normalizeSuiAddress(address));

  /// Deletes expired nonces and sessions.
  Future<void> purgeExpired() async {
    final now = this.now();
    await nonces.deleteExpiredNonces(now);
    await sessions.deleteExpiredSessions(now);
  }

  static SuiAuthException _fromSignatureError(SuiSignatureException e) {
    switch (e.code) {
      case SuiSignatureErrorCode.malformed:
      case SuiSignatureErrorCode.invalidSignature:
        return SuiAuthException(
          SuiAuthErrorCode.invalidSignature,
          'The wallet signature did not check out. Try signing in again.',
          detail: e.message,
        );
      case SuiSignatureErrorCode.addressMismatch:
        return SuiAuthException(
          SuiAuthErrorCode.addressMismatch,
          'The signature came from a different account than the one in the '
          'request. Try again.',
          detail: e.message,
        );
      case SuiSignatureErrorCode.unsupportedScheme:
        return SuiAuthException(
          SuiAuthErrorCode.unsupportedScheme,
          'This wallet signs in a way this site does not support yet'
          '${e.scheme == null ? '' : ' (${e.scheme!.label})'}. '
          'Try another account or wallet.',
          detail: e.message,
        );
      case SuiSignatureErrorCode.verifierUnavailable:
        return SuiAuthException(
          SuiAuthErrorCode.verifierUnavailable,
          'Could not reach the Sui network to check your sign-in. '
          'Try again in a moment.',
          detail: e.message,
        );
    }
  }
}
