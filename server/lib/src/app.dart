import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sui_auth/sui_auth.dart';
import 'package:walrus_blob_check/walrus_blob_check.dart';

import 'api.dart';
import 'auth.dart';
import 'config.dart';
import 'json.dart';
import 'origin.dart';
import 'rate_limit.dart';
import 'store.dart';
import 'uploads.dart';
import 'validation.dart';
import 'web.dart';

/// Builds the full request handler: sign-in, API and web app.
///
/// There is no upload proxy: people store files on Walrus with their own
/// wallet, and `POST /api/uploads` checks the result on Sui.
///
/// [auth] defaults to [buildAuth] over the store's database, and
/// [blobChecker] to Mysten's GraphQL and the configured aggregator. Tests
/// pass their own (a local signature verifier, a fake clock, a fake chain).
Handler buildHandler({
  required ServerConfig config,
  required Store store,
  SuiAuth? auth,
  WalrusBlobChecker? blobChecker,
  RateLimiter? vaultLimiter,
  RateLimiter? uploadLimiter,
  DateTime Function()? clock,
  bool logRequests = false,
}) {
  final suiAuth =
      auth ??
      buildAuth(config, store.db, allowedOrigins: devAuthOrigins(config));
  final authHandlers = SuiAuthHandlers(
    suiAuth,
    log: logRequests ? (line) => print('auth: $line') : null,
  );
  final checker =
      blobChecker ??
      WalrusBlobChecker(
        chain: WalrusChain.parse(config.suiChain.id),
        graphqlUrl: config.graphqlUrl,
        aggregatorUrl: config.aggregatorUrl,
      );
  final api = Api(
    config: config,
    store: store,
    uploads: UploadClaims(
      config: config,
      store: store,
      checker: checker,
      limiter: uploadLimiter,
      clock: clock,
    ),
    vaultLimiter: vaultLimiter,
    clock: clock,
  ).handler;
  final web = WebAssets(config: config, store: store);
  final signInLimiter = RateLimiter(
    limit: 30,
    window: const Duration(minutes: 10),
    clock: clock,
  );

  Future<Response> route(Request request) async {
    final path = request.url.path;
    if ((path == 'api' || path.startsWith('api/')) &&
        !{'GET', 'HEAD', 'OPTIONS'}.contains(request.method)) {
      final origin = request.headers['origin'];
      final developmentOrigin = config.corsAllowOrigin;
      final allowed =
          origin == Uri.parse(config.siteUrl).origin ||
          developmentOrigin == '*' ||
          origin == developmentOrigin;
      if ((origin != null && !allowed) ||
          (origin == null &&
              request.headers['sec-fetch-site'] == 'cross-site')) {
        throw const ApiException(
          403,
          'ORIGIN_NOT_ALLOWED',
          'Open Credence on its own site to continue.',
        );
      }
    }
    if (path.startsWith('api/auth/')) {
      final info = request.context['shelf.io.connection_info'];
      final direct = info is HttpConnectionInfo
          ? info.remoteAddress.address
          : 'local';
      if (request.method == 'POST' &&
          {'api/auth/nonce', 'api/auth/verify'}.contains(path) &&
          !signInLimiter.allow(clientAddress(request, config, direct))) {
        throw const ApiException(
          429,
          'RATE_LIMITED',
          'Too many sign-in attempts. Try again in a few minutes.',
        );
      }
      return authHandlers.handler(request.change(path: 'api/auth'));
    }
    if (path == 'api' || path.startsWith('api/')) {
      return api(request.change(path: 'api'));
    }
    return web.handle(request);
  }

  var pipeline = const Pipeline()
      .addMiddleware(_errors())
      .addMiddleware(_securityHeaders(contentSecurityPolicy(config)))
      .addMiddleware(_cors(config.corsAllowOrigin));
  if (logRequests) pipeline = pipeline.addMiddleware(logRequestsSafely());
  return pipeline.addMiddleware(suiAuthMiddleware(suiAuth)).addHandler(route);
}

/// Logs method, path and status. Never logs query strings, headers or bodies.
Middleware logRequestsSafely() =>
    (inner) => (request) async {
      final watch = Stopwatch()..start();
      final response = await inner(request);
      print(
        '${DateTime.now().toUtc().toIso8601String()} ${request.method} '
        '/${request.url.path} ${response.statusCode} ${watch.elapsedMilliseconds}ms',
      );
      return response;
    };

