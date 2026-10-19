import 'dart:convert';
import 'dart:typed_data';

enum RecoveryFailure {
  unavailable,
  quota,
  conflict,
  missing,
  corrupt,
  limit,
  closed,
}

class UploadRecoveryException implements Exception {
  const UploadRecoveryException(this.failure, this.message);

  final RecoveryFailure failure;
  final String message;

  @override
  String toString() => 'UploadRecoveryException(${failure.name}): $message';
}

/// Scope is explicit on every operation; a different account cannot resume a job.
class RecoveryScope {
  RecoveryScope({required this.app, required this.chain, required String owner})
    : owner = owner.toLowerCase() {
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(app) ||
        chain.isEmpty ||
        chain.length > 128 ||
        !RegExp(r'^0x[0-9a-f]{64}$').hasMatch(this.owner)) {
      throw ArgumentError('Invalid upload recovery scope');
    }
  }

  final String app;
  final String chain;
  final String owner;
  String get key => jsonEncode([app, chain, owner]);
  Map<String, Object?> toJson() => {'app': app, 'chain': chain, 'owner': owner};

  factory RecoveryScope.fromJson(Map<String, Object?> json) => RecoveryScope(
    app: json['app'] as String,
    chain: json['chain'] as String,
    owner: json['owner'] as String,
  );
}

/// Small job data. File bytes are loaded only by [UploadRecoveryStore.read].
class RecoverySummary {
  RecoverySummary({
    required this.scope,
    required this.id,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    required Map<String, int> fileSizes,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  }) : fileSizes = Map.unmodifiable(fileSizes),
       checkpoint = copyJson(checkpoint),
       metadata = copyJson(metadata);

  final RecoveryScope scope;
  final String id;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, int> fileSizes;
  final Map<String, Object?> checkpoint;
  final Map<String, Object?> metadata;
  int get totalBytes => fileSizes.values.fold(0, (sum, size) => sum + size);
  String get key => recoveryKey(scope, id);

  Map<String, Object?> toJson() => {
    'version': 1,
    'scope': scope.toJson(),
    'id': id,
    'revision': revision,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'fileSizes': fileSizes,
    'checkpoint': checkpoint,
    'metadata': metadata,
  };

  factory RecoverySummary.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const UploadRecoveryException(
        RecoveryFailure.corrupt,
        'This saved upload uses an unsupported format.',
      );
    }
    final sizes = Map<String, Object?>.from(json['fileSizes'] as Map);
    final revision = json['revision'] as int;
    if (revision < 1 || sizes.values.any((size) => size is! int || size < 0)) {
      throw const FormatException('Invalid saved upload');
    }
    final result = RecoverySummary(
      scope: RecoveryScope.fromJson(
        Map<String, Object?>.from(json['scope'] as Map),
      ),
      id: json['id'] as String,
      revision: revision,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      fileSizes: sizes.cast<String, int>(),
      checkpoint: Map<String, Object?>.from(json['checkpoint'] as Map),
      metadata: Map<String, Object?>.from(json['metadata'] as Map),
    );
    validateId(result.id);
    return result;
  }
}

class RecoveryJob {
  RecoveryJob({required this.summary, required Map<String, Uint8List> files})
    : files = Map.unmodifiable({
        for (final entry in files.entries)
          entry.key: Uint8List.fromList(entry.value).asUnmodifiableView(),
      });

  final RecoverySummary summary;
  final Map<String, Uint8List> files;
}

String recoveryKey(RecoveryScope scope, String id) {
  validateId(id);
  return jsonEncode([scope.app, scope.chain, scope.owner, id]);
}

void validateId(String id) {
  if (id.isEmpty || id.length > 256) throw ArgumentError('Invalid upload ID');
}

Map<String, Object?> copyJson(Map<String, Object?> value) {
  final encoded = jsonEncode(value);
  if (encoded.length > 4 * 1024 * 1024) {
    throw const UploadRecoveryException(
      RecoveryFailure.limit,
      'Upload progress is too large to save. Store file bytes separately.',
    );
  }
  Object? freeze(Object? item) => switch (item) {
    Map<String, dynamic> map => Map<String, Object?>.unmodifiable(
      map.map((key, value) => MapEntry(key, freeze(value))),
    ),
    List<dynamic> list => List<Object?>.unmodifiable(list.map(freeze)),
    _ => item,
  };
  return freeze(jsonDecode(encoded))! as Map<String, Object?>;
}
