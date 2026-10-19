import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'errors.dart';
import 'models.dart';
import 'platform/platform.dart';

/// Visual settings for [SuiWalletPicker]. Add it to your `ThemeData`
/// extensions (or pass it to the widget) to match your design system.
/// Anything left null falls back to the ambient `Theme`.
@immutable
class SuiWalletPickerTheme extends ThemeExtension<SuiWalletPickerTheme> {
  const SuiWalletPickerTheme({
    this.tileColor,
    this.tileHoverColor,
    this.tileBorderColor,
    this.tileSelectedBorderColor,
    this.tileRadius,
    this.tilePadding,
    this.tileSpacing,
    this.minTileHeight,
    this.iconSize,
    this.iconRadius,
    this.focusColor,
    this.progressColor,
    this.titleStyle,
    this.nameStyle,
    this.bodyStyle,
    this.errorStyle,
    this.linkStyle,
    this.errorBackgroundColor,
  });

  final Color? tileColor;
  final Color? tileHoverColor;
  final Color? tileBorderColor;
  final Color? tileSelectedBorderColor;
  final BorderRadius? tileRadius;
  final EdgeInsetsGeometry? tilePadding;
  final double? tileSpacing;

  /// At least 44 logical pixels by default (touch target).
  final double? minTileHeight;
  final double? iconSize;
  final BorderRadius? iconRadius;
  final Color? focusColor;
  final Color? progressColor;
  final TextStyle? titleStyle;
  final TextStyle? nameStyle;
  final TextStyle? bodyStyle;
  final TextStyle? errorStyle;
  final TextStyle? linkStyle;
  final Color? errorBackgroundColor;

