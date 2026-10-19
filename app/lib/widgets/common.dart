import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/hashing.dart';
import '../theme/tokens.dart';
import 'page_frame.dart';

enum Tone { info, success, warning, danger }

/// A message panel with a coloured bar. Never relies on colour alone: each
/// tone has its own icon and the text says what happened.
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.tone,
    required this.title,
    this.body,
    this.child,
    this.action,
    this.large = false,
  });

  final Tone tone;
  final String title;
  final String? body;
  final Widget? child;
  final Widget? action;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final (bg, bar, fg, icon) = switch (tone) {
      Tone.info => (C.surface, C.control, C.ink, Icons.info_outline),
      Tone.success => (C.mint, C.ledger, C.ledger, Icons.check_circle_outline),
      Tone.warning => (C.amberTint, C.amber, C.amber, Icons.schedule),
      Tone.danger => (C.crimsonTint, C.crimson, C.crimson, Icons.block),
    };
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(R.panel),
        border: Border(left: BorderSide(color: bar, width: 4)),
      ),
      padding: EdgeInsets.fromLTRB(
        S.x4,
        large ? S.x4 : S.x3,
        S.x4,
        large ? S.x4 : S.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: large ? 4 : 2),
            child: Icon(icon, color: fg, size: large ? 24 : 20),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: large
                      ? T.h2(context).copyWith(color: fg)
                      : T.h3.copyWith(color: tone == Tone.info ? C.ink : fg),
                ),
                if (body != null) ...[
                  const SizedBox(height: S.x1),
                  Text(body!, style: T.body.copyWith(color: C.ink)),
                ],
                if (child != null) ...[const SizedBox(height: S.x2), child!],
                if (action != null) ...[const SizedBox(height: S.x3), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small bordered tag: "Revoked", "PDF", "Organization".
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = C.inkMuted, this.fill});

  final String text;
  final Color color;
  final Color? fill;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: fill,
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(R.control),
    ),
    child: Text(
      text.toUpperCase(),
      style: T.label.copyWith(color: color, fontSize: 11, letterSpacing: 0.8),
    ),
  );
}

/// One label/value row of the ledger.
class LedgerRow {
  const LedgerRow(this.label, this.value);
  final String label;
  final Widget value;
}

/// Details laid out as a ledger: labels on the left (stacked on phones),
/// hairlines between rows.
class Ledger extends StatelessWidget {
  const Ledger({super.key, required this.rows, this.labelWidth = 150});

  final List<LedgerRow> rows;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = box.maxWidth < 480;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: i == 0
                        ? const BorderSide(color: C.rule)
                        : BorderSide.none,
                    bottom: const BorderSide(color: C.rule),
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: MergeSemantics(
                  child: stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Eyebrow(rows[i].label),
                            const SizedBox(height: S.x1),
                            rows[i].value,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: labelWidth,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Eyebrow(rows[i].label),
                              ),
                            ),
                            Expanded(child: rows[i].value),
                          ],
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Copies [text] and confirms with a short "Copied" state.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.label = 'Copy',
    this.semanticLabel,
    this.compact = false,
  });

  final String text;
  final String label;
  final String? semanticLabel;
  final bool compact;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

Future<bool> copyText(BuildContext context, String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } on Object {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy this text'),
        content: SelectableText(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    return false;
  }
}

class _CopyButtonState extends State<CopyButton> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final copied = await copyText(context, widget.text);
    if (!mounted || !copied) return;
    setState(() => _copied = true);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Copied',
        TextDirection.ltr,
      ),
    );
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = _copied ? 'Copied' : widget.label;
    final icon = Icon(_copied ? Icons.check : Icons.content_copy, size: 18);
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      excludeSemantics: true,
      child: widget.compact
          ? TextButton.icon(onPressed: _copy, icon: icon, label: Text(label))
          : OutlinedButton.icon(
              onPressed: _copy,
              icon: icon,
              label: Text(label),
            ),
    );
  }
}

/// A link shown in full with a copy button.
class LinkField extends StatelessWidget {
  const LinkField({
    super.key,
    required this.label,
    required this.url,
    this.help,
    this.secret = false,
  });

