import 'dart:async';
import 'dart:math';

import 'package:dartus/dartus.dart';
import 'package:flutter/foundation.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';

import 'upload_recovery.dart';

export 'upload_recovery.dart';

typedef CheckpointHandler = Future<void> Function(WalrusWriteCheckpoint);

/// Implemented by the real storage adapters; test storage need not persist.
abstract interface class RecoveryCheckpointSource {
  WalrusWriteCheckpoint get checkpoint;
  set onCheckpoint(CheckpointHandler? handler);
}

class RecoveredUpload {
  RecoveredUpload({
    required this.blob,
    this.files = const [],
    this.identifiers = const [],
  });

  final WalrusWriteResult blob;
  final List<WalrusStoredFile> files;
  final List<String> identifiers;
  String get objectId => blob.blobObjectId;
  String get blobId => blob.blobId;
  int get endEpoch => blob.endEpoch;
  List<String> get patchIds => [
    for (final id in identifiers)
      files.firstWhere((file) => file.identifier == id).patchId,
  ];
}

class RecoveryCompletion {
  const RecoveryCompletion.complete() : metadata = null;
  const RecoveryCompletion.keep(this.metadata);

  final Map<String, Object?>? metadata;
  bool get completed => metadata == null;
}

typedef FinishRecoveredUpload =
    Future<RecoveryCompletion> Function(
      RecoverySummary job,
      RecoveredUpload stored,
    );

/// Coordinates durable progress with an app's idempotent metadata save.
class WalrusUploadRecovery extends ChangeNotifier {
  WalrusUploadRecovery({
    required this.app,
    required this.chain,
    required this.wallet,
    required this.finish,
    UploadRecoveryStore? store,
    WalrusWriter Function()? writerFactory,
  }) : _store = store == null ? null : Future.value(store),
       _writerFactory = writerFactory {
    if (chain != 'sui:mainnet' && chain != 'sui:testnet') {
      throw ArgumentError.value(chain, 'chain', 'Unsupported Walrus network');
    }
  }

  final String app;
  final String chain;
  final SuiWalletController wallet;
  final FinishRecoveredUpload finish;
  final WalrusWriter Function()? _writerFactory;
  Future<UploadRecoveryStore>? _store;
  bool _disposed = false;
  final Set<String> _active = {};

  Future<UploadRecoveryStore> get store => _store ??= openUploadRecoveryStore();
  RecoveryScope scope(String owner) =>
      RecoveryScope(app: app, chain: chain, owner: owner);

  void _requireActive() {
    if (_disposed) {
      throw const UploadRecoveryException(
        RecoveryFailure.unavailable,
        'Reopen this app to continue the saved upload.',
      );
    }
  }

  Future<List<RecoverySummary>> pending(String owner) async => [
    for (final job in await (await store).list(scope(owner)))
      if (!_active.contains(job.key)) job,
  ];

  /// Called before the storage adapter runs. A failed disk write prevents payment.
  Future<UploadRecoverySession> bind(
    RecoveryCheckpointSource source, {
    required String owner,
    required Map<String, Object?> metadata,
    String? id,
  }) async {
    _requireActive();
    final session = UploadRecoverySession._(
      this,
      scope(owner),
      id ?? _newId(),
      metadata,
    );
    await session.activate();
    try {
      source.onCheckpoint = session.checkpoint;
      await session.checkpoint(source.checkpoint);
      return session;
    } catch (_) {
      source.onCheckpoint = null;
      await session.release();
      rethrow;
    }
  }

  RecoverableWalletTransactionSigner signer(
    String owner, {
    bool Function()? canContinue,
  }) => RecoverableWalletTransactionSigner(
    address: owner,
    execute: (transaction, {required requestId, required resume}) async {
      if (_disposed ||
          wallet.chain != chain ||
          wallet.account?.address.toLowerCase() != owner.toLowerCase() ||
          canContinue?.call() == false) {
        throw SuiWalletException(
          SuiWalletErrorKind.accountNotFound,
          'Reconnect the wallet account that started this upload, then continue.',
          definitelyNotSubmitted: !resume,
        );
      }
      try {
        return (await wallet.signAndExecuteRecoverable(
          transaction.json,
          requestId: requestId,
          resume: resume,
        )).digest;
      } on SuiWalletException catch (error) {
        final digest = error.transactionDigest;
        if (error.kind == SuiWalletErrorKind.transactionFailed &&
            digest != null &&
            digest.isNotEmpty) {
          throw WalrusTransactionExecutionFailed(digest, error.message);
        }
        rethrow;
      }
    },
    isDefinitelyNotCommitted: (error) =>
        error is SuiWalletException && error.definitelyNotSubmitted,
  );