  /// [overrides] on top of the theme extension on top of Material defaults.
  static SuiWalletPickerTheme resolve(
    BuildContext context, [
    SuiWalletPickerTheme? overrides,
  ]) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final defaults = SuiWalletPickerTheme(
      tileColor: scheme.surface,
      tileHoverColor: scheme.surfaceContainerHighest,
      tileBorderColor: scheme.outlineVariant,
      tileSelectedBorderColor: scheme.primary,
      tileRadius: BorderRadius.circular(12),
      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      tileSpacing: 8,
      minTileHeight: 52,
      iconSize: 32,
      iconRadius: BorderRadius.circular(8),
      focusColor: scheme.primary,
      progressColor: scheme.primary,
      titleStyle: text.titleMedium,
      nameStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      bodyStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      errorStyle: text.bodyMedium?.copyWith(color: scheme.onErrorContainer),
      linkStyle: text.bodyMedium?.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      errorBackgroundColor: scheme.errorContainer,
    );
    return defaults
        .merge(theme.extension<SuiWalletPickerTheme>())
        .merge(overrides);
  }

  SuiWalletPickerTheme merge(SuiWalletPickerTheme? other) {
    if (other == null) return this;
    return copyWith(
      tileColor: other.tileColor,
      tileHoverColor: other.tileHoverColor,
      tileBorderColor: other.tileBorderColor,
      tileSelectedBorderColor: other.tileSelectedBorderColor,
      tileRadius: other.tileRadius,
      tilePadding: other.tilePadding,
      tileSpacing: other.tileSpacing,
      minTileHeight: other.minTileHeight,
      iconSize: other.iconSize,
      iconRadius: other.iconRadius,
      focusColor: other.focusColor,
      progressColor: other.progressColor,
      titleStyle: titleStyle?.merge(other.titleStyle) ?? other.titleStyle,
      nameStyle: nameStyle?.merge(other.nameStyle) ?? other.nameStyle,
      bodyStyle: bodyStyle?.merge(other.bodyStyle) ?? other.bodyStyle,
      errorStyle: errorStyle?.merge(other.errorStyle) ?? other.errorStyle,
      linkStyle: linkStyle?.merge(other.linkStyle) ?? other.linkStyle,
      errorBackgroundColor: other.errorBackgroundColor,
    );
  }

  @override
  SuiWalletPickerTheme copyWith({
    Color? tileColor,
    Color? tileHoverColor,
    Color? tileBorderColor,
    Color? tileSelectedBorderColor,
    BorderRadius? tileRadius,
    EdgeInsetsGeometry? tilePadding,
    double? tileSpacing,
    double? minTileHeight,
    double? iconSize,
    BorderRadius? iconRadius,
    Color? focusColor,
    Color? progressColor,
    TextStyle? titleStyle,
    TextStyle? nameStyle,
    TextStyle? bodyStyle,
    TextStyle? errorStyle,
    TextStyle? linkStyle,
    Color? errorBackgroundColor,
  }) => SuiWalletPickerTheme(
    tileColor: tileColor ?? this.tileColor,
    tileHoverColor: tileHoverColor ?? this.tileHoverColor,
    tileBorderColor: tileBorderColor ?? this.tileBorderColor,
    tileSelectedBorderColor:
        tileSelectedBorderColor ?? this.tileSelectedBorderColor,
    tileRadius: tileRadius ?? this.tileRadius,
    tilePadding: tilePadding ?? this.tilePadding,
    tileSpacing: tileSpacing ?? this.tileSpacing,
    minTileHeight: minTileHeight ?? this.minTileHeight,
    iconSize: iconSize ?? this.iconSize,
    iconRadius: iconRadius ?? this.iconRadius,
    focusColor: focusColor ?? this.focusColor,
    progressColor: progressColor ?? this.progressColor,
    titleStyle: titleStyle ?? this.titleStyle,
    nameStyle: nameStyle ?? this.nameStyle,
    bodyStyle: bodyStyle ?? this.bodyStyle,
    errorStyle: errorStyle ?? this.errorStyle,
    linkStyle: linkStyle ?? this.linkStyle,
    errorBackgroundColor: errorBackgroundColor ?? this.errorBackgroundColor,
  );

  @override
  SuiWalletPickerTheme lerp(SuiWalletPickerTheme? other, double t) {
    if (other == null) return this;
    return SuiWalletPickerTheme(
      tileColor: Color.lerp(tileColor, other.tileColor, t),
      tileHoverColor: Color.lerp(tileHoverColor, other.tileHoverColor, t),
      tileBorderColor: Color.lerp(tileBorderColor, other.tileBorderColor, t),
      tileSelectedBorderColor: Color.lerp(
        tileSelectedBorderColor,
        other.tileSelectedBorderColor,
        t,
      ),
      tileRadius: BorderRadius.lerp(tileRadius, other.tileRadius, t),
      tilePadding: EdgeInsetsGeometry.lerp(tilePadding, other.tilePadding, t),
      tileSpacing: lerpDouble(tileSpacing, other.tileSpacing, t),
      minTileHeight: lerpDouble(minTileHeight, other.minTileHeight, t),
      iconSize: lerpDouble(iconSize, other.iconSize, t),
      iconRadius: BorderRadius.lerp(iconRadius, other.iconRadius, t),
      focusColor: Color.lerp(focusColor, other.focusColor, t),
      progressColor: Color.lerp(progressColor, other.progressColor, t),
      titleStyle: TextStyle.lerp(titleStyle, other.titleStyle, t),
      nameStyle: TextStyle.lerp(nameStyle, other.nameStyle, t),
      bodyStyle: TextStyle.lerp(bodyStyle, other.bodyStyle, t),
      errorStyle: TextStyle.lerp(errorStyle, other.errorStyle, t),
      linkStyle: TextStyle.lerp(linkStyle, other.linkStyle, t),
      errorBackgroundColor: Color.lerp(
        errorBackgroundColor,
        other.errorBackgroundColor,
        t,
      ),
    );
  }
}

/// Words the picker shows. Override for your app's voice or language.
@immutable
class SuiWalletPickerStrings {
  const SuiWalletPickerStrings({
    this.title = 'Choose a wallet',
    this.searching = 'Looking for wallets…',
    this.noWallet = 'No Sui wallet found in this browser.',
    this.install = 'Install Slush',
    this.installHint = 'Then reload this page.',
    this.approveIn = 'Approve in',
    this.connected = 'Connected',
  });

  final String title;
  final String searching;
  final String noWallet;
  final String install;
  final String installHint;

  /// Shown as "Approve in Slush…" while a wallet is asking.
  final String approveIn;
  final String connected;
}

/// A minimal list of installed Sui wallets. Tapping one connects it.
///
/// It is deliberately plain: style it with [SuiWalletPickerTheme], change
/// the words with [strings], or replace tiles with [tileBuilder].
class SuiWalletPicker extends StatefulWidget {
  const SuiWalletPicker({
    super.key,
    required this.controller,
    this.onConnected,
    this.onError,
    this.theme,
    this.strings = const SuiWalletPickerStrings(),
    this.showTitle = true,
    this.installUrl = slushInstallUrl,
    this.onInstall,
    this.tileBuilder,
  });

