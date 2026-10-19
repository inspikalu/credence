import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import '../services/file_rules.dart';
import 'browser_stub.dart'
    if (dart.library.js_interop) 'browser_web.dart'
    as impl;

/// A file dropped on the page, with where it was dropped (logical pixels).
class DroppedFile {
  const DroppedFile(this.file, this.position);
  final LocalFile file;
  final Offset position;
}

/// Drag-and-drop events from the page.
abstract interface class DropListener {
  void onDragOver(Offset position);
  void onDragLeave();
  void onDrop(DroppedFile dropped);
}

/// A tab opened before its content is ready (to avoid popup blockers).
abstract interface class PendingTab {
  /// Shows [bytes] in the tab as a file of [contentType].
  void show(Uint8List bytes, String contentType, {String? title});

  /// Closes the tab, for example when loading failed.
  void close();
}

/// Everything the app needs from the browser. Tests use [MemoryBrowser].
abstract class Browser {
  /// The real browser on web, an in-memory stand-in elsewhere.
  factory Browser() => impl.createBrowser();

  /// The page URL at start-up.
  Uri get baseUri;

  /// Opens the system file chooser. Null when the person cancels.
  Future<LocalFile?> pickFile({String accept = ''});

  /// Starts delivering page drag-and-drop events to [listener].
  void setDropListener(DropListener? listener);

  /// Stops delivering events, if [listener] is still the current one.
  void clearDropListener(DropListener listener);

  /// Opens an empty tab synchronously, inside a click handler. Null when the
  /// browser blocked it.
  PendingTab? openPendingTab();

  /// Opens [bytes] in a new tab (needs a recent click to avoid blockers).
  bool openBytes(Uint8List bytes, String contentType);

  /// Saves [bytes] as a download named [fileName].
  void download(Uint8List bytes, String fileName, String contentType);

  /// Small persistent key-value storage (localStorage on web).
  String? read(String key);
  void write(String key, String? value);
}

/// In-memory browser for tests and non-web runs.
class MemoryBrowser implements Browser {
  MemoryBrowser({Uri? baseUri, this.nextPick})
    : baseUri = baseUri ?? Uri.parse('http://localhost:8094/');

  @override
  final Uri baseUri;

  /// The file the next [pickFile] call returns.
  LocalFile? nextPick;
  final Map<String, String> storage = {};
  final List<({Uint8List bytes, String type})> opened = [];
  final List<String> downloads = [];
  DropListener? dropListener;

  @override
  Future<LocalFile?> pickFile({String accept = ''}) async {
    final file = nextPick;
    nextPick = null;
    return file;
  }

  @override
  void setDropListener(DropListener? listener) => dropListener = listener;

  @override
  void clearDropListener(DropListener listener) {
    if (identical(dropListener, listener)) dropListener = null;
  }

  @override
  PendingTab? openPendingTab() => _MemoryTab(this);

  @override
  bool openBytes(Uint8List bytes, String contentType) {
    opened.add((bytes: bytes, type: contentType));
    return true;
  }

  @override
  void download(Uint8List bytes, String fileName, String contentType) =>
      downloads.add(fileName);

  @override
  String? read(String key) => storage[key];

  @override
  void write(String key, String? value) {
    if (value == null) {
      storage.remove(key);
    } else {
      storage[key] = value;
    }
  }
}

class _MemoryTab implements PendingTab {
  _MemoryTab(this.browser);
  final MemoryBrowser browser;

  @override
  void show(Uint8List bytes, String contentType, {String? title}) =>
      browser.opened.add((bytes: bytes, type: contentType));

  @override
  void close() {}
}
