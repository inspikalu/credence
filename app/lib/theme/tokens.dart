import 'package:flutter/material.dart';

/// Design tokens.
abstract final class C {
  static const paper = Color(0xFFF3F5F2);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0E1A16);
  static const inkMuted = Color(0xFF4A5852);
  static const inkFaint = Color(0xFF5E6B65);
  static const ledger = Color(0xFF0F4D3A);
  static const ledgerDeep = Color(0xFF0A3D2E);
  static const mint = Color(0xFFE2EEE7);
  static const rule = Color(0xFFCDD6D1);
  static const control = Color(0xFF76847D);
  static const crimson = Color(0xFFA1192F);
  static const crimsonTint = Color(0xFFF9E7EA);
  static const amber = Color(0xFF7A4E00);
  static const amberTint = Color(0xFFFBF0DA);
}

abstract final class Fonts {
  static const serif = 'SourceSerif4';
  static const sans = 'PublicSans';
  static const mono = 'IBMPlexMono';
}

/// 4 pt spacing scale.
abstract final class S {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const x12 = 48.0;
  static const x16 = 64.0;
}

abstract final class R {
  static const control = 3.0;
  static const panel = 6.0;
}

/// Motion vocabulary. Durations stay under
/// 300 ms; things enter with a strong ease-out and leave faster than they
/// came; nothing animates when the platform asks for reduced motion.
abstract final class Motion {
  /// Colour and opacity feedback (hover, focus, selected).
  static const micro = Duration(milliseconds: 120);

  /// Press feedback (scale to 0.97 and back).
  static const press = Duration(milliseconds: 160);

  /// Small state changes inside a panel.
  static const quick = Duration(milliseconds: 150);

  /// Something entering: a result, a dialog, a page.
  static const enter = Duration(milliseconds: 220);

  /// The same thing leaving: shorter than its entrance.
  static const exit = Duration(milliseconds: 140);

  /// A check result revealing itself.
  static const reveal = enter;

  /// Strong ease-out (Emil Kowalski): fast start, gentle settle.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Strong ease-in-out for things moving on screen.
  static const easeInOut = Cubic(0.77, 0, 0.175, 1);

  /// Press scale for buttons and other pressables.
  static const pressScale = 0.97;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Instant when the platform asks for reduced motion.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// Enter and exit timings for dialogs and popovers.
  static AnimationStyle dialogStyle(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: enter,
          reverseDuration: exit,
          curve: easeOut,
          reverseCurve: Curves.easeOut,
        );
}

/// Breakpoints used across screens.
abstract final class Breakpoints {
  static const tablet = 720.0;
  static const desktop = 1040.0;
  static const maxContent = 1120.0;
  static const maxProse = 640.0;

  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < tablet;
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktop;

  static double gutter(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= desktop) return S.x12;
    if (w >= tablet) return S.x8;
    return S.x4;
  }
}

/// Text styles. Sizes step up on wider screens.
abstract final class T {
  static TextStyle display(BuildContext c) => TextStyle(
    fontFamily: Fonts.serif,
    fontWeight: FontWeight.w600,
    fontSize: Breakpoints.isDesktop(c) ? 44 : 32,
    height: Breakpoints.isDesktop(c) ? 50 / 44 : 38 / 32,
    letterSpacing: -0.4,
    color: C.ink,
  );

  static TextStyle h1(BuildContext c) => TextStyle(
    fontFamily: Fonts.serif,
    fontWeight: FontWeight.w600,
    fontSize: Breakpoints.isDesktop(c) ? 34 : 26,
    height: Breakpoints.isDesktop(c) ? 40 / 34 : 32 / 26,
    letterSpacing: -0.2,
    color: C.ink,
  );

  static TextStyle h2(BuildContext c) => TextStyle(
    fontFamily: Fonts.serif,
    fontWeight: FontWeight.w600,
    fontSize: Breakpoints.isDesktop(c) ? 24 : 21,
    height: Breakpoints.isDesktop(c) ? 30 / 24 : 28 / 21,
    color: C.ink,
  );

  static const h3 = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 17,
    height: 24 / 17,
    color: C.ink,
  );

  /// Digits of equal width, so times, sizes and epochs line up and do not
  /// jitter when they change.
  static const tabular = [FontFeature.tabularFigures()];

  static const body = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 24 / 16,
    color: C.ink,
    fontFeatures: tabular,
  );

  static const bodyMuted = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 24 / 16,
    color: C.inkMuted,
    fontFeatures: tabular,
  );

  static const small = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 20 / 14,
    color: C.inkMuted,
    fontFeatures: tabular,
  );

  static const smallStrong = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 14,
    height: 20 / 14,
    color: C.ink,
    fontFeatures: tabular,
  );

  static const label = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.96,
    color: C.inkMuted,
    fontFeatures: tabular,
  );

  static const mono = TextStyle(
    fontFamily: Fonts.mono,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 22 / 14,
    color: C.ink,
  );

  static const monoSmall = TextStyle(
    fontFamily: Fonts.mono,
    fontWeight: FontWeight.w400,
    fontSize: 13,
    height: 20 / 13,
    color: C.ink,
  );
}
