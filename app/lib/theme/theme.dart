import 'package:flutter/material.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';

import '../platform/input_modality.dart';
import 'tokens.dart';

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: C.ledger,
    onPrimary: Colors.white,
    primaryContainer: C.mint,
    onPrimaryContainer: C.ledgerDeep,
    secondary: C.inkMuted,
    onSecondary: Colors.white,
    error: C.crimson,
    onError: Colors.white,
    errorContainer: C.crimsonTint,
    onErrorContainer: C.crimson,
    surface: C.surface,
    onSurface: C.ink,
    onSurfaceVariant: C.inkMuted,
    outline: C.control,
    outlineVariant: C.rule,
    surfaceContainerLowest: C.surface,
    surfaceContainerLow: C.paper,
    surfaceContainer: C.paper,
    surfaceContainerHigh: C.surface,
    surfaceContainerHighest: C.mint,
  );

  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.control),
        borderSide: BorderSide(color: color, width: width),
      );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(R.control),
  );
  const buttonText = TextStyle(
    fontFamily: Fonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 20 / 15,
    letterSpacing: 0.1,
  );
  const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 12);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.paper,
    fontFamily: Fonts.sans,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
    textTheme: const TextTheme(
      bodyLarge: T.body,
      bodyMedium: T.body,
      bodySmall: T.small,
      labelLarge: buttonText,
      titleMedium: T.h3,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: C.ledger,
      selectionColor: C.mint,
      selectionHandleColor: C.ledger,
    ),
    focusColor: C.mint,
    hoverColor: const Color(0x0F0F4D3A),
    dividerTheme: const DividerThemeData(color: C.rule, thickness: 1, space: 1),
    // Buttons draw their own fill and border inside a builder so the whole
    // button, not just its label, scales to 0.97 while pressed.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: const WidgetStatePropertyAll(buttonText),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? C.inkMuted : Colors.white,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundBuilder: pressableBackground(
          fill: (s) {
            if (s.contains(WidgetState.disabled)) return C.rule;
            if (s.contains(WidgetState.pressed) ||
                s.contains(WidgetState.hovered)) {
              return C.ledgerDeep;
            }
            return C.ledger;
          },
          border: (s) => _focusVisible(s)
              ? const BorderSide(color: C.ink, width: 3)
              : BorderSide.none,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
        padding: const WidgetStatePropertyAll(buttonPadding),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: const WidgetStatePropertyAll(buttonText),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? C.inkFaint : C.ink,
        ),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundBuilder: pressableBackground(
          fill: (s) =>
              s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)
              ? C.paper
              : C.surface,
          border: (s) {
            if (_focusVisible(s)) {
              return const BorderSide(color: C.ledger, width: 2);
            }
            if (s.contains(WidgetState.disabled)) {
              return const BorderSide(color: C.rule);
            }
            return const BorderSide(color: C.control);
          },
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        textStyle: WidgetStateProperty.resolveWith(
          (s) => buttonText.copyWith(
            decoration: s.contains(WidgetState.hovered)
                ? TextDecoration.underline
                : TextDecoration.none,
          ),
        ),
        foregroundColor: const WidgetStatePropertyAll(C.ledger),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundBuilder: pressableBackground(
          fill: (_) => Colors.transparent,
          border: (s) => _focusVisible(s)
              ? const BorderSide(color: C.ledger, width: 2)
              : BorderSide.none,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        foregroundColor: const WidgetStatePropertyAll(C.ink),
        shape: WidgetStatePropertyAll(buttonShape),
        side: WidgetStateProperty.resolveWith(
          (s) => _focusVisible(s)
              ? const BorderSide(color: C.ledger, width: 2)
              : BorderSide.none,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: T.body.copyWith(color: C.control),
      helperStyle: T.small,
      helperMaxLines: 3,
      errorStyle: T.small.copyWith(color: C.crimson),
      errorMaxLines: 3,
      border: border(C.control),
      enabledBorder: border(C.control),
      focusedBorder: border(C.ledger, 2),
      errorBorder: border(C.crimson),
      focusedErrorBorder: border(C.crimson, 2),
      disabledBorder: border(C.rule),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: C.ledger,
      linearTrackColor: C.rule,
      linearMinHeight: 4,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.ink,
      contentTextStyle: T.body.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.control),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.panel),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: Fonts.serif,
        fontWeight: FontWeight.w600,
        fontSize: 22,
        height: 28 / 22,
        color: C.ink,
      ),
      contentTextStyle: T.body,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: C.ink,
        borderRadius: BorderRadius.circular(R.control),
      ),
      textStyle: T.small.copyWith(color: Colors.white),
    ),
    datePickerTheme: const DatePickerThemeData(
      backgroundColor: C.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: C.ledger,
      headerForegroundColor: Colors.white,
    ),
    extensions: [
      // The wallet list in the sign-in dialog, in Credence's tokens: square
      // ledger corners, hairline rules, the mint selection fill.
      SuiWalletPickerTheme(
        tileColor: C.surface,
        tileHoverColor: C.mint,
        tileBorderColor: C.rule,
        tileSelectedBorderColor: C.ledger,
        tileRadius: BorderRadius.circular(R.control),
        tilePadding: const EdgeInsets.symmetric(
          horizontal: S.x3,
          vertical: S.x2,
        ),
        tileSpacing: S.x2,
        minTileHeight: 52,
        iconSize: 28,
        iconRadius: BorderRadius.circular(R.control),
        focusColor: C.ledger,
        progressColor: C.ledger,
        titleStyle: T.h3,
        nameStyle: T.body.copyWith(fontWeight: FontWeight.w600),
        bodyStyle: T.small,
        errorStyle: T.small.copyWith(color: C.crimson),
        errorBackgroundColor: C.crimsonTint,
        linkStyle: T.smallStrong.copyWith(
          color: C.ledger,
          decoration: TextDecoration.underline,
          decorationColor: C.ledger,
        ),
      ),
    ],
  );
}

/// Builds a button background that scales to [Motion.pressScale] while the
/// button is pressed, with a short ease-out, and stays still when the
/// platform asks for reduced motion.
ButtonLayerBuilder pressableBackground({
  required Color Function(Set<WidgetState>) fill,
  required BorderSide Function(Set<WidgetState>) border,
}) {
  return (context, states, child) {
    final pressed = states.contains(WidgetState.pressed);
    return AnimatedScale(
      scale: pressed && !Motion.reduced(context) ? Motion.pressScale : 1,
      duration: Motion.press,
      curve: Motion.easeOut,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill(states),
          borderRadius: BorderRadius.circular(R.control),
          border: Border.fromBorderSide(border(states)),
        ),
        child: child,
      ),
    );
  };
}

/// A filled button for destructive actions (revoke).
final ButtonStyle dangerButtonStyle = ButtonStyle(
  foregroundColor: WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.disabled) ? C.inkMuted : Colors.white,
  ),
  backgroundBuilder: pressableBackground(
    fill: (s) => s.contains(WidgetState.disabled) ? C.rule : C.crimson,
    border: (s) => _focusVisible(s)
        ? const BorderSide(color: C.ink, width: 3)
        : BorderSide.none,
  ),
);

/// Focused and reached by keyboard (the `:focus-visible` rule).
bool _focusVisible(Set<WidgetState> states) =>
    states.contains(WidgetState.focused) && keyboardFocusVisible.value;