Middleware _errors() =>
    (inner) => (request) async {
      try {
        return await inner(request);
      } on ApiException catch (e) {
        return errorResponse(e);
      } catch (e, st) {
        print('Unhandled error on /${request.url.path}: $e\n$st');
        return errorResponse(
          const ApiException(
            500,
            'INTERNAL',
            'Something went wrong on the server.',
          ),
        );
      }
    };

/// The Content-Security-Policy for every response.
///
/// Wallet-paid storage runs in the browser, so besides this server the page
/// talks to the aggregator (reads), a Sui full node (the Walrus writer reads
/// the chain over gRPC-web) and the upload relay (the file's bytes). Dartus
/// computes the blob ID with `walrus-wasm` in a module worker started from a
/// `blob:` URL, which needs `worker-src blob:` and `'wasm-unsafe-eval'`
/// (CanvasKit needs the latter too). Flutter sets inline styles. The one
/// inline script, on the landing page, is allowed by its hash. Wallet
/// extensions inject their own scripts, which a page's CSP does not govern.
String contentSecurityPolicy(ServerConfig config) {
  final connect = {
    "'self'",
    config.aggregatorUrl.origin,
    config.fullNodeUrl.origin,
    config.uploadRelayUrl.origin,
  };
  return [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval' '$landingInlineScriptHash'",
    "worker-src 'self' blob:",
    'connect-src ${connect.join(' ')}',
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    // Documents open in a new tab from a blob: URL, which inherits this
    // policy; Chrome's PDF viewer then counts as an object.
    "object-src 'self' blob:",
    "frame-src 'self' blob:",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join('; ');
}

/// SHA-256 of the landing page's one inline script,
/// `document.documentElement.classList.add('js');`, which marks that
/// JavaScript runs before the page paints. A test keeps it in step.
const landingInlineScriptHash =
    'sha256-/x7W7R75k8Roq0WaVRQX9blP4OufE5xbAdzklGxsgpw=';

Middleware _securityHeaders(String csp) =>
    (inner) => (request) async {
      final response = await inner(request);
      return response.change(
        headers: {
          'content-security-policy': csp,
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
          'x-frame-options': 'DENY',
          'permissions-policy': 'camera=(), microphone=(), geolocation=()',
        },
      );
    };

/// Extra origins allowed to sign in when CORS_ALLOW_ORIGIN names one
/// (development only). With no CORS setting only [ServerConfig.siteUrl]'s
/// origin may POST to /api/auth/*.
List<String>? devAuthOrigins(ServerConfig config) {
  final cors = config.corsAllowOrigin;
  if (cors == null || cors == '*') return null;
  return [Uri.parse(config.siteUrl).origin, cors];
}

/// Off unless CORS_ALLOW_ORIGIN is set (development and browser tests only;
/// never in production).
///
/// Sign-in needs cookies, so the request's origin is echoed back with
/// `access-control-allow-credentials`. With `CORS_ALLOW_ORIGIN='*'` (the
/// Chrome test runner serves from a random port) the `Origin` header of
/// sign-in requests is also dropped, so sui_auth's origin check accepts them.
/// This setting must stay disabled on a public deployment.
Middleware _cors(String? allowed) =>
    (inner) => (request) async {
      if (allowed == null) return inner(request);
      final origin = request.headers['origin'];
      final echo = allowed == '*' ? origin : allowed;
      final headers = {
        if (echo != null) 'access-control-allow-origin': echo,
        if (echo != null) 'access-control-allow-credentials': 'true',
        'access-control-allow-methods': 'GET, POST, PATCH, PUT, OPTIONS',
        'access-control-allow-headers': 'content-type',
        'access-control-max-age': '600',
        'vary': 'origin',
      };
      if (request.method == 'OPTIONS') {
        return Response(204, headers: headers);
      }
      var forward = request;
      if (allowed == '*' &&
          origin != null &&
          request.url.path.startsWith('api/auth/')) {
        forward = request.change(headers: {'origin': null});
      }
      final response = await inner(forward);
      return response.change(headers: headers);
    };
