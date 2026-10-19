import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'input_modality_stub.dart'
    if (dart.library.js_interop) 'input_modality_web.dart'
    as impl;

/// True after keyboard input, false after any pointer press: the
/// `:focus-visible` rule for Flutter. Focus rings show only when this is
/// true, so clicking a button does not leave a ring around it.
final ValueNotifier<bool> keyboardFocusVisible = ValueNotifier<bool>(false);

bool _installed = false;

/// Starts tracking the last input modality. Safe to call more than once.
void installInputModality() {
  if (_installed) return;
  _installed = true;
  HardwareKeyboard.instance.addHandler((event) {
    if (event is KeyDownEvent) keyboardFocusVisible.value = true;
    return false;
  });
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event is PointerDownEvent) keyboardFocusVisible.value = false;
  });
  // On the web, quick clicks on semantics nodes become semantic taps and
  // never reach the pointer router, so also listen to the page itself.
  impl.listenForPointerDown(() => keyboardFocusVisible.value = false);
}
