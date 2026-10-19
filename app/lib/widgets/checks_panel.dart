import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/checks.dart';
import '../services/file_rules.dart';
import '../services/hashing.dart';
import '../services/services.dart';
import '../services/walrus_service.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'check_result_view.dart';
import 'common.dart';
import 'drop_zone.dart';
import 'page_frame.dart';
import 'preview.dart';

enum _Phase { idle, fetching, hashing, done, failed }

/// "Check stored file": fetch from Walrus through Dartus, hash locally,
/// compare with the record.
class StoredFileCheck extends StatefulWidget {
  const StoredFileCheck({
    super.key,
    required this.document,
    required this.vault,
  });

  final DocumentRecord document;
  final Vault vault;

  @override
  State<StoredFileCheck> createState() => _StoredFileCheckState();
}

class _StoredFileCheckState extends State<StoredFileCheck> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  CheckResult? _result;
  WalrusFailure? _failure;

  Future<void> _run() async {
    final walrus = Services.of(context).walrus;
    setState(() {
      _phase = _Phase.fetching;
      _failure = null;
      _result = null;
      _progress = 0;
    });
    try {
      final bytes = await walrus.read(
        widget.document.blobId,
        fresh: true,
        waitIfMissing: widget.document.readPatience,
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.hashing);
      final hex = await sha256Hex(
        bytes,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = CheckResult(
          source: CheckSource.stored,
          expected: widget.document.sha256,
          computed: hex,
          sizeBytes: bytes.length,
          checkedAt: DateTime.now().toUtc(),
        );
        _phase = _Phase.done;
      });
    } on WalrusFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = e;
        _phase = _Phase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.fetching || _phase == _Phase.hashing;
    return _CheckCard(
      icon: Icons.cloud_sync_outlined,
      title: 'Check stored file',
      body:
          'Fetch the file from Walrus and recompute its SHA-256 fingerprint '
          'here, in your browser.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy) ...[
            Semantics(
              liveRegion: true,
              label: _phase == _Phase.fetching
                  ? 'Fetching from Walrus'
                  : 'Computing fingerprint',
              child: LinearProgressIndicator(
                value: _phase == _Phase.hashing ? _progress : null,
              ),
            ),
            const SizedBox(height: S.x2),
            Text(
              _phase == _Phase.fetching
                  ? 'Fetching ${formatBytes(widget.document.sizeBytes)} from '
                        'Walrus…'
                  : 'Computing the fingerprint on this device…',
              style: T.small,
            ),
          ] else
            OutlinedButton.icon(
              onPressed: _run,
              icon: Icon(
                _phase == _Phase.idle ? Icons.play_arrow : Icons.refresh,
                size: 18,
              ),
              label: Text(
                _phase == _Phase.idle ? 'Check stored file' : 'Check again',
              ),
            ),
          if (_phase == _Phase.failed &&
              _failure?.kind == WalrusFailureKind.unavailable &&
              widget.document.isRecent) ...[
            const SizedBox(height: S.x3),
            NotReadableYet(onRetry: _run),
          ] else if (_phase == _Phase.failed && _failure != null) ...[
            const SizedBox(height: S.x3),
            Notice(
              tone: _failure!.kind == WalrusFailureKind.unavailable
                  ? Tone.warning
                  : Tone.danger,
              title: _failure!.kind == WalrusFailureKind.unavailable
                  ? 'The stored file is no longer available'
                  : 'The check did not finish',
              body: _failure!.message,
            ),
          ],
          if (_phase == _Phase.done && _result != null) ...[
            const SizedBox(height: S.x4),
            CheckResultView(
              result: _result!,
              document: widget.document,
              vault: widget.vault,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Check a copy you received": hash a local file, compare with the record.
/// The file never leaves the device.
class CopyCheck extends StatefulWidget {
  const CopyCheck({super.key, required this.document, required this.vault});

  final DocumentRecord document;
  final Vault vault;

  @override
  State<CopyCheck> createState() => _CopyCheckState();
}

class _CopyCheckState extends State<CopyCheck> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  LocalFile? _file;
  CheckResult? _result;
  String? _error;

  Future<void> _onFile(LocalFile file) async {
    if (_phase == _Phase.hashing) return;
    if (file.size > maxCheckBytes) {
      setState(() {
        _error =
            'This file is ${formatBytes(file.size)}, much larger than the '
            'stored file (${formatBytes(widget.document.sizeBytes)}). It is '
            'not the same file.';
        _phase = _Phase.failed;
        _file = file;
      });
      return;
    }
    setState(() {
      _file = file;
      _phase = _Phase.hashing;
      _progress = 0;
      _result = null;
      _error = null;
    });
    final hex = await sha256Hex(
      file.bytes,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted || !identical(_file, file)) return;
    setState(() {
      _result = CheckResult(
        source: CheckSource.copy,
        expected: widget.document.sha256,
        computed: hex,
        sizeBytes: file.size,
        fileName: file.name,
        checkedAt: DateTime.now().toUtc(),
      );
      _phase = _Phase.done;
    });
  }

  void _reset() => setState(() {
    _phase = _Phase.idle;
    _file = null;
    _result = null;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    return _CheckCard(
      icon: Icons.fact_check_outlined,
      title: 'Check a copy you received',
      body:
          'Drop the file someone sent you, or choose it. It is hashed on this '
          'device and never uploaded.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_phase == _Phase.idle)
            FileDropZone(
              title: 'Drop the file here',
              help: 'Any file. It stays on this device.',
              buttonLabel: 'Choose a file',
              compact: true,
              onFile: _onFile,
            ),
          if (_phase == _Phase.hashing) ...[
            Semantics(
              liveRegion: true,
              label: 'Computing fingerprint of ${_file?.name}',
              child: LinearProgressIndicator(value: _progress),
            ),
            const SizedBox(height: S.x2),
            Text(
              'Computing the fingerprint of ${_file?.name} on this device…',
              style: T.small,
            ),
          ],
          if (_phase == _Phase.failed && _error != null) ...[
            Notice(tone: Tone.danger, title: 'No match', body: _error),
          ],
          if (_phase == _Phase.done && _result != null)
            CheckResultView(
              result: _result!,
              document: widget.document,
              vault: widget.vault,
            ),
          if (_phase == _Phase.done || _phase == _Phase.failed) ...[
            const SizedBox(height: S.x3),
            OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Check another file'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: C.ledger),
            const SizedBox(width: S.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(header: true, child: Text(title, style: T.h3)),
                  const SizedBox(height: S.x1),
                  Text(body, style: T.small),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: S.x4),
        child,
      ],
    ),
  );
}
