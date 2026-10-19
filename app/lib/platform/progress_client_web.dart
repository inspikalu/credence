import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'progress_client.dart';

const reportsProgress = true;

http.Client createProgressClient(UploadProgress? Function() progress) =>
    _XhrClient(progress);

/// A `package:http` client over `XMLHttpRequest`, so uploads can report
/// progress (the same approach as Confetti's `XhrClient`). Used only for
/// Walrus traffic: the Sui full node and the upload relay. No cookies.
class _XhrClient extends http.BaseClient {
  _XhrClient(this._progress);

  final UploadProgress? Function() _progress;
  final _open = <web.XMLHttpRequest>{};

  static const _forbidden = {'content-length', 'host', 'connection'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final xhr = web.XMLHttpRequest();
    _open.add(xhr);
    xhr
      ..open(request.method, request.url.toString(), true)
      ..responseType = 'arraybuffer';
    request.headers.forEach((name, value) {
      if (!_forbidden.contains(name.toLowerCase())) {
        xhr.setRequestHeader(name, value);
      }
    });

    final completer = Completer<http.StreamedResponse>();
    final progress = _progress();
    if (progress != null && body.isNotEmpty) {
      xhr.upload.addEventListener(
        'progress',
        ((web.ProgressEvent e) {
          if (e.lengthComputable) progress(e.loaded, e.total);
        }).toJS,
      );
    }
    xhr.addEventListener(
      'load',
      ((web.Event _) {
        _open.remove(xhr);
        final buffer = xhr.response as JSArrayBuffer?;
        final bytes = buffer?.toDart.asUint8List() ?? Uint8List(0);
        completer.complete(
          http.StreamedResponse(
            Stream.value(bytes),
            xhr.status,
            contentLength: bytes.length,
            request: request,
            headers: _parseHeaders(xhr.getAllResponseHeaders()),
            reasonPhrase: xhr.statusText,
          ),
        );
      }).toJS,
    );
    void fail(String message) {
      _open.remove(xhr);
      if (!completer.isCompleted) {
        completer.completeError(http.ClientException(message, request.url));
      }
    }

    xhr
      ..addEventListener('error', ((web.Event _) => fail('Network error')).toJS)
      ..addEventListener(
        'abort',
        ((web.Event _) => fail('Request cancelled')).toJS,
      )
      ..addEventListener(
        'timeout',
        ((web.Event _) => fail('Request timed out')).toJS,
      );

    if (body.isEmpty) {
      xhr.send();
    } else {
      xhr.send(body.toJS);
    }
    return completer.future;
  }

  static Map<String, String> _parseHeaders(String raw) {
    final headers = <String, String>{};
    for (final line in raw.split('\r\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final name = line.substring(0, i).trim().toLowerCase();
      final value = line.substring(i + 1).trim();
      headers[name] = headers.containsKey(name)
          ? '${headers[name]}, $value'
          : value;
    }
    return headers;
  }

  @override
  void close() {
    for (final xhr in _open.toList()) {
      xhr.abort();
    }
    _open.clear();
  }
}
