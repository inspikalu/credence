import 'dart:typed_data';

import 'model.dart';

abstract interface class UploadRecoveryStore {
  /// Held across network and wallet waits. A competing tab fails immediately.
  Future<RecoveryLease> acquire(RecoveryScope scope, String id);

  /// Resolves only after both bytes and the first checkpoint commit.
  Future<RecoverySummary> create({
    required RecoveryScope scope,
    required String id,
    required Map<String, Uint8List> files,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  });

  /// Compare-and-set must complete before the next wallet request.
  Future<RecoverySummary> update({
    required RecoveryScope scope,
    required String id,
    required int expectedRevision,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  });

  Future<RecoveryJob?> read(RecoveryScope scope, String id);
  Future<List<RecoverySummary>> list(RecoveryScope scope);

  /// Remove only after the app has saved its final metadata successfully.
  Future<void> remove(
    RecoveryScope scope,
    String id, {
    required int expectedRevision,
  });
  Future<void> close();
}

abstract interface class RecoveryLease {
  Future<void> release();
}

RecoverySummary initialSummary({
  required RecoveryScope scope,
  required String id,
  required Map<String, Uint8List> files,
  required Map<String, Object?> checkpoint,
  required Map<String, Object?> metadata,
  required int maxJobBytes,
}) {
  validateId(id);
  if (files.isEmpty ||
      files.length > 128 ||
      files.keys.any((name) => name.isEmpty || name.length > 1024)) {
    throw ArgumentError('Invalid upload files');
  }
  final total = files.values.fold(0, (sum, bytes) => sum + bytes.length);
  if (total > maxJobBytes) {
    throw const UploadRecoveryException(
      RecoveryFailure.limit,
      'These upload files exceed the recovery storage limit.',
    );
  }
  final now = DateTime.now().toUtc();
  return RecoverySummary(
    scope: scope,
    id: id,
    revision: 1,
    createdAt: now,
    updatedAt: now,
    fileSizes: files.map((name, bytes) => MapEntry(name, bytes.length)),
    checkpoint: checkpoint,
    metadata: metadata,
  );
}

RecoverySummary nextSummary(
  RecoverySummary old,
  int revision,
  Map<String, Object?> checkpoint,
  Map<String, Object?> metadata,
) {
  checkRevision(old, revision);
  return RecoverySummary(
    scope: old.scope,
    id: old.id,
    revision: old.revision + 1,
    createdAt: old.createdAt,
    updatedAt: DateTime.now().toUtc(),
    fileSizes: old.fileSizes,
    checkpoint: checkpoint,
    metadata: metadata,
  );
}

void checkRevision(RecoverySummary old, int expected) {
  if (expected != old.revision) {
    throw const UploadRecoveryException(
      RecoveryFailure.conflict,
      'This upload changed in another tab. Reopen its saved progress before continuing.',
    );
  }
}
