import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/checks.dart';
import '../services/hashing.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'common.dart';
import 'page_frame.dart';

/// Shows a check result with honest wording: what a match shows and what it
/// does not.
class CheckResultView extends StatelessWidget {
  const CheckResultView({
    super.key,
    required this.result,
    required this.document,
    required this.vault,
  });

  final CheckResult result;
  final DocumentRecord document;
  final Vault vault;

  @override
  Widget build(BuildContext context) {
    final e = explain(result, document, vault);
    final match = result.match;
    final bar = match ? C.ledger : C.crimson;
    final bg = match ? C.mint : C.crimsonTint;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.tablet;
    final diffAt = match
        ? -1
        : firstDifferentGroup(result.expected, result.computed);

    final shows = _List(
      title: 'What this shows',
      items: e.shows,
      icon: Icons.check,
      color: C.ledger,
    );
    final notShows = _List(
      title: 'What this does not show',
      items: e.doesNotShow,
      icon: Icons.remove,
      color: C.inkMuted,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.of(context, Motion.reveal),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(R.panel),
          border: Border(left: BorderSide(color: bar, width: 4)),
        ),
        padding: const EdgeInsets.all(S.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              label: '${e.headline}. ${e.summary}',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    match ? Icons.verified_outlined : Icons.cancel_outlined,
                    color: bar,
                    size: 28,
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.headline,
                          style: T.h2(context).copyWith(color: bar),
                        ),
                        const SizedBox(height: S.x1),
                        Text(e.summary, style: T.body),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: S.x4),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: shows),
                  const SizedBox(width: S.x6),
                  Expanded(child: notShows),
                ],
              )
            else ...[
              shows,
              const SizedBox(height: S.x4),
              notShows,
            ],
            if (e.issuerNote != null) ...[
              const SizedBox(height: S.x4),
              Text(e.issuerNote!, style: T.small.copyWith(color: C.ink)),
            ],
            if (e.websiteNote != null) ...[
              const SizedBox(height: S.x2),
              Text(e.websiteNote!, style: T.small.copyWith(color: C.ink)),
            ],
            const SizedBox(height: S.x4),
            const Divider(color: C.rule),
            const SizedBox(height: S.x3),
            const Eyebrow('Fingerprint in the record'),
            const SizedBox(height: S.x1),
            FingerprintText(result.expected, style: T.monoSmall),
            const SizedBox(height: S.x3),
            Eyebrow(
              result.source == CheckSource.copy
                  ? 'Fingerprint of your file'
                  : 'Fingerprint of the file from Walrus',
            ),
            const SizedBox(height: S.x1),
            FingerprintText(
              result.computed,
              style: T.monoSmall,
              highlightGroup: diffAt,
            ),
            const SizedBox(height: S.x3),
            Text(
              [
                if (result.fileName != null) result.fileName!,
                formatBytes(result.sizeBytes),
                'checked ${formatDateTime(result.checkedAt)}',
              ].join(' · '),
              style: T.small,
            ),
            if (!match && diffAt >= 0) ...[
              const SizedBox(height: S.x1),
              const Text(
                'The underlined group is where the fingerprints first differ.',
                style: T.small,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.title,
    required this.items,
    required this.icon,
    required this.color,
  });

  final String title;
  final List<String> items;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Eyebrow(title),
      const SizedBox(height: S.x2),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: S.x2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(item, style: T.small.copyWith(color: C.ink)),
              ),
            ],
          ),
        ),
    ],
  );
}
