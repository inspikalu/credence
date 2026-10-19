import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui';

import 'package:web/web.dart' as web;

import '../services/file_rules.dart';
import 'browser.dart';

Browser createBrowser() => WebBrowser();

/// The real browser, through `package:web`.
class WebBrowser implements Browser {
  @override
  Uri get baseUri => Uri.base;

  @override
  Future<LocalFile?> pickFile({String accept = ''}) {
    final completer = Completer<LocalFile?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept;
    input.style.display = 'none';
    web.document.body?.append(input);

    void finish(LocalFile? file, [Object? error]) {
      input.remove();
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(file);
      }
    }

    input.addEventListener(
      'change',
      (web.Event _) {
        final files = input.files;
        if (files == null || files.length == 0) {
          finish(null);
          return;
        }
        final file = files.item(0)!;
        _readFile(file).then(
          (bytes) => finish(LocalFile(file.name, bytes)),
          onError: (Object e) => finish(null, e),
        );
      }.toJS,
    );
    input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
    input.click();
    return completer.future;
  }

  static Future<Uint8List> _readFile(web.File file) async {
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  DropListener? _listener;
  bool _dropInstalled = false;

  static bool _carriesFiles(web.DragEvent e) {
    final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
    return types.any((t) => t.toDart == 'Files');
  }

  @override
  void clearDropListener(DropListener listener) {
    if (identical(_listener, listener)) _listener = null;
  }

  @override
  void setDropListener(DropListener? listener) {
    _listener = listener;
    if (_dropInstalled) return;
    _dropInstalled = true;
    // Always stop the browser from navigating to a dropped file, which would
    // leave the page and lose what the person typed.
    web.window.addEventListener(
      'dragover',
      (web.DragEvent e) {
        if (!_carriesFiles(e)) return;
        e.preventDefault();
        final l = _listener;
        e.dataTransfer?.dropEffect = l == null ? 'none' : 'copy';
        l?.onDragOver(Offset(e.clientX.toDouble(), e.clientY.toDouble()));
      }.toJS,
    );
    web.window.addEventListener(
      'dragleave',
      (web.DragEvent e) {
        // relatedTarget is null when the pointer leaves the window.
        if (e.relatedTarget == null) _listener?.onDragLeave();
      }.toJS,
    );
    web.window.addEventListener(
      'drop',
      (web.DragEvent e) {
        if (!_carriesFiles(e)) return;
        e.preventDefault();
        final l = _listener;
        final files = e.dataTransfer?.files;
        if (l == null || files == null || files.length == 0) {
          l?.onDragLeave();
          return;
        }
        final file = files.item(0)!;
        final at = Offset(e.clientX.toDouble(), e.clientY.toDouble());
        _readFile(file).then(
          (bytes) =>
              _listener?.onDrop(DroppedFile(LocalFile(file.name, bytes), at)),
          onError: (Object _) => _listener?.onDragLeave(),
        );
      }.toJS,
    );
  }

  static String _objectUrl(Uint8List bytes, String contentType) {
    final blob = web.Blob(
      <web.BlobPart>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: contentType),
    );
    final url = web.URL.createObjectURL(blob);
    // Keep the URL alive long enough for the tab to load and reload.
    Timer(const Duration(minutes: 30), () => web.URL.revokeObjectURL(url));
    return url;
  }

  @override
  PendingTab? openPendingTab() {
    final tab = web.window.open('', '_blank');
    if (tab == null) return null;
    try {
      tab.document.title = 'Opening document…';
      tab.document.body?.textContent = 'Fetching the file from Walrus…';
    } catch (_) {
      // Some browsers isolate the new tab; the content still loads.
    }
    return _WebTab(tab);
  }

  @override
  bool openBytes(Uint8List bytes, String contentType) {
    final url = _objectUrl(bytes, contentType);
    return web.window.open(url, '_blank') != null;
  }

  @override
  void download(Uint8List bytes, String fileName, String contentType) {
    final url = _objectUrl(bytes, contentType);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName;
    a.style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
  }

  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  @override
  void write(String key, String? value) {
    try {
      if (value == null) {
        web.window.localStorage.removeItem(key);
      } else {
        web.window.localStorage.setItem(key, value);
      }
    } catch (_) {
      // Storage can be unavailable (private mode, quota). Not fatal.
    }
  }
}

class _WebTab implements PendingTab {
  _WebTab(this._tab);
  final web.Window _tab;

  @override
  void show(Uint8List bytes, String contentType, {String? title}) {
    _tab.location.href = WebBrowser._objectUrl(bytes, contentType);
  }

  @override
  void close() => _tab.close();
}
