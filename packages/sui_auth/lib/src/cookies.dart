/// Whether [host] is the local machine, where browsers allow cookies without
/// HTTPS only if they are not marked `Secure` (Safari in particular).
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h == '::1' || h == '[::1]') return true;
  return RegExp(r'^127(\.\d{1,3}){3}$').hasMatch(h);
}

final _cookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _cookieValue = RegExp(r'^[!#-+\--:<-\[\]-~]*$');

/// A `Set-Cookie` value for a session: `HttpOnly`, `SameSite=Lax`,
/// `Path=/`, and `Secure` when [secure] is true.
String sessionCookieHeader({
  required String name,
  required String token,
  required Duration maxAge,
  required bool secure,
}) {
  if (!_cookieName.hasMatch(name)) throw ArgumentError.value(name, 'name');
  if (!_cookieValue.hasMatch(token)) throw ArgumentError.value(token, 'token');
  return [
    '$name=$token',
    'Path=/',
    'Max-Age=${maxAge.inSeconds}',
    'HttpOnly',
    'SameSite=Lax',
    if (secure) 'Secure',
  ].join('; ');
}

/// A `Set-Cookie` value that deletes the session cookie.
String clearSessionCookieHeader({required String name, required bool secure}) {
  if (!_cookieName.hasMatch(name)) throw ArgumentError.value(name, 'name');
  return [
    '$name=',
    'Path=/',
    'Max-Age=0',
    'Expires=Thu, 01 Jan 1970 00:00:00 GMT',
    'HttpOnly',
    'SameSite=Lax',
    if (secure) 'Secure',
  ].join('; ');
}

/// Parses a `Cookie` request header into name/value pairs. The first value
/// wins when a name repeats.
Map<String, String> parseCookieHeader(String? header) {
  final cookies = <String, String>{};
  if (header == null || header.isEmpty) return cookies;
  for (final part in header.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final name = part.substring(0, eq).trim();
    var value = part.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    cookies.putIfAbsent(name, () => value);
  }
  return cookies;
}
