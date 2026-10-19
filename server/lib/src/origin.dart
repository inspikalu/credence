import 'package:shelf/shelf.dart';

import 'config.dart';

/// Letters, digits, dots and hyphens, then an optional port. Nothing else
/// can reach a URL Credence writes into a page.
final _hostPattern = RegExp(r'^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$');

const _maxHostLength = 260;

/// The origin (`scheme://host[:port]`) Credence uses in absolute URLs it
/// writes into HTML: link previews, canonical URLs.
///
/// * `PUBLIC_BASE_URL` always wins. Production must set it.
/// * Otherwise the `Host` header, or `X-Forwarded-Host` and
///   `X-Forwarded-Proto` only when TRUST_PROXY=true.
/// * A host or scheme that fails the strict check falls back to
///   `PUBLIC_BASE_URL`, else `http://localhost:<PORT>`.
///
/// Never uses `request.requestedUri`: dart:io builds it from
/// `X-Forwarded-Host` and `X-Forwarded-Proto` whether or not a proxy is
/// trusted.
String publicOrigin(Request request, ServerConfig config) {
  final configured = config.publicBaseUrl;
  if (configured != null) return configured;
  final fallback = 'http://localhost:${config.port}';

  String? first(String? value) {
    if (value == null) return null;
    final part = value.split(',').first.trim();
    return part.isEmpty ? null : part;
  }

  final headers = request.headers;
  String? host = first(headers['host']);
  String scheme = 'http';
  if (config.trustProxy) {
    host = first(headers['x-forwarded-host']) ?? host;
    scheme = (first(headers['x-forwarded-proto']) ?? 'http').toLowerCase();
  }
  if (host == null || !isSafeHost(host)) return fallback;
  if (scheme != 'http' && scheme != 'https') return fallback;
  return '$scheme://${host.toLowerCase()}';
}

/// Whether [host] (with an optional port) is safe to put in a URL.
bool isSafeHost(String host) {
  if (host.length > _maxHostLength || !_hostPattern.hasMatch(host)) {
    return false;
  }
  final colon = host.indexOf(':');
  if (colon != -1) {
    final port = int.tryParse(host.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return false;
  }
  final name = colon == -1 ? host : host.substring(0, colon);
  return !name.startsWith('.') &&
      !name.startsWith('-') &&
      !name.endsWith('-') &&
      !name.contains('..');
}

/// Client address for rate limiting. `X-Forwarded-For` only counts when a
/// proxy is trusted, so a client cannot pick its own bucket.
String clientAddress(Request request, ServerConfig config, String direct) {
  if (!config.trustProxy) return direct;
  final forwarded = request.headers['x-forwarded-for'];
  final firstHop = forwarded?.split(',').first.trim();
  if (firstHop == null || firstHop.isEmpty || firstHop.length > 64) {
    return direct;
  }
  return RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(firstHop) ? firstHop : direct;
}
