import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Loading placeholders shaped like the content they stand in for, so the
/// page does not jump when the data arrives. A slow, faint pulse says
/// "still working"; it stops when the platform asks for reduced motion.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.label, required this.child});

  /// What screen readers hear ("Loading the record").
  final String label;
  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _pulse.value = 1;
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    liveRegion: true,
    child: ExcludeSemantics(
      child: FadeTransition(
        opacity: Tween<double>(
          begin: 0.55,
          end: 1,
        ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
        child: widget.child,
      ),
    ),
  );
}

/// One grey bar or block.
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, required this.height, this.radius = 3});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: C.rule.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

Widget _panel(Widget child) => Container(
  width: double.infinity,
  padding: const EdgeInsets.all(S.x6),
  decoration: BoxDecoration(
    color: C.surface,
    border: Border.all(color: C.rule),
    borderRadius: BorderRadius.circular(R.panel),
  ),
  child: child,
);

Widget _ledgerRows(int n) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (var i = 0; i < n; i++) ...[
      const Bone(width: 72, height: 10),
      const SizedBox(height: S.x2),
      Bone(width: i.isEven ? 200 : 150, height: 14),
      const SizedBox(height: S.x4),
    ],
  ],
);

Widget _header(BuildContext context) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    const Bone(width: 180, height: 12),
    const SizedBox(height: S.x3),
    FractionallySizedBox(
      widthFactor: Breakpoints.isPhone(context) ? 0.9 : 0.6,
      child: const Bone(height: 30),
    ),
    const SizedBox(height: S.x3),
    const FractionallySizedBox(widthFactor: 0.45, child: Bone(height: 14)),
  ],
);

/// Placeholder for the check page.
class DocumentSkeleton extends StatelessWidget {
  const DocumentSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final desktop = Breakpoints.isDesktop(context);
    final preview = _panel(
      const AspectRatio(aspectRatio: 1.42, child: Bone(height: 10, radius: 2)),
    );
    final checks = _panel(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Bone(width: 200, height: 16),
          SizedBox(height: S.x2),
          Bone(width: 280, height: 12),
          SizedBox(height: S.x4),
          Bone(height: 96, radius: 6),
        ],
      ),
    );
    final details = _panel(_ledgerRows(6));
    return Skeleton(
      label: 'Loading the record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: S.x6),
          _header(context),
          const SizedBox(height: S.x8),
          if (desktop)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      preview,
                      const SizedBox(height: S.x6),
                      checks,
                    ],
                  ),
                ),
                const SizedBox(width: S.x8),
                Expanded(flex: 5, child: details),
              ],
            )
          else ...[
            preview,
            const SizedBox(height: S.x6),
            checks,
          ],
        ],
      ),
    );
  }
}

/// Placeholder for a vault page or the admin list.
class VaultSkeleton extends StatelessWidget {
  const VaultSkeleton({super.key, this.label = 'Loading vault'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: S.x8),
          _header(context),
          const SizedBox(height: S.x12),
          const Bone(width: 140, height: 22),
          const SizedBox(height: S.x4),
          Container(
            decoration: BoxDecoration(
              color: C.surface,
              border: Border.all(color: C.rule),
              borderRadius: BorderRadius.circular(R.panel),
            ),
            child: Column(
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    padding: const EdgeInsets.all(S.x6),
                    decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : const Border(top: BorderSide(color: C.rule)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: 0.5,
                          child: Bone(height: 16),
                        ),
                        SizedBox(height: S.x2),
                        FractionallySizedBox(
                          widthFactor: 0.7,
                          child: Bone(height: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