  /// Continues the exact saved flow. It does not start an automatic payment.
  Future<RecoveryCompletion> resume(
    RecoverySummary selected, {
    void Function(WalrusWriteStage)? onStage,
    void Function()? onSaving,
    bool Function()? canContinue,
  }) async {
    _requireActive();
    if (selected.scope.app != app || selected.scope.chain != chain) {
      throw StateError('This upload belongs to another app or network.');
    }
    final owner = selected.scope.owner;
    if (wallet.account?.address.toLowerCase() != owner ||
        canContinue?.call() == false) {
      throw const UploadRecoveryException(
        RecoveryFailure.unavailable,
        'Connect the wallet account that started this upload.',
      );
    }
    if (!_active.add(selected.key)) {
      throw const UploadRecoveryException(
        RecoveryFailure.conflict,
        'This upload is already continuing.',
      );
    }
    WalrusWriter? writer;
    UploadRelayClient? relay;
    RecoveryLease? lease;
    UploadRecoverySession? session;
    try {
      final db = await store;
      lease = await db.acquire(selected.scope, selected.id);
      final saved = await db.read(selected.scope, selected.id);
      if (saved == null) {
        throw const UploadRecoveryException(
          RecoveryFailure.missing,
          'This upload has already been completed or removed.',
        );
      }
      // Claim this revision before any network or wallet operation.
      final claimed = await db.update(
        scope: saved.summary.scope,
        id: saved.summary.id,
        expectedRevision: selected.revision,
        checkpoint: saved.summary.checkpoint,
        metadata: saved.summary.metadata,
      );
      session =
          UploadRecoverySession._(
              this,
              claimed.scope,
              claimed.id,
              claimed.metadata,
            )
            .._summary = claimed
            .._lease = lease;
      final checkpoint = _restoreCheckpoint(claimed.checkpoint, saved.files);
      _checkScope(checkpoint, claimed.scope);
      final network = chain == 'sui:mainnet'
          ? WalrusNetwork.mainnet
          : WalrusNetwork.testnet;
      if (_writerFactory != null) {
        writer = _writerFactory();
      } else {
        relay = UploadRelayClient(
          host: network.defaultUploadRelayUrl,
          timeout: const Duration(minutes: 15),
        );
        writer = WalrusWriter(network: network, relay: relay);
      }
      final payer = signer(owner, canContinue: canContinue);
      final RecoveredUpload stored;
      if (checkpoint.isFiles) {
        final flow = await writer.restoreFilesFlow(
          checkpoint,
          onCheckpoint: session.checkpoint,
        );
        final result = await flow.run(payer, onStage: onStage);
        stored = RecoveredUpload(
          blob: result.quilt,
          files: result.files,
          identifiers: [for (final file in checkpoint.files!) file.identifier],
        );
      } else {
        final flow = await writer.restoreFlow(
          checkpoint,
          onCheckpoint: session.checkpoint,
        );
        stored = RecoveredUpload(blob: await flow.run(payer, onStage: onStage));
      }
      if (_disposed ||
          wallet.account?.address.toLowerCase() != owner ||
          canContinue?.call() == false) {
        throw const UploadRecoveryException(
          RecoveryFailure.unavailable,
          'Sign in with the original account to save this upload.',
        );
      }
      onSaving?.call();
      final completion = await finish(session.summary!, stored);
      if (completion.completed) {
        await session.complete();
      } else {
        await session.updateMetadata(completion.metadata!);
      }
      return completion;
    } finally {
      writer?.close();
      relay?.close();
      if (session != null) {
        await session.release();
      } else {
        await lease?.release();
      }
      _active.remove(selected.key);
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Closing a database while a checkpoint is committing could lose its
    // completion notification. The browser owns this connection's lifetime.
    super.dispose();
  }
}

class UploadRecoverySession {
  UploadRecoverySession._(
    this.recovery,
    this.scope,
    this.id,
    Map<String, Object?> metadata,
  ) : _metadata = copyJson(metadata);

  final WalrusUploadRecovery recovery;
  final RecoveryScope scope;
  final String id;
  Map<String, Object?> _metadata;
  RecoverySummary? _summary;
  RecoverySummary? get summary => _summary;
  Future<void> _tail = Future.value();
  bool _complete = false;
  bool get completed => _complete;
  RecoveryLease? _lease;

  String get _key => recoveryKey(scope, id);

