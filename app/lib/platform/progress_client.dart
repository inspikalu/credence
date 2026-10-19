import 'package:http/http.dart' as http;

import 'progress_client_stub.dart'
    if (dart.library.js_interop) 'progress_client_web.dart'
    as impl;

/// Reports how many bytes of a request body have been sent.
typedef UploadProgress = void Function(int sent, int total);

/// An HTTP client that reports upload progress through [onUpload].
///
/// In the browser it sends requests with `XMLHttpRequest`, whose upload
/// events `package:http`'s browser client does not expose. Dartus's
/// `WalrusWriter` takes any `http.Client`, so the upload to the Walrus relay
/// reports progress without Dartus knowing. With an [inner] client (tests)
/// or off the web, progress is reported once the request is sent.
class ProgressClient extends http.BaseClient {
  ProgressClient([http.Client? inner]) : _inner = inner;

  final http.Client? _inner;

  /// Called while a request body uploads. Set it around one upload.
  UploadProgress? onUpload;

  late final http.Client _platform = impl.createProgressClient(() => onUpload);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final inner = _inner;
    if (inner == null && impl.reportsProgress) return _platform.send(request);
    final response = await (inner ?? _platform).send(request);
    final length = request.contentLength ?? 0;
    if (length > 0) onUpload?.call(length, length);
    return response;
  }

  @override
  void close() {
    _inner?.close();
    _platform.close();
  }
}
