import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'model.dart';
import 'store.dart';

class IndexedDbUploadRecoveryStore implements UploadRecoveryStore {
  IndexedDbUploadRecoveryStore._(
    this._db,
    this.maxJobBytes,
    this.maxStoredBytes,
    this.maxJobs,
  );

  final web.IDBDatabase _db;
  final int maxJobBytes;
  final int maxStoredBytes;
  final int maxJobs;
  final Set<RecoveryLease> _leases = {};
  bool _closed = false;

  @override
  Future<RecoveryLease> acquire(RecoveryScope scope, String id) async {
    if (_closed) {
      throw const UploadRecoveryException(
        RecoveryFailure.closed,
        'Upload recovery storage is closed.',
      );
    }
    final granted = Completer<RecoveryLease>();
    final released = Completer<void>();
    late Future<void> finished;
    try {
      final request = web.window.navigator.locks.request(
        'dartus-recovery:${_db.name}:${recoveryKey(scope, id)}',
        web.LockOptions(mode: 'exclusive', ifAvailable: true),
        ((web.Lock? lock) {
          if (lock == null || _closed) {
            granted.completeError(
              const UploadRecoveryException(
                RecoveryFailure.conflict,
                'This upload is already running. Continue it in the other tab.',
              ),
            );
            return Future<JSAny?>.value(null).toJS;
          }
          late final _BrowserLease lease;
          lease = _BrowserLease(
            released,
            () => finished,
            () => _leases.remove(lease),
          );
          _leases.add(lease);
          granted.complete(lease);
          return released.future.then<JSAny?>((_) => null).toJS;
        }).toJS,
      );
      finished = request.toDart.then<void>(
        (_) {},
        onError: (Object error) {
          if (!granted.isCompleted) granted.completeError(_failure(error));
        },
      );
    } catch (error) {
      throw _failure(error);
    }
    return granted.future;
  }

