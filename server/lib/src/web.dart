import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

import 'config.dart';
import 'origin.dart';
import 'store.dart';

/// Serves the landing page at `/` and the built Flutter web app everywhere
/// else. Unknown paths without a file extension get the app's `index.html`,
/// so links like `/app` and `/d/<id>` open the right screen.
class WebAssets {
  WebAssets({required this.config, required this.store});

  final ServerConfig config;
  final Store store;

  late final Handler _static = createStaticHandler(
    config.webDir,
    defaultDocument: 'index.html',
  );

  File get _indexFile => File(p.join(config.webDir, 'index.html'));

  /// The plain HTML landing page, shipped inside the web build.
  File get _landingFile => File(p.join(config.webDir, 'landing', 'index.html'));

  Future<Response> handle(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405, body: 'Method not allowed');
    }
    final path = request.url.path;
    final looksLikeFile = p.extension(path).isNotEmpty;
    if (looksLikeFile) {
      final response = await _static(request);
      if (response.statusCode == 404) {
        if (_fallbackFontPath.hasMatch(path)) return _missingFallbackFont();
        return Response.notFound('Not found');
      }
      final cacheControl = _cacheFor(path);
      final etag = _etagFor(response);
      if (etag != null && _matches(request.headers['if-none-match'], etag)) {
        return Response.notModified(
          headers: {'etag': etag, 'cache-control': cacheControl},
        );
      }
      return response.change(
        headers: {'cache-control': cacheControl, 'etag': ?etag},
      );
    }
    if (path.isEmpty && _landingFile.existsSync()) return _landing(request);
    return _index(request);
  }

  Future<Response> _landing(Request request) async {
    final html = absoluteSocialUrls(
      await _landingFile.readAsString(),
      base: publicOrigin(request, config),
      path: '/',
    );
    return Response.ok(
      request.method == 'HEAD' ? null : html,
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  /// A font the Flutter engine asks for when text has characters the bundled
  /// fonts do not cover (`fontFallbackBaseUrl` in `web/flutter_bootstrap.js`),
  /// for example `fonts/fallback/notosanssc/v37/<id>.118.woff2`.
  static final _fallbackFontPath = RegExp(
    r'^fonts/fallback/[a-z0-9]+/v[0-9]+/[A-Za-z0-9_.-]+[.]woff2$',
  );

  /// Answer for fallback fonts this server does not bundle (most CJK and
  /// other scripts): a valid font with no glyphs
  /// (`fonts/fallback/missing.woff2`).
  ///
  /// The engine retries a failed font download every time it lays out the
  /// text again (hundreds of requests a minute while someone types). A font
  /// it can load, even one without glyphs, stops that; the characters show
  /// as boxes, and nothing is fetched from a font CDN.
  Response _missingFallbackFont() {
    final file = File(
      p.join(config.webDir, 'fonts', 'fallback', 'missing.woff2'),
    );
    if (!file.existsSync()) return Response.notFound('Not found');
    return Response.ok(
      file.readAsBytesSync(),
      headers: {
        'content-type': 'font/woff2',
        'cache-control': 'public, max-age=86400',
        'x-credence-font': 'no-glyphs',
      },
    );
  }

  /// Fonts, icons and landing images do not change between builds, so
  /// browsers may keep them for a day. Everything else, including CanvasKit
  /// (which changes with the Flutter version) and the app's own scripts, is
  /// revalidated on every load with its ETag and costs a 304 when unchanged.
  static String _cacheFor(String path) {
    if (path.startsWith('assets/fonts/') ||
        path.startsWith('fonts/') ||
        path.startsWith('landing/fonts/') ||
        path.startsWith('landing/img/') ||
        path.startsWith('icons/')) {
      return 'public, max-age=86400';
    }
    return 'no-cache';
  }

  /// A weak validator from the file's size and modification time, which
  /// shelf_static reports. Rebuilding the app changes both.
  static String? _etagFor(Response response) {
    final length = response.headers['content-length'];
    final modified = response.headers['last-modified'];
    if (length == null || modified == null) return null;
    final stamp = modified.codeUnits.fold<int>(
      17,
      (h, c) => (h * 31 + c) & 0x7fffffff,
    );
    return 'W/"$length-${stamp.toRadixString(36)}"';
  }

  static bool _matches(String? ifNoneMatch, String etag) {
    if (ifNoneMatch == null) return false;
    final tag = etag.substring(2); // compare weakly: ignore W/
    return ifNoneMatch
        .split(',')
        .map((t) => t.trim())
        .any((t) => t == '*' || t == etag || t == tag || t == 'W/$tag');
  }

  Future<Response> _index(Request request) async {
    final file = _indexFile;
    if (!file.existsSync()) {
      return Response(
        503,
        body:
            'The web app is not built yet. Run `flutter build web` in app/, '
            'or set WEB_DIR.',
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    }
    var html = await file.readAsString();
    final segments = request.url.pathSegments;
    final headers = <String, String>{
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-cache',
    };
    html = absoluteSocialUrls(
      html,
      base: publicOrigin(request, config),
      path: encodePath(segments),
    );
    final meta = _metaFor(segments, request);
    if (meta != null) {
      html = injectMeta(
        html,
        title: meta.title,
        description: meta.description,
        url: meta.url,
      );
    }
    if (segments.isNotEmpty &&
        (segments.first == 'd' || segments.first == 'v')) {
      // Vaults and documents name real people. Keep them out of search.
      headers['x-robots-tag'] = 'noindex, nofollow';
    }
    return Response.ok(
      request.method == 'HEAD' ? null : html,
      headers: headers,
    );
  }

  ({String title, String description, String url})? _metaFor(
    List<String> segments,
    Request request,
  ) {
    final base = publicOrigin(request, config);
    if (segments.length == 2 && segments.first == 'd') {
      final doc = store.findDocument(segments[1]);
      if (doc == null) return null;
      final vault = store.findVault(doc['vaultId'] as String);
      final revoked = doc['revokedAt'] != null;
      return (
        title: '${revoked ? 'Revoked: ' : ''}${doc['title']} · Credence',
        description:
            'Check this document from ${vault?['name'] ?? 'a Credence vault'}. '
            'Issued by ${doc['issuerName']} to ${doc['recipientName']}.',
        url: '$base/d/${Uri.encodeComponent(doc['id'] as String)}',
      );
    }
    if (segments.length == 2 && segments.first == 'v') {
      final vault = store.findVault(segments[1]);
      if (vault == null) return null;
      return (
        title: '${vault['name']} · Credence vault',
        description:
            'Documents stored by ${vault['name']}. Open one to check a copy.',
        url: '$base/v/${Uri.encodeComponent(vault['id'] as String)}',
      );
    }
    return null;
  }
}

/// HTML escaping safe for attribute values (quoted with " or ') and text.
String escapeHtmlAttribute(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('`', '&#96;');

String _escape(String s) => escapeHtmlAttribute(s);

/// `/a/b` from decoded path segments, each URL-encoded again.
String encodePath(List<String> segments) =>
    '/${segments.map(Uri.encodeComponent).join('/')}';

/// Replaces the title, description and Open Graph tags in [html].
String injectMeta(
  String html, {
  required String title,
  required String description,
  required String url,
}) {
  final t = _escape(title);
  final d = _escape(description);
  final u = _escape(url);
  String replaceContent(
    String source,
    String attr,
    String name,
    String value,
  ) => source.replaceAllMapped(
    RegExp('(<meta\\s+$attr="$name"\\s+content=")[^"]*(")'),
    (m) => '${m[1]}$value${m[2]}',
  );
  var out = html.replaceFirst(
    RegExp(r'<title>[^<]*</title>'),
    '<title>$t</title>',
  );
  out = replaceContent(out, 'name', 'description', d);
  out = replaceContent(out, 'property', 'og:title', t);
  out = replaceContent(out, 'property', 'og:description', d);
  out = replaceContent(out, 'property', 'og:url', u);
  out = replaceContent(out, 'name', 'twitter:title', t);
  out = replaceContent(out, 'name', 'twitter:description', d);
  return out;
}

/// Link previews need absolute URLs for og:url and og:image.
String absoluteSocialUrls(
  String html, {
  required String base,
  required String path,
}) {
  final b = _escape(base);
  return html
      .replaceAllMapped(
        RegExp(
          r'(<meta\s+property="og:image"\s+content=")(?!https?:)/?([^"]*)(")',
        ),
        (m) => '${m[1]}$b/${m[2]}${m[3]}',
      )
      .replaceAllMapped(
        RegExp(r'(<meta\s+property="og:url"\s+content=")[^"]*(")'),
        (m) => '${m[1]}$b${_escape(path)}${m[2]}',
      );
}
