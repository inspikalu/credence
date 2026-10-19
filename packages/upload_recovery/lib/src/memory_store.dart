import 'dart:typed_data';

import 'model.dart';
import 'store.dart';

/// Explicit test backend. This never substitutes for failed browser storage.
class MemoryUploadRecoveryStore implements UploadRecoveryStore {
  MemoryUploadRecoveryStore({
    this.maxJobBytes = 128 * 1024 * 1024,
    this.maxStoredBytes = 512 * 1024 * 1024,
    this.maxJobs = 64,
  });

  final int maxJobBytes;
  final int maxStoredBytes;
  final int maxJobs;
  final Map<String, RecoveryJob> _jobs = {};
  final Set<String> _leases = {};
  bool _closed = false;

  void _checkOpen() {
    if (_closed) {
      throw const UploadRecoveryException(
        RecoveryFailure.closed,
        'Upload recovery storage is closed.',
      );
    }
  }

  @override
  Future<RecoveryLease> acquire(RecoveryScope scope, String id) async {
    _checkOpen();
    final key = recoveryKey(scope, id);
    if (!_leases.add(key)) {
      throw const UploadRecoveryException(
        RecoveryFailure.conflict,
        'This upload is already running. Continue it in the other tab.',
      );
    }
    return _MemoryLease(() => _leases.remove(key));
  }

  @override
  Future<RecoverySummary> create({
    required RecoveryScope scope,
    required String id,
    required Map<String, Uint8List> files,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  }) async {
    _checkOpen();
    final summary = initialSummary(
      scope: scope,
      id: id,
      files: files,
      checkpoint: checkpoint,
      metadata: metadata,
      maxJobBytes: maxJobBytes,
    );
    if (_jobs.containsKey(summary.key)) {
      throw const UploadRecoveryException(
        RecoveryFailure.conflict,
        'This upload is already saved.',
      );
    }
    final used = _jobs.values.fold(
      0,
      (sum, job) => sum + job.summary.totalBytes,
    );
    if (_jobs.length >= maxJobs || used + summary.totalBytes > maxStoredBytes) {
      throw const UploadRecoveryException(
        RecoveryFailure.quota,
        'There is not enough recovery storage. Finish another saved upload first.',
      );
    }
    _jobs[summary.key] = RecoveryJob(summary: summary, files: files);
    return summary;
  }

  @override
  Future<RecoverySummary> update({
    required RecoveryScope scope,
    required String id,
    required int expectedRevision,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  }) async {
    _checkOpen();
    final key = recoveryKey(scope, id);
    final old = _jobs[key];
    if (old == null) {
      throw const UploadRecoveryException(
        RecoveryFailure.missing,
        'This saved upload was removed.',
      );
    }
    final next = nextSummary(
      old.summary,
      expectedRevision,
      checkpoint,
      metadata,
    );
    _jobs[key] = RecoveryJob(summary: next, files: old.files);
    return next;
  }

  @override
  Future<RecoveryJob?> read(RecoveryScope scope, String id) async {
    _checkOpen();
    final job = _jobs[recoveryKey(scope, id)];
    return job == null
        ? null
        : RecoveryJob(summary: job.summary, files: job.files);
  }

  @override
  Future<List<RecoverySummary>> list(RecoveryScope scope) async {
    _checkOpen();
    return _jobs.values
        .where((job) => job.summary.scope.key == scope.key)
        .map((job) => job.summary)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> remove(
    RecoveryScope scope,
    String id, {
    required int expectedRevision,
  }) async {
    _checkOpen();
    final key = recoveryKey(scope, id);
    final old = _jobs[key];
    if (old == null) return;
    checkRevision(old.summary, expectedRevision);
    _jobs.remove(key);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _leases.clear();
  }
}

class _MemoryLease implements RecoveryLease {
  _MemoryLease(this._release);
  final void Function() _release;
  bool _released = false;
  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _release();
  }
}
