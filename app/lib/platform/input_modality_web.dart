import 'dart:js_interop';

import 'package:web/web.dart' as web;

void listenForPointerDown(void Function() onDown) {
  web.window.addEventListener(
    'pointerdown',
    ((web.Event _) => onDown()).toJS,
    web.AddEventListenerOptions(capture: true, passive: true),
  );
}
