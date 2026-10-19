import 'dart:async';

import 'package:dartus/dartus.dart';
import 'package:flutter/material.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';

import 'walrus_recovery.dart';

export 'walrus_recovery.dart';

class PendingUploadsPanel extends StatefulWidget {
  const PendingUploadsPanel({
    super.key,
    required this.recovery,
    required this.owner,
    this.filter,
    this.canContinue,
    this.beforeResume,
    this.onCompleted,
  });

  final WalrusUploadRecovery recovery;
  final String owner;
  final bool Function(RecoverySummary)? filter;
  final bool Function()? canContinue;
  final Future<bool> Function()? beforeResume;
  final FutureOr<void> Function(RecoverySummary, RecoveryCompletion)? onCompleted;

  @override
  State<PendingUploadsPanel> createState() => _PendingUploadsPanelState();
}

class _PendingUploadsPanelState extends State<PendingUploadsPanel> {
  List<RecoverySummary> _jobs = const [];
  String? _error;
  String? _working;
  String? _stage;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.recovery.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(PendingUploadsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recovery != widget.recovery) {
      oldWidget.recovery.removeListener(_refresh);
      widget.recovery.addListener(_refresh);
    }
    if (oldWidget.recovery != widget.recovery || oldWidget.owner != widget.owner) {
      _jobs = const [];
      _error = null;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final jobs = await widget.recovery.pending(widget.owner);
      if (!mounted || generation != _generation) return;
      setState(() => _jobs = jobs);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = _message(error));
    }
  }

  Future<void> _resume(RecoverySummary job) async {
    final owner = widget.owner;
    setState(() {
      _working = job.id;
      _stage = 'Opening saved upload…';
      _error = null;
    });
    void stage(String value) {
      if (mounted) setState(() => _stage = value);
    }
    try {
      if (await widget.beforeResume?.call() == false) return;
      if (!mounted || widget.owner != owner) return;
      final result = await widget.recovery.resume(
        job,
        canContinue: () => mounted && widget.owner == owner && widget.canContinue?.call() != false,
        onStage: (value) => stage(switch (value) {
          WalrusWriteStage.encoding => 'Preparing…',
          WalrusWriteStage.registering => 'Checking storage payment…',
          WalrusWriteStage.uploading => 'Uploading…',
          WalrusWriteStage.certifying => 'Confirming storage…',
        }),
        onSaving: () => stage('Saving…'),
      );
      if (mounted && widget.owner == owner) await widget.onCompleted?.call(job, result);
    } catch (error) {
      if (mounted && widget.owner == owner) setState(() => _error = _message(error));
    } finally {
      if (mounted) {
        setState(() { _working = null; _stage = null; });
        await _refresh();
      }
    }
  }

  @override
  void dispose() {
    widget.recovery.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _jobs.where((job) => widget.filter?.call(job) != false).toList();
    if (jobs.isEmpty && _error == null && _working == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Unfinished uploads', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Continue files saved in this browser. Your wallet will ask for any approval still needed.'),
          for (final job in jobs) ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(job.metadata['label'] as String? ?? 'Saved upload', maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: TextButton(
              onPressed: _working == null ? () => _resume(job) : null,
              child: const Text('Continue upload'),
            ),
          ),
          if (_stage != null) Semantics(liveRegion: true, child: Text(_stage!)),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_error != null && jobs.isEmpty && _working == null) Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () { setState(() => _error = null); _refresh(); }, child: const Text('Try again')),
          ),
        ],
      ),
    );
  }
}

String _message(Object error) => switch (error) {
  UploadRecoveryException() => error.message,
  SuiWalletException() => error.message,
  InsufficientWalBalanceError() => 'This wallet needs more WAL to finish storing the upload.',
  _ => 'The upload could not finish. Its progress is saved; try again.',
};