  static Future<IndexedDbUploadRecoveryStore> open({
    required String databaseName,
    required int maxJobBytes,
    required int maxStoredBytes,
    required int maxJobs,
  }) async {
    if (databaseName.isEmpty ||
        maxJobBytes < 1 ||
        maxStoredBytes < 1 ||
        maxJobs < 1) {
      throw ArgumentError('Invalid upload recovery storage limits');
    }
    final completer = Completer<web.IDBDatabase>();
    try {
      final request = web.window.indexedDB.open(databaseName, 1);
      request.addEventListener(
        'upgradeneeded',
        ((web.Event _) {
          final db = request.result as web.IDBDatabase;
          db.createObjectStore('jobs').createIndex('scope', 'scope'.toJS);
          db.createObjectStore('files');
        }).toJS,
      );
      request.addEventListener(
        'success',
        ((web.Event _) {
          final db = request.result as web.IDBDatabase;
          if (completer.isCompleted) {
            db.close();
          } else {
            completer.complete(db);
          }
        }).toJS,
      );
      request.addEventListener(
        'error',
        ((web.Event _) {
          if (!completer.isCompleted) {
            completer.completeError(_failure(request.error));
          }
        }).toJS,
      );
      request.addEventListener(
        'blocked',
        ((web.Event _) {
          if (!completer.isCompleted) {
            completer.completeError(
              const UploadRecoveryException(
                RecoveryFailure.unavailable,
                'Close other tabs using this app, then try saving the upload again.',
              ),
            );
          }
        }).toJS,
      );
      final timer = Timer(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          completer.completeError(
            const UploadRecoveryException(
              RecoveryFailure.unavailable,
              'Could not open recovery storage. Try again before paying.',
            ),
          );
        }
      });
      final db = await completer.future.whenComplete(timer.cancel);
      final store = IndexedDbUploadRecoveryStore._(
        db,
        maxJobBytes,
        maxStoredBytes,
        maxJobs,
      );
      db.addEventListener(
        'versionchange',
        ((web.Event _) {
          store.close();
        }).toJS,
      );
      return store;
    } catch (error) {
      throw _failure(error);
    }
  }

  web.IDBTransaction _transaction(List<String> stores, {bool write = false}) {
    if (_closed) {
      throw const UploadRecoveryException(
        RecoveryFailure.closed,
        'Upload recovery storage is closed.',
      );
    }
    try {
      return _db.transaction(
        stores.map((s) => s.toJS).toList().toJS,
        write ? 'readwrite' : 'readonly',
        web.IDBTransactionOptions(durability: 'strict'),
      );
    } catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<RecoverySummary> create({
    required RecoveryScope scope,
    required String id,
    required Map<String, Uint8List> files,
    required Map<String, Object?> checkpoint,
    required Map<String, Object?> metadata,
  }) async {
    final summary = initialSummary(
      scope: scope,
      id: id,
      files: files,
      checkpoint: checkpoint,
      metadata: metadata,
      maxJobBytes: maxJobBytes,
    );
    final binary = _encodeFiles(files);
    final tx = _transaction(['jobs', 'files'], write: true);
    final outcome = _Outcome(tx);
    try {
      final jobs = tx.objectStore('jobs');
      final request = jobs.getAll();
      request.addEventListener(
        'success',
        ((web.Event _) {
          outcome.run(() {
            final all = (request.result as JSArray<JSObject>).toDart
                .map(_decodeSummary)
                .toList();
            if (all.any((old) => old.key == summary.key)) {
              throw const UploadRecoveryException(
                RecoveryFailure.conflict,
                'This upload is already saved.',
              );
            }
            final used = all.fold(0, (sum, old) => sum + old.totalBytes);
            if (all.length >= maxJobs ||
                used + summary.totalBytes > maxStoredBytes) {
              throw const UploadRecoveryException(
                RecoveryFailure.quota,
                'There is not enough recovery storage. Finish another saved upload first.',
              );
            }
            jobs.add(_encodeSummary(summary), summary.key.toJS);
            tx.objectStore('files').add(binary, summary.key.toJS);
          });
        }).toJS,
      );
    } catch (error) {
      outcome.abort(error);
    }
    await outcome.done;
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
    // Validate/copy before opening the transaction; no asynchronous work inside it.
    final savedCheckpoint = copyJson(checkpoint);
    final savedMetadata = copyJson(metadata);
    final key = recoveryKey(scope, id);
    final tx = _transaction(['jobs'], write: true);
    final outcome = _Outcome(tx);
    RecoverySummary? next;
    outcome.run(() {
      final jobs = tx.objectStore('jobs');
      final request = jobs.get(key.toJS);
      request.addEventListener(
        'success',
        ((web.Event _) {
          outcome.run(() {
            if (request.result.isUndefinedOrNull) {
              throw const UploadRecoveryException(
                RecoveryFailure.missing,
                'This saved upload was removed.',
              );
            }
            final old = _decodeSummary(request.result as JSObject);
            next = nextSummary(
              old,
              expectedRevision,
              savedCheckpoint,
              savedMetadata,
            );
            jobs.put(_encodeSummary(next!), key.toJS);
          });
        }).toJS,
      );
    });
    await outcome.done;
    return next!;
  }

  @override
  Future<RecoveryJob?> read(RecoveryScope scope, String id) async {
    final key = recoveryKey(scope, id);
    final tx = _transaction(['jobs', 'files']);
    final outcome = _Outcome(tx);
    JSAny? rawJob;
    JSAny? rawFiles;
    outcome.run(() {
      final job = tx.objectStore('jobs').get(key.toJS);
      final files = tx.objectStore('files').get(key.toJS);
      job.addEventListener(
        'success',
        ((web.Event _) {
          rawJob = job.result;
        }).toJS,
      );
      files.addEventListener(
        'success',
        ((web.Event _) {
          rawFiles = files.result;
        }).toJS,
      );
    });
    await outcome.done;
    if (rawJob.isUndefinedOrNull) return null;
    try {
      final summary = _decodeSummary(rawJob as JSObject);
      if (summary.key != key || rawFiles.isUndefinedOrNull) {
        throw const FormatException('Missing saved bytes');
      }
      final files = _decodeFiles(rawFiles as JSArray<JSObject>);
      if (files.length != summary.fileSizes.length ||
          summary.fileSizes.entries.any(
            (e) => files[e.key]?.length != e.value,
          )) {
        throw const FormatException('Saved byte length mismatch');
      }
      return RecoveryJob(summary: summary, files: files);
    } catch (_) {
      throw const UploadRecoveryException(
        RecoveryFailure.corrupt,
        'This saved upload is incomplete. Its bytes cannot be safely restored.',
      );
    }
  }

  @override
  Future<List<RecoverySummary>> list(RecoveryScope scope) async {
    final tx = _transaction(['jobs']);
    final outcome = _Outcome(tx);
    final summaries = <RecoverySummary>[];
    outcome.run(() {
      final request = tx
          .objectStore('jobs')
          .index('scope')
          .getAll(scope.key.toJS);
      request.addEventListener(
        'success',
        ((web.Event _) {
          outcome.run(() {
            for (final item in (request.result as JSArray<JSObject>).toDart) {
              final summary = _decodeSummary(item);
              if (summary.scope.key != scope.key) {
                throw const FormatException('Scope mismatch');
              }
              summaries.add(summary);
            }
          });
        }).toJS,
      );
    });
    await outcome.done;
    summaries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return summaries;
  }

  @override
  Future<void> remove(
    RecoveryScope scope,
    String id, {
    required int expectedRevision,
  }) async {
    final key = recoveryKey(scope, id);
    final tx = _transaction(['jobs', 'files'], write: true);
    final outcome = _Outcome(tx);
    outcome.run(() {
      final jobs = tx.objectStore('jobs');
      final request = jobs.get(key.toJS);
      request.addEventListener(
        'success',
        ((web.Event _) {
          outcome.run(() {
            if (request.result.isUndefinedOrNull) return;
            checkRevision(
              _decodeSummary(request.result as JSObject),
              expectedRevision,
            );
            jobs.delete(key.toJS);
            tx.objectStore('files').delete(key.toJS);
          });
        }).toJS,
      );
    });
    await outcome.done;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([for (final lease in List.of(_leases)) lease.release()]);
    _db.close();
  }
}

