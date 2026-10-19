import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../platform/browser.dart';
import '../services/services.dart';
import '../services/walrus_service.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'common.dart';

/// The stored file, fetched from Walrus through Dartus. Images show inline;
/// PDFs open in a new tab from a blob URL.
class DocumentPreview extends StatelessWidget {
  const DocumentPreview({super.key, required this.document});

  final DocumentRecord document;

  @override
  Widget build(BuildContext context) => document.isImage
      ? _ImagePreview(document: document)
      : _PdfPreview(document: document);
}

BoxDecoration _sheet() => BoxDecoration(
  color: C.surface,
  border: Border.all(color: C.rule),
  borderRadius: BorderRadius.circular(R.control),
  boxShadow: const [
    BoxShadow(color: Color(0x140E1A16), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F0E1A16), blurRadius: 24, offset: Offset(0, 8)),
  ],
);

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.document});

  final DocumentRecord document;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  Future<Uint8List>? _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bytes ??= Services.of(context).walrus.read(
      widget.document.blobId,
      waitIfMissing: widget.document.readPatience,
    );
  }

  void _retry() => setState(
    () => _bytes = Services.of(context).walrus.read(
      widget.document.blobId,
      fresh: true,
      waitIfMissing: widget.document.readPatience,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final maxHeight = Breakpoints.isPhone(context) ? 380.0 : 560.0;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            height: maxHeight * 0.7,
            decoration: _sheet(),
            child: const Center(
              child: LoadingView(label: 'Fetching the file from Walrus…'),
            ),
          );
        }
        final error = snap.error;
        if (error != null || snap.data == null) {
          return _PreviewProblem(
            failure: error is WalrusFailure ? error : null,
            recent: widget.document.isRecent,
            onRetry: _retry,
          );
        }
        final bytes = snap.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              constraints: BoxConstraints(maxHeight: maxHeight),
              padding: const EdgeInsets.all(S.x3),
              decoration: _sheet(),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel:
                    'Preview of ${widget.document.title}, the stored file',
                errorBuilder: (context, _, _) => const Padding(
                  padding: EdgeInsets.all(S.x6),
                  child: Text(
                    'This image could not be displayed, but you can still '
                    'check its fingerprint below.',
                    style: T.small,
                  ),
                ),
              ),
            ),
            const SizedBox(height: S.x2),
            Wrap(
              spacing: S.x3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${widget.document.typeLabel} · '
                  '${formatBytes(widget.document.sizeBytes)} · fetched from '
                  'Walrus',
                  style: T.small,
                ),
                TextButton.icon(
                  onPressed: () => Services.of(
                    context,
                  ).browser.openBytes(bytes, widget.document.contentType),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open full size'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PdfPreview extends StatefulWidget {
  const _PdfPreview({required this.document});

  final DocumentRecord document;

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  bool _loading = false;
  WalrusFailure? _failure;
  Uint8List? _bytes;
  bool _blocked = false;

  Future<void> _open() async {
    final services = Services.of(context);
    final cached = _bytes;
    if (cached != null) {
      // A direct click: the browser allows opening the tab now.
      services.browser.openBytes(cached, 'application/pdf');
      return;
    }
    // Open the tab inside the click, before the fetch, so popup blockers
    // do not stop it.
    final PendingTab? tab = services.browser.openPendingTab();
    setState(() {
      _loading = true;
      _failure = null;
      _blocked = false;
    });
    try {
      final bytes = await services.walrus.read(
        widget.document.blobId,
        waitIfMissing: widget.document.readPatience,
      );
      if (!mounted) {
        tab?.close();
        return;
      }
      if (tab != null) {
        tab.show(bytes, 'application/pdf', title: widget.document.title);
      }
      setState(() {
        _bytes = bytes;
        _loading = false;
        _blocked = tab == null;
      });
    } on WalrusFailure catch (e) {
      tab?.close();
      if (!mounted) return;
      setState(() {
        _failure = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.document;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(S.x6),
          decoration: _sheet(),
          child: Column(
            children: [
              const Icon(
                Icons.picture_as_pdf_outlined,
                size: 48,
                color: C.ledger,
              ),
              const SizedBox(height: S.x3),
              Text(
                d.fileName,
                style: T.h3,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text('PDF · ${formatBytes(d.sizeBytes)}', style: T.small),
              const SizedBox(height: S.x4),
              FilledButton.icon(
                onPressed: _loading ? null : _open,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(
                  _loading
                      ? 'Fetching from Walrus…'
                      : _blocked
                      ? 'Open the PDF'
                      : 'Open PDF in a new tab',
                ),
              ),
              if (_loading) ...[
                const SizedBox(height: S.x3),
                const SizedBox(width: 160, child: LinearProgressIndicator()),
              ],
              if (_blocked) ...[
                const SizedBox(height: S.x2),
                const Text(
                  'Your browser blocked the new tab. The file is ready: '
                  'press the button again.',
                  style: T.small,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: S.x2),
              const Text(
                'Your browser fetches the file from Walrus and opens it in a '
                'new tab.',
                style: T.small,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        if (_failure != null) ...[
          const SizedBox(height: S.x3),
          _PreviewProblem(
            failure: _failure,
            recent: d.isRecent,
            onRetry: _open,
          ),
        ],
      ],
    );
  }
}

class _PreviewProblem extends StatelessWidget {
  const _PreviewProblem({
    required this.failure,
    required this.recent,
    required this.onRetry,
  });

  final WalrusFailure? failure;
  final bool recent;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final missing = failure?.kind == WalrusFailureKind.unavailable;
    if (missing && recent) return NotReadableYet(onRetry: onRetry);
    return Notice(
      tone: missing ? Tone.warning : Tone.danger,
      title: missing
          ? 'The stored file is no longer available'
          : 'The file could not be fetched',
      body:
          failure?.message ??
          'Something went wrong while fetching the file. Try again.',
      action: missing
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
    );
  }
}

/// A just-uploaded file the aggregator does not serve yet.
class NotReadableYet extends StatelessWidget {
  const NotReadableYet({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Notice(
    tone: Tone.info,
    title: 'Walrus is not serving this file yet',
    body:
        'It was stored minutes ago. New files can take a few minutes to '
        'reach the Walrus aggregators. Try again shortly.',
    action: OutlinedButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text('Try again'),
    ),
  );
}
