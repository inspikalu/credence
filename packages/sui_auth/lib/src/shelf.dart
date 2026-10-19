import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'bytes.dart';
import 'cookies.dart';
import 'store.dart';

/// Key under which [suiAuthMiddleware] stores the [SuiSession] in
/// `Request.context`.
const suiSessionContextKey = 'sui_auth.session';

extension SuiAuthRequest on Request {
  /// The signed-in session, when [suiAuthMiddleware] found a valid cookie.
  SuiSession? get suiSession => context[suiSessionContextKey] as SuiSession?;

  /// The verified Sui address of the signed-in owner, or null.
  String? get suiAddress => suiSession?.address;

  /// The raw session token from the cookie, if any.
  String? suiSessionToken(SuiAuthConfig config) =>
      parseCookieHeader(headers['cookie'])[config.cookieName];
}

/// Reads the session cookie and, when it is valid, puts the session in the
/// request context. Use [SuiAuthRequest.suiAddress] in handlers.
Middleware suiAuthMiddleware(SuiAuth auth) =>
    (inner) => (request) async {
      final token = request.suiSessionToken(auth.config);
      final session = token == null ? null : await auth.sessionForToken(token);
      if (session == null) return inner(request);
      return inner(request.change(context: {suiSessionContextKey: session}));
    };

/// Rejects requests without a session with a 401 JSON error. Place it after
/// [suiAuthMiddleware].
Middleware requireSuiSession() =>
    (inner) => (request) {
      if (request.suiSession == null) {
        return suiAuthErrorResponse(
          SuiAuthErrorCode.notSignedIn,
          'Sign in with your Sui wallet to continue.',
        );
      }
      return inner(request);
    };

/// JSON error in the same shape as the Walrus publisher (and the apps):
/// `{"error": {"code": 401, "status": "UNAUTHENTICATED", "message": "..."}}`.
Response suiAuthErrorResponse(SuiAuthErrorCode code, String message) =>
    Response(
      code.httpStatus,
      body: jsonEncode({
        'error': {
          'code': code.httpStatus,
          'status': code.status,
          'message': message,
        },
      }),
      headers: _jsonHeaders,
    );

const _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

/// HTTP endpoints for the browser flow. Mount under a prefix, for example:
///
/// ```dart
/// if (path.startsWith('api/auth/')) {
///   return authHandlers.handler(request.change(path: 'api/auth'));
/// }
/// ```
///
/// Routes (relative to the mount point):
/// * `POST nonce` `{"address": "0x…"}` → challenge JSON with `message`;
/// * `POST verify` `{"message": "…", "signature": "…"}` (or `messageBytes`
///   as base64) → sets the session cookie, returns the session;
/// * `GET session` → the current session, or 401;
/// * `POST sign-out` → clears the session and the cookie.
class SuiAuthHandlers {
  SuiAuthHandlers(this.auth, {this.log});

  final SuiAuth auth;

  /// Receives technical details of failed sign-ins (never secrets).
  final void Function(String message)? log;

  static const maxBodyBytes = 32 * 1024;

  Handler get handler => (request) {
    final path = request.url.path;
    switch (path) {
      case 'nonce':
        return _post(request, nonce);
      case 'verify':
        return _post(request, verify);
      case 'session':
        if (request.method != 'GET' && request.method != 'HEAD') {
          return _methodNotAllowed('GET');
        }
        return session(request);
      case 'sign-out':
        return _post(request, signOut);
      default:
        return Response.notFound(
          jsonEncode({
            'error': {
              'code': 404,
              'status': 'NOT_FOUND',
              'message': 'Unknown sign-in endpoint.',
            },
          }),
          headers: _jsonHeaders,
        );
    }
  };

  FutureOr<Response> _post(
    Request request,
    Future<Response> Function(Request) inner,
  ) {
    if (request.method != 'POST') return _methodNotAllowed('POST');
    final origin = request.headers['origin'];
    if (origin != null && !auth.config.allowedOrigins.contains(origin)) {
      return suiAuthErrorResponse(
        SuiAuthErrorCode.originNotAllowed,
        'Sign-in requests must come from this site.',
      );
    }
    return inner(request);
  }

