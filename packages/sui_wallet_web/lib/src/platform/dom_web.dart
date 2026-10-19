// Small, dependency-free DOM bindings (no package:web, so apps can use any
// version of it).
import 'dart:js_interop';

@JS('document')
external DomDocument get domDocument;

extension type DomDocument._(JSObject _) implements JSObject {
  external DomElement createElement(String tag);
  external DomElement? get head;
  external DomElement get documentElement;
  external DomElement? getElementById(String id);
}

extension type DomElement._(JSObject _) implements JSObject {
  external set id(String value);
  external set text(String value);
  external set src(String value);
  external set async(bool value);
  external set onload(JSFunction? handler);
  external set onerror(JSFunction? handler);
  external void appendChild(DomElement child);
}

extension type DomStorage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('localStorage')
external DomStorage? get _localStorage;

@JS('open')
external JSAny? _open(String url, String target, String features);

/// `localStorage`, or null when the browser blocks it.
DomStorage? get localStorageOrNull {
  try {
    return _localStorage;
  } catch (_) {
    return null;
  }
}

/// Runs [source] as an inline `<script>` (executes synchronously).
void injectInlineScript(String source, {required String id}) {
  if (domDocument.getElementById(id) != null) return;
  final script = domDocument.createElement('script')
    ..id = id
    ..text = source;
  (domDocument.head ?? domDocument.documentElement).appendChild(script);
}

/// Loads [url] as a `<script src>`; calls [onLoad] when it has run.
void injectScriptUrl(
  String url, {
  required String id,
  void Function()? onLoad,
  void Function()? onError,
}) {
  if (domDocument.getElementById(id) != null) return;
  final script = domDocument.createElement('script')
    ..id = id
    ..async = true
    ..src = url;
  if (onLoad != null) script.onload = (() => onLoad()).toJS;
  if (onError != null) script.onerror = (() => onError()).toJS;
  (domDocument.head ?? domDocument.documentElement).appendChild(script);
}

/// Opens [url] in a new tab without giving it a handle on this page.
void openInNewTab(String url) {
  _open(url, '_blank', 'noopener,noreferrer');
}