class _BrowserLease implements RecoveryLease {
  _BrowserLease(this._released, this._finished, this._remove);
  final Completer<void> _released;
  final Future<void> Function() _finished;
  final void Function() _remove;
  @override
  Future<void> release() async {
    if (!_released.isCompleted) _released.complete();
    await _finished();
    _remove();
  }
}

JSObject _encodeSummary(RecoverySummary summary) => JSObject()
  ..setProperty('scope'.toJS, summary.scope.key.toJS)
  ..setProperty('json'.toJS, jsonEncode(summary.toJson()).toJS);

RecoverySummary _decodeSummary(JSObject value) {
  try {
    final json = value.getProperty<JSString>('json'.toJS).toDart;
    return RecoverySummary.fromJson(
      Map<String, Object?>.from(jsonDecode(json) as Map),
    );
  } catch (_) {
    throw const UploadRecoveryException(
      RecoveryFailure.corrupt,
      'This saved upload cannot be safely read.',
    );
  }
}

JSArray<JSObject> _encodeFiles(Map<String, Uint8List> files) => [
  for (final entry in files.entries)
    JSObject()
      ..setProperty('name'.toJS, entry.key.toJS)
      ..setProperty('bytes'.toJS, Uint8List.fromList(entry.value).toJS),
].toJS;

Map<String, Uint8List> _decodeFiles(JSArray<JSObject> files) => {
  for (final item in files.toDart)
    item.getProperty<JSString>('name'.toJS).toDart: item
        .getProperty<JSUint8Array>('bytes'.toJS)
        .toDart,
};

class _Outcome {
  _Outcome(this.transaction) {
    transaction.addEventListener(
      'complete',
      ((web.Event _) {
        if (!_complete.isCompleted) _complete.complete();
      }).toJS,
    );
    transaction.addEventListener(
      'abort',
      ((web.Event _) {
        if (!_complete.isCompleted) {
          _complete.completeError(_error ?? _failure(transaction.error));
        }
      }).toJS,
    );
  }

  final web.IDBTransaction transaction;
  final _complete = Completer<void>();
  UploadRecoveryException? _error;
  Future<void> get done => _complete.future;

  void run(void Function() action) {
    try {
      action();
    } catch (error) {
      abort(error);
    }
  }

  void abort(Object error) {
    _error ??= _failure(error);
    try {
      transaction.abort();
    } catch (_) {
      if (!_complete.isCompleted) _complete.completeError(_error!);
    }
  }
}

UploadRecoveryException _failure(Object? error) {
  if (error is UploadRecoveryException) return error;
  String? name;
  try {
    name = (error as JSObject).getProperty<JSString>('name'.toJS).toDart;
  } catch (_) {}
  return switch (name) {
    'QuotaExceededError' => const UploadRecoveryException(
      RecoveryFailure.quota,
      'The browser could not save this upload. Free storage space before paying.',
    ),
    'ConstraintError' => const UploadRecoveryException(
      RecoveryFailure.conflict,
      'This upload was already saved in another tab. Reopen its saved progress.',
    ),
    _ => const UploadRecoveryException(
      RecoveryFailure.unavailable,
      'The browser could not save upload recovery data. Try again before paying.',
    ),
  };
}
