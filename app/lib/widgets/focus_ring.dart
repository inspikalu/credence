import 'package:flutter/material.dart';

import '../platform/input_modality.dart';
import '../theme/tokens.dart';

/// Draws a clear outline when a descendant has keyboard focus.
///
/// Ink highlights are painted on the nearest [Material], so they hide behind
/// opaque decorations (selected toggles, white list panels). This ring is
/// painted in front instead: by default just outside the element with a
/// small gap, so it also shows on elements that already have a green border;
/// with [inset], inside the element (for full-width list rows).
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.child,
    this.radius = R.control,
    this.inset = false,
  });

  final Widget child;
  final double radius;
  final bool inset;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: ValueListenableBuilder<bool>(
        valueListenable: keyboardFocusVisible,
        builder: (context, keyboard, child) => CustomPaint(
          foregroundPainter: _RingPainter(
            visible: _focused && keyboard,
            radius: widget.radius,
            inset: widget.inset,
          ),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.visible,
    required this.radius,
    required this.inset,
  });

  final bool visible;
  final double radius;
  final bool inset;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    final rect = Offset.zero & size;
    final ring = inset ? rect.deflate(2.5) : rect.inflate(4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(ring, Radius.circular(radius + (inset ? 0 : 3))),
      Paint()
        ..color = C.ledger
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.visible != visible || old.radius != radius || old.inset != inset;
}