  final String label;
  final String url;
  final String? help;
  final bool secret;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Eyebrow(label, color: secret ? C.crimson : C.inkMuted),
            if (secret) ...[
              const SizedBox(width: S.x2),
              const Tag('Keep private', color: C.crimson),
            ],
          ],
        ),
        const SizedBox(height: S.x2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(S.x3, S.x1, S.x1, S.x1),
          decoration: BoxDecoration(
            color: C.surface,
            border: Border.all(color: C.control),
            borderRadius: BorderRadius.circular(R.control),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  // Shown without the scheme to fit; Copy copies the full URL.
                  url.replaceFirst(RegExp(r'^https?://'), ''),
                  style: T.monoSmall,
                  // Never cut a link short: people may copy it by hand.
                  minLines: 1,
                  maxLines: null,
                  semanticsLabel: '$label: $url',
                ),
              ),
              const SizedBox(width: S.x2),
              CopyButton(
                text: url,
                compact: true,
                semanticLabel: 'Copy ${label.toLowerCase()}',
              ),
            ],
          ),
        ),
        if (help != null) ...[
          const SizedBox(height: S.x2),
          Text(help!, style: T.small),
        ],
      ],
    );
  }
}

/// A SHA-256 fingerprint in mono, grouped by 8, optionally highlighting one
/// group (where two fingerprints first differ).
class FingerprintText extends StatelessWidget {
  const FingerprintText(
    this.hex, {
    super.key,
    this.highlightGroup = -1,
    this.highlightColor = C.crimson,
    this.style = T.mono,
  });

  final String hex;
  final int highlightGroup;
  final Color highlightColor;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final groups = groupFingerprint(hex);
    return Semantics(
      label: 'SHA-256 fingerprint ${groups.join(' ')}',
      excludeSemantics: true,
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        children: [
          for (var i = 0; i < groups.length; i++)
            Container(
              decoration: i == highlightGroup
                  ? BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: highlightColor, width: 2),
                      ),
                    )
                  : null,
              child: Text(
                groups[i],
                style: i == highlightGroup
                    ? style.copyWith(
                        color: highlightColor,
                        fontWeight: FontWeight.w500,
                      )
                    : style,
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-width loading state.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x16),
    child: Semantics(
      liveRegion: true,
      label: label,
      child: Column(
        children: [
          const SizedBox(width: 160, child: LinearProgressIndicator()),
          const SizedBox(height: S.x4),
          ExcludeSemantics(child: Text(label, style: T.small)),
        ],
      ),
    ),
  );
}

/// An error with a retry button.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x8),
    child: Notice(
      tone: Tone.danger,
      title: title,
      body: message,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
    ),
  );
}

/// Not-found page body, used by the router and by screens.
class NotFoundView extends StatelessWidget {
  const NotFoundView({
    super.key,
    this.title = 'Nothing here',
    this.message =
        'This link does not open anything on Credence. Check that it was '
        'copied in full.',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('Not found'),
            const SizedBox(height: S.x2),
            Semantics(header: true, child: Text(title, style: T.h1(context))),
            const SizedBox(height: S.x3),
            Text(message, style: T.bodyMuted),
            const SizedBox(height: S.x6),
            FilledButton(
              onPressed: () => context.go('/app'),
              child: const Text('Go to Credence home'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Wraps content in a [Panel] titled with a serif heading.
class TitledPanel extends StatelessWidget {
  const TitledPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(title, style: T.h2(context))),
        if (subtitle != null) ...[
          const SizedBox(height: S.x1),
          Text(subtitle!, style: T.small),
        ],
        const SizedBox(height: S.x4),
        child,
      ],
    ),
  );
}

/// "Owned by 0x1234…abcd", with the full address in a tooltip and a copy
/// button. The address is the vault owner's Sui address, which also owns
/// the Walrus blob objects.
class OwnerAddressLine extends StatelessWidget {
  const OwnerAddressLine({
    super.key,
    required this.address,
    this.prefix = 'Owned by',
  });

  final String address;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final short = address.length <= 12
        ? address
        : '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
    return Wrap(
      spacing: S.x1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(prefix, style: T.small),
        Tooltip(
          message: address,
          child: Semantics(
            label: '$prefix Sui address $address',
            excludeSemantics: true,
            child: Text(short, style: T.monoSmall.copyWith(color: C.ink)),
          ),
        ),
        CopyButton(
          text: address,
          compact: true,
          label: 'Copy address',
          semanticLabel: 'Copy the owner\'s Sui address',
        ),
      ],
    );
  }
}

/// Selectable monospace text (IDs, addresses) that screen readers can read.
///
/// On the web a `SelectableText` becomes an empty text field in the
/// semantics tree, and inside a merged ledger row it hid the whole row
/// (label and explanation included). The text is given to assistive
/// technology as a plain label instead; mouse users can still select it.
class SelectableValue extends StatelessWidget {
  const SelectableValue(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Semantics(
    label: text,
    child: ExcludeSemantics(child: SelectableText(text, style: style)),
  );
}
