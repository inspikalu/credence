import 'package:flutter/material.dart';

import '../platform/browser.dart';
import '../services/file_rules.dart';
import '../services/services.dart';
import '../theme/tokens.dart';

/// A place to drop or choose one file. While it is on screen, a file
/// dropped anywhere on the page lands here (there is only ever one zone per
/// screen), so the browser never navigates away to the file.
class FileDropZone extends StatefulWidget {
  const FileDropZone({
    super.key,
    required this.onFile,
    required this.title,
    required this.help,
    this.buttonLabel = 'Choose a file',
    this.accept = '',
    this.enabled = true,
    this.compact = false,
  });

  final void Function(LocalFile file) onFile;
  final String title;
  final String help;
  final String buttonLabel;
  final String accept;
  final bool enabled;
  final bool compact;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> implements DropListener {
  bool _over = false;
  Browser? _browser;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final browser = Services.of(context).browser;
    if (!identical(browser, _browser)) {
      _browser?.clearDropListener(this);
      _browser = browser;
      browser.setDropListener(this);
    }
  }

  @override
  void dispose() {
    _browser?.clearDropListener(this);
    super.dispose();
  }

  @override
  void onDragOver(Offset position) {
    if (!widget.enabled || _over) return;
    setState(() => _over = true);
  }

  @override
  void onDragLeave() {
    if (_over && mounted) setState(() => _over = false);
  }

  @override
  void onDrop(DroppedFile dropped) {
    if (!mounted) return;
    setState(() => _over = false);
    if (widget.enabled) widget.onFile(dropped.file);
  }

  Future<void> _choose() async {
    final file = await _browser?.pickFile(accept: widget.accept);
    if (file != null && mounted && widget.enabled) widget.onFile(file);
  }

  @override
  Widget build(BuildContext context) {
    final duration = Motion.of(context, Motion.quick);
    return AnimatedContainer(
      width: double.infinity,
      duration: duration,
      decoration: BoxDecoration(
        color: _over ? C.mint : C.surface,
        borderRadius: BorderRadius.circular(R.panel),
      ),
      child: CustomPaint(
        painter: _DashedBorder(
          color: _over ? C.ledger : C.control,
          width: _over ? 2 : 1,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: S.x4,
            vertical: widget.compact ? S.x4 : S.x6,
          ),
          child: Column(
            children: [
              Icon(
                _over ? Icons.file_download_outlined : Icons.upload_file,
                color: _over ? C.ledger : C.inkMuted,
                size: 28,
              ),
              const SizedBox(height: S.x2),
              Text(
                _over ? 'Release to use this file' : widget.title,
                textAlign: TextAlign.center,
                style: T.h3,
              ),
              const SizedBox(height: S.x1),
              Text(widget.help, textAlign: TextAlign.center, style: T.small),
              const SizedBox(height: S.x3),
              OutlinedButton.icon(
                onPressed: widget.enabled ? _choose : null,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(widget.buttonLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(width / 2),
      const Radius.circular(R.panel),
    );
    final path = Path()..addRRect(rect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.width != width;
}