  Response _methodNotAllowed(String allow) => Response(
    405,
    body: jsonEncode({
      'error': {
        'code': 405,
        'status': 'METHOD_NOT_ALLOWED',
        'message': 'Use $allow.',
      },
    }),
    headers: {..._jsonHeaders, 'allow': allow},
  );

  /// `POST nonce`: issues a challenge.
  Future<Response> nonce(Request request) => _guard(() async {
    final body = await _readJson(request, allowEmpty: true);
    final address = body['address'];
    if (address != null && address is! String) {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidRequest,
        'address must be a string.',
      );
    }
    final challenge = await auth.createChallenge(address: address as String?);
    return _json(challenge.toJson());
  });

  /// `POST verify`: checks the signature and sets the session cookie.
  Future<Response> verify(Request request) => _guard(() async {
    final contentType = request.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().startsWith('application/json')) {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidRequest,
        'Send JSON (content-type: application/json).',
      );
    }
    final body = await _readJson(request);
    final signature = body['signature'];
    if (signature is! String || signature.isEmpty) {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidRequest,
        'signature is required.',
      );
    }
    List<int> message;
    final messageBytes = body['messageBytes'];
    final messageText = body['message'];
    if (messageBytes is String) {
      try {
        message = decodeBase64(messageBytes);
      } on FormatException {
        throw const SuiAuthException(
          SuiAuthErrorCode.invalidRequest,
          'messageBytes must be base64.',
        );
      }
    } else if (messageText is String) {
      message = utf8.encode(messageText);
    } else {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidRequest,
        'message (text) or messageBytes (base64) is required.',
      );
    }
    final result = await auth.verifySignIn(
      message: message,
      signature: signature,
    );
    return _json(
      {...result.session.toJson(), 'scheme': result.scheme.label},
      headers: {
        'set-cookie': sessionCookieHeader(
          name: auth.config.cookieName,
          token: result.token,
          maxAge: auth.config.sessionTtl,
          secure: auth.config.secureCookies,
        ),
      },
    );
  });

  /// `GET session`: who is signed in.
  Future<Response> session(Request request) => _guard(() async {
    final session =
        request.suiSession ??
        await auth.sessionForToken(request.suiSessionToken(auth.config));
    if (session == null) {
      throw const SuiAuthException(
        SuiAuthErrorCode.notSignedIn,
        'Not signed in.',
      );
    }
    return _json(session.toJson());
  });

  /// `POST sign-out`: ends the session and clears the cookie.
  Future<Response> signOut(Request request) => _guard(() async {
    await auth.signOut(request.suiSessionToken(auth.config));
    return _json(
      {'signedOut': true},
      headers: {
        'set-cookie': clearSessionCookieHeader(
          name: auth.config.cookieName,
          secure: auth.config.secureCookies,
        ),
      },
    );
  });

  Future<Response> _guard(Future<Response> Function() body) async {
    try {
      return await body();
    } on SuiAuthException catch (e) {
      if (e.detail != null) log?.call('sign-in ${e.code.name}: ${e.detail}');
      return suiAuthErrorResponse(e.code, e.message);
    }
  }

  Response _json(Object body, {Map<String, String> headers = const {}}) =>
      Response.ok(jsonEncode(body), headers: {..._jsonHeaders, ...headers});

  Future<Map<String, Object?>> _readJson(
    Request request, {
    bool allowEmpty = false,
  }) async {
    final declared = request.contentLength;
    if (declared != null && declared > maxBodyBytes) {
      throw const SuiAuthException(
        SuiAuthErrorCode.invalidRequest,
        'Request body is too large.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        throw const SuiAuthException(
          SuiAuthErrorCode.invalidRequest,
          'Request body is too large.',
        );
      }
    }
    if (bytes.isEmpty && allowEmpty) return {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Fall through.
    }
    throw const SuiAuthException(
      SuiAuthErrorCode.invalidRequest,
      'Request body must be a JSON object.',
    );
  }
}