  final SuiWalletController controller;
  final ValueChanged<SuiWalletAccount>? onConnected;
  final ValueChanged<SuiWalletException>? onError;
  final SuiWalletPickerTheme? theme;
  final SuiWalletPickerStrings strings;
  final bool showTitle;

  /// Where "Install Slush" goes.
  final String installUrl;

  /// Replaces opening [installUrl] in a new tab.
  final VoidCallback? onInstall;

  /// Custom tile. Call `onPressed` to connect.
  final Widget Function(
    BuildContext context,
    SuiWalletInfo wallet,
    SuiWalletTileState tileState,
    VoidCallback? onPressed,
  )?
  tileBuilder;

  @override
  State<SuiWalletPicker> createState() => _SuiWalletPickerState();
}

/// What a wallet tile should show.
enum SuiWalletTileState { idle, connecting, connected, disabled }

class _SuiWalletPickerState extends State<SuiWalletPicker> {
  SuiWalletException? _error;
  String? _pendingId;

  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  Future<void> _connect(SuiWalletInfo wallet) async {
    setState(() {
      _error = null;
      _pendingId = wallet.id;
    });
    try {
      final account = await widget.controller.connect(wallet);
      if (!mounted) return;
      setState(() => _pendingId = null);
      widget.onConnected?.call(account);
    } on SuiWalletException catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingId = null;
        _error = e;
      });
      widget.onError?.call(e);
    }
  }

  void _install() {
    final onInstall = widget.onInstall;
    if (onInstall != null) {
      onInstall();
    } else {
      openExternalUrl(widget.installUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SuiWalletPickerTheme.resolve(context, widget.theme);
    final s = widget.strings;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final children = <Widget>[
          if (widget.showTitle)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                container: true,
                header: true,
                child: Text(s.title, style: t.titleStyle),
              ),
            ),
        ];

        if (state.wallets.isEmpty && !state.discoveryComplete) {
          children.add(
            Row(
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: t.progressColor,
                  ),
                ),
                const SizedBox(width: 10),
                Text(s.searching, style: t.bodyStyle),
              ],
            ),
          );
        } else if (state.wallets.isEmpty) {
          children.addAll([
            Text(s.noWallet, style: t.bodyStyle),
            const SizedBox(height: 8),
            _PressableTile(
              theme: t,
              semanticLabel: '${s.install} (opens a new tab)',
              onPressed: _install,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s.install, style: t.linkStyle),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 16,
                    color: t.linkStyle?.color,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(s.installHint, style: t.bodyStyle),
          ]);
        } else {
          for (final wallet in state.wallets) {
            final tileState = _pendingId == wallet.id
                ? SuiWalletTileState.connecting
                : state.isConnected && state.wallet?.id == wallet.id
                ? SuiWalletTileState.connected
                : state.busy || _pendingId != null
                ? SuiWalletTileState.disabled
                : SuiWalletTileState.idle;
            final onPressed =
                tileState == SuiWalletTileState.idle ||
                    tileState == SuiWalletTileState.connected
                ? () => _connect(wallet)
                : null;
            children.add(
              Padding(
                padding: EdgeInsets.only(bottom: t.tileSpacing ?? 8),
                child:
                    widget.tileBuilder?.call(
                      context,
                      wallet,
                      tileState,
                      onPressed,
                    ) ??
                    _WalletTile(
                      wallet: wallet,
                      tileState: tileState,
                      theme: t,
                      strings: s,
                      onPressed: onPressed,
                    ),
              ),
            );
          }
        }

        final error = _error;
        if (error != null) {
          children.add(
            Semantics(
              container: true,
              liveRegion: true,
              child: Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: t.errorBackgroundColor,
                  borderRadius: t.tileRadius,
                ),
                child: Text(error.message, style: t.errorStyle),
              ),
            ),
          );
        }

        // Keep the title, each wallet and the error as separate nodes for
        // screen readers (inside a dialog they would otherwise merge).
        return Semantics(
          container: true,
          explicitChildNodes: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}

class _WalletTile extends StatelessWidget {
  const _WalletTile({
    required this.wallet,
    required this.tileState,
    required this.theme,
    required this.strings,
    required this.onPressed,
  });