  Future<void> activate() => _serialize(() async {
    recovery._requireActive();
    if (_complete) throw StateError('This upload is already complete.');
    if (_lease != null) return;
    final lease = await (await recovery.store).acquire(scope, id);
    try {
      recovery._requireActive();
      if (_summary != null) {
        final current = await (await recovery.store).read(scope, id);
        if (current == null || current.summary.revision != _summary!.revision) {
          throw const UploadRecoveryException(
            RecoveryFailure.conflict,
            'This upload changed in another tab. Continue it from the saved uploads list.',
          );
        }
      }
    } catch (_) {
      await lease.release();
      rethrow;
    }
    _lease = lease;
    recovery._active.add(_summary?.key ?? _key);
    recovery._changed();
  });

  Future<void> release() => _serialize(() async {
    final lease = _lease;
    _lease = null;
    await lease?.release();
    recovery._active.remove(_summary?.key ?? _key);
    recovery._changed();
  });

  void _requireLease() {
    if (_lease == null) {
      throw const UploadRecoveryException(
        RecoveryFailure.conflict,
        'Continue this upload before changing its saved progress.',
      );
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> checkpoint(WalrusWriteCheckpoint value) => _serialize(() async {
    if (_complete) throw StateError('This upload is already complete.');
    _requireLease();
    _checkScope(value, scope);
    final db = await recovery.store;
    final encoded = _encodeCheckpoint(value);
    final old = _summary;
    _summary = old == null
        ? await db.create(
            scope: scope,
            id: id,
            files: _checkpointFiles(value),
            checkpoint: encoded,
            metadata: _metadata,
          )
        : await db.update(
            scope: scope,
            id: id,
            expectedRevision: old.revision,
            checkpoint: encoded,
            metadata: _metadata,
          );
    recovery._changed();
  });

  /// Saves corrected form details before retrying the app's metadata request.
  Future<void> updateMetadata(Map<String, Object?> metadata) =>
      _serialize(() async {
        if (_complete) throw StateError('This upload is already complete.');
        _requireLease();
        final old = _summary;
        if (old != null) {
          _summary = await (await recovery.store).update(
            scope: scope,
            id: id,
            expectedRevision: old.revision,
            checkpoint: old.checkpoint,
            metadata: metadata,
          );
        }
        _metadata = Map.of(metadata);
        recovery._changed();
      });

  /// Only after the app's idempotent save has succeeded.
  Future<void> complete() => _serialize(() async {
    if (_complete) return;
    _requireLease();
    final old = _summary;
    if (old != null) {
      await (await recovery.store).remove(
        scope,
        id,
        expectedRevision: old.revision,
      );
    }
    _complete = true;
    final lease = _lease;
    _lease = null;
    await lease?.release();
    recovery._active.remove(old?.key ?? _key);
    recovery._changed();
  });
}

void _checkScope(WalrusWriteCheckpoint checkpoint, RecoveryScope scope) {
  if ('sui:${checkpoint.network}' != scope.chain ||
      (checkpoint.owner != null &&
          checkpoint.owner!.toLowerCase() != scope.owner)) {
    throw const UploadRecoveryException(
      RecoveryFailure.corrupt,
      'Saved upload account or network does not match.',
    );
  }
}

String _newId() {
  final random = Random.secure();
  return List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Map<String, Uint8List> _checkpointFiles(WalrusWriteCheckpoint checkpoint) =>
    checkpoint.isFiles
    ? {
        for (var i = 0; i < checkpoint.files!.length; i++)
          'file-$i': checkpoint.files![i].contents,
      }
    : {'data': checkpoint.data};

Map<String, Object?> _encodeCheckpoint(WalrusWriteCheckpoint checkpoint) => {
  'format': 1,
  'sdk': checkpoint.toJson(includeData: false),
  if (checkpoint.isFiles)
    'files': [
      for (final file in checkpoint.files!)
        {'identifier': file.identifier, 'tags': file.tags},
    ],
};

WalrusWriteCheckpoint _restoreCheckpoint(
  Map<String, Object?> encoded,
  Map<String, Uint8List> bytes,
) {
  if (encoded['format'] != 1 || encoded['sdk'] is! Map) {
    throw const UploadRecoveryException(
      RecoveryFailure.corrupt,
      'Saved upload progress could not be read.',
    );
  }
  final files = encoded['files'] as List?;
  return WalrusWriteCheckpoint.fromJson(
    Map<String, Object?>.from(encoded['sdk'] as Map),
    data: files == null ? bytes['data'] : null,
    files: files == null
        ? null
        : [
            for (var i = 0; i < files.length; i++)
              QuiltBlob(
                contents:
                    bytes['file-$i'] ??
                    (throw const FormatException('Saved file is missing')),
                identifier: (files[i] as Map)['identifier'] as String,
                tags: (files[i] as Map)['tags'] == null
                    ? null
                    : Map<String, String>.from(
                        (files[i] as Map)['tags'] as Map,
                      ),
              ),
          ],
  );
}
