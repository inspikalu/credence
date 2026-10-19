import 'package:http/http.dart' as http;

import 'http_client_stub.dart'
    if (dart.library.js_interop) 'http_client_web.dart'
    as impl;

/// An HTTP client that sends the session cookie with requests to the
/// Credence server.
///
/// In production the app and the API share an origin, so the browser sends
/// the cookie anyway. With `--dart-define=CREDENCE_SERVER=…` (development)
/// or in the Chrome test, the API is on another port, which needs
/// `withCredentials`.
http.Client createCredentialedClient() => impl.createCredentialedClient();
