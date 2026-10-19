import 'dart:async';
import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;

/// Why a Walrus operation failed, in words people can act on.
class WalrusFailure implements Exception {
  const WalrusFailure(this.kind, this.message);

  final WalrusFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

enum WalrusFailureKind {
  /// The aggregator has no such blob: storage ended or it was deleted.
  unavailable,

  /// Network trouble or a timeout; retrying may help.
  network,

  /// The aggregator failed.
  server,
}

/// Reads files from Walrus: the Dartus [WalrusClient] in HTTP mode, against
/// the aggregator from server config. Nobody needs a wallet to read.
///
/// Writes do not go through here: the owner's wallet pays for storage with
/// Dartus's `WalrusWriter` (see `storage.dart`).
class WalrusService {
  WalrusService({
    required Uri aggregatorBaseUrl,
    http.Client? httpClient,
    Duration timeout = const Duration(minutes: 3),
  }) : client = WalrusClient(
         // Reads only; WalrusClient wants a publisher URL all the same.
         publisherBaseUrl: aggregatorBaseUrl,
         aggregatorBaseUrl: aggregatorBaseUrl,
         timeout: timeout,
         httpClient: httpClient,
         cacheMaxSize: 8,
       );

  final WalrusClient client;

  /// Reads a blob from the aggregator.
  ///
  /// With [fresh], any cached copy is dropped first so the bytes really come
  /// from Walrus. Dartus `getBlob` always consults its cache, so the cache
  /// entry is removed explicitly.
  ///
  /// A blob that was certified moments ago can still answer 404 for a while
  /// on some aggregators. With [waitIfMissing], a 404 is retried with
  /// growing pauses until that much time has passed.
  Future<Uint8List> read(
    String blobId, {
    bool fresh = false,
    Duration waitIfMissing = Duration.zero,
    Duration Function(int attempt)? backoff,
  }) async {
    final deadline = DateTime.now().add(waitIfMissing);
    for (var attempt = 1; ; attempt++) {
      try {
        return await _readOnce(blobId, fresh: fresh || attempt > 1);
      } on WalrusFailure catch (e) {
        final pause = (backoff ?? _defaultBackoff)(attempt);
        final canRetry =
            e.kind == WalrusFailureKind.unavailable &&
            DateTime.now().add(pause).isBefore(deadline);
        if (!canRetry) rethrow;
        await Future<void>.delayed(pause);
      }
    }
  }

  static Duration _defaultBackoff(int attempt) =>
      Duration(seconds: attempt < 4 ? 2 * attempt : 8);

  Future<Uint8List> _readOnce(String blobId, {required bool fresh}) async {
    try {
      if (fresh) await client.cache.remove(blobId);
      return await client.getBlob(blobId);
    } on WalrusApiError catch (e) {
      throw _fromApiError(e);
    } on TimeoutException {
      throw const WalrusFailure(
        WalrusFailureKind.network,
        'Walrus took too long to answer. Try again.',
      );
    } on Exception {
      throw const WalrusFailure(
        WalrusFailureKind.network,
        'Could not reach the Walrus aggregator. Check your connection and '
        'try again.',
      );
    }
  }

  WalrusFailure _fromApiError(WalrusApiError e) {
    if (e.code == 404) {
      return const WalrusFailure(
        WalrusFailureKind.unavailable,
        'Walrus no longer has this file. Its storage period may have ended, '
        'or its owner deleted it.',
      );
    }
    return WalrusFailure(
      WalrusFailureKind.server,
      'The Walrus aggregator had a problem (HTTP ${e.code}). Try again.',
    );
  }

  Future<void> close() => client.close();
}