  final SuiWalletInfo wallet;
  final SuiWalletTileState tileState;
  final SuiWalletPickerTheme theme;
  final SuiWalletPickerStrings strings;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    // Null when there is no status, so the name gets the whole row instead of
    // sharing it with an empty Flexible.
    final Widget? trailing = switch (tileState) {
      SuiWalletTileState.connecting => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '${strings.approveIn} ${wallet.name}…',
              style: t.bodyStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: t.progressColor,
            ),
          ),
        ],
      ),
      SuiWalletTileState.connected => Text(
        strings.connected,
        style: t.bodyStyle,
      ),
      _ => null,
    };
    return _PressableTile(
      theme: t,
      selected: tileState == SuiWalletTileState.connected,
      semanticLabel: tileState == SuiWalletTileState.connected
          ? '${wallet.name}, ${strings.connected.toLowerCase()}'
          : 'Connect with ${wallet.name}',
      onPressed: onPressed,
      child: Row(
        children: [
          SuiWalletIcon(
            wallet: wallet,
            size: t.iconSize ?? 32,
            borderRadius: t.iconRadius,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              wallet.name,
              style: t.nameStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(child: trailing),
          ],
        ],
      ),
    );
  }
}

/// A focusable, pressable surface: hover colour, a visible focus ring,
/// Enter/Space activation and a 0.97 press scale (off under reduced motion).
class _PressableTile extends StatefulWidget {
  const _PressableTile({
    required this.theme,
    required this.child,
    required this.onPressed,
    required this.semanticLabel,
    this.selected = false,
  });

  final SuiWalletPickerTheme theme;
  final Widget child;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final bool selected;

  @override
  State<_PressableTile> createState() => _PressableTileState();
}

class _PressableTileState extends State<_PressableTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final enabled = widget.onPressed != null;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final border = widget.selected
        ? t.tileSelectedBorderColor
        : t.tileBorderColor;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _pressed && !reduceMotion ? 0.97 : 1,
            duration: Duration(milliseconds: reduceMotion ? 0 : 120),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: Duration(milliseconds: reduceMotion ? 0 : 150),
              curve: Curves.easeOut,
              constraints: BoxConstraints(minHeight: t.minTileHeight ?? 52),
              padding: t.tilePadding,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: _hovered && enabled ? t.tileHoverColor : t.tileColor,
                borderRadius: t.tileRadius,
                border: Border.all(
                  color: _focused
                      ? (t.focusColor ?? Colors.blue)
                      : (border ?? Colors.transparent),
                  width: _focused || widget.selected ? 2 : 1,
                ),
              ),
              child: Opacity(opacity: enabled ? 1 : 0.55, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// A wallet's icon from its `data:` URI. PNG, WebP, GIF and JPEG decode in
/// Flutter; SVG (common for wallets) is drawn by the browser. Falls back to
/// the wallet's initial.
class SuiWalletIcon extends StatelessWidget {
  const SuiWalletIcon({
    super.key,
    required this.wallet,
    this.size = 32,
    this.borderRadius,
  });

  final SuiWalletInfo wallet;
  final double size;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final fallback = _Initial(name: wallet.name, size: size);
    final icon = wallet.icon;
    Widget image = fallback;
    if (icon.startsWith('data:image/')) {
      UriData? data;
      try {
        data = UriData.parse(icon);
      } on FormatException {
        data = null;
      }
      if (data != null) {
        if (data.mimeType == 'image/svg+xml') {
          image = Image.network(
            icon,
            width: size,
            height: size,
            fit: BoxFit.contain,
            webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
            errorBuilder: (_, _, _) => fallback,
            semanticLabel: '',
          );
        } else {
          image = Image.memory(
            data.contentAsBytes(),
            width: size,
            height: size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          );
        }
      }
    }
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.circular(size / 4),
        child: SizedBox.square(dimension: size, child: image),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: scheme.secondaryContainer,
      child: Text(
        letter,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.5,
        ),
      ),
    );
  }
}

/// Shows [SuiWalletPicker] in a dialog. Returns the account once connected,
/// or null if the dialog was dismissed.
Future<SuiWalletAccount?> showSuiWalletPicker(
  BuildContext context, {
  required SuiWalletController controller,
  SuiWalletPickerTheme? theme,
  SuiWalletPickerStrings strings = const SuiWalletPickerStrings(),
}) => showDialog<SuiWalletAccount>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SuiWalletPicker(
          controller: controller,
          theme: theme,
          strings: strings,
          onConnected: (account) => Navigator.of(context).pop(account),
        ),
      ),
    ),
  ),
);
