import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/services.dart';
import '../theme/tokens.dart';
import 'focus_ring.dart';
import 'mark.dart';
import 'sign_in.dart';

/// The shared page shell: ledger rule, top bar, centred content, footer.
class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.child,
    this.context,
    this.maxWidth = Breakpoints.maxContent,
  });

  final Widget child;

  /// Short text on the right of the top bar ("Vault", "Manage").
  final String? context;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = Breakpoints.gutter(context);
    final account = AccountScope.maybeOf(context);
    final showSwitch = account?.switchedTo != null && account?.signedIn == true;
    return Scaffold(
      body: Column(
        children: [
          Container(height: 4, color: C.ledger),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _TopBar(label: this.context, maxWidth: maxWidth),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, S.x12),
                        // Always a Column, with the page keyed, so showing or
                        // hiding the notice keeps the page's state (a half
                        // filled form, a paid upload waiting to finish).
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showSwitch)
                              const SizedBox(
                                width: double.infinity,
                                child: AccountSwitchNotice(),
                              ),
                            KeyedSubtree(
                              key: const ValueKey('page'),
                              child: child,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _Footer(maxWidth: maxWidth),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({this.label, required this.maxWidth});

  final String? label;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = Breakpoints.gutter(context);
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: C.rule)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 10),
            child: Row(
              children: [
                Semantics(
                  link: true,
                  linkUrl: Uri.parse('/app'),
                  label: 'Credence home',
                  child: FocusRing(
                    child: InkWell(
                      onTap: () => context.go('/app'),
                      borderRadius: BorderRadius.circular(R.control),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 4,
                        ),
                        child: ExcludeSemantics(child: CredenceLogo(size: 28)),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (label != null && !Breakpoints.isPhone(context)) ...[
                  Text(label!.toUpperCase(), style: T.label),
                  const SizedBox(width: S.x4),
                ],
                const AccountChip(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.maxWidth});

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = Breakpoints.gutter(context);
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: C.rule)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: S.x6),
            child: Wrap(
              spacing: S.x6,
              runSpacing: S.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                Text('Built with Dartus', style: T.smallStrong),
                Text('Files stored on Walrus', style: T.small),
                Text(
                  'Fingerprints are computed in your browser',
                  style: T.small,
                ),
                Text('MIT licence · Clement Kalu Okereke', style: T.small),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A white panel with a hairline border.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding,
    this.color = C.surface,
    this.borderColor = C.rule,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding:
        padding ?? EdgeInsets.all(Breakpoints.isPhone(context) ? S.x4 : S.x6),
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: borderColor),
      borderRadius: BorderRadius.circular(R.panel),
    ),
    child: child,
  );
}

/// Small uppercase heading above a section.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color = C.inkMuted});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: T.label.copyWith(color: color));
}

/// Section heading with optional trailing action.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: S.x3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(text, style: T.h2(context)),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}
