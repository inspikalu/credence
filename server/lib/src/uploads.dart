import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:sui_auth/sui_auth.dart' show SuiAuthRequest;
import 'package:walrus_blob_check/walrus_blob_check.dart';

import 'config.dart';
import 'json.dart';
import 'rate_limit.dart';
import 'sniff.dart';
import 'store.dart';
import 'validation.dart';

/// `POST /api/uploads`: list a file the signed-in owner stored on Walrus
/// with their own wallet.
///
/// The browser stores the file itself (Dartus's `WalrusWriter`: the
/// person's wallet pays, and the Blob object belongs to them), then posts
/// only the Blob object ID. Nothing else the browser says is trusted:
///
/// * [WalrusBlobChecker.check] reads the object on Sui: a certified Walrus
///   `Blob` owned by the session address. Size, blob ID and storage epochs
///   come from the chain.
/// * The size must be within `MAX_UPLOAD_MB`.
/// * The whole file is read back from the aggregator. Its type comes from
///   its first bytes (PDF, PNG, JPEG or WebP) and its SHA-256 fingerprint is
///   computed here, so a record can only name the bytes that are on Walrus.
/// * Each Blob object can be listed once.
class UploadClaims {
  UploadClaims({
    required this.config,
    required this.store,
    required this.checker,
    RateLimiter? limiter,
    DateTime Function()? clock,
  }) : _limiter =
           limiter ??
           RateLimiter(limit: 1000, window: const Duration(hours: 24)),
       _clock = clock ?? DateTime.now;

  final ServerConfig config;
  final Store store;
  final WalrusBlobChecker checker;
  final RateLimiter _limiter;
  final DateTime Function() _clock;

  static final _objectId = RegExp(r'^0x[0-9a-fA-F]{1,64}$');

  Future<Response> claim(Request request) async {
    final owner = request.suiAddress;
    if (owner == null) {
      throw const ApiException(
        401,
        'UNAUTHENTICATED',
        'Sign in with your Sui wallet to add files.',
      );
    }
    final body = await readJsonObject(request);
    final raw = body['objectId'];
    if (raw is! String || !_objectId.hasMatch(raw)) {
      throw badField('objectId', 'objectId must be a Sui object ID (0x…).');
    }
    final objectId = normalizeSuiAddress(raw);
    // Abuse limit only (people pay for their own storage). It counts
    // attempts, including the app's retries while Sui catches up.
    if (!_limiter.allow(owner)) {
      throw const ApiException(
        429,
        'RATE_LIMITED',
        'This account has added a lot of files today. Try again tomorrow.',
      );
    }

    final StoredBlob blob;
    try {
      blob = await checker.check(objectId, owner: owner);
    } on BlobCheckException catch (e) {
      throw _fromCheck(e, reading: false);
    }
    if (store.objectClaimed(blob.objectId)) {
      throw const ApiException(
        409,
        'ALREADY_CLAIMED',
        'This file is already listed on Credence.',
      );
    }
    if (blob.size > config.maxUploadBytes) {
      throw ApiException(
        413,
        'TOO_LARGE',
        'Files can be at most ${config.maxUploadMb} MB.',
      );
    }
    if (blob.size == 0) {
      throw const ApiException(400, 'EMPTY_FILE', 'The file is empty.');
    }

    final List<int> bytes;
    try {
      bytes = await checker.readStart(blob.blobId, length: blob.size);
    } on BlobCheckException catch (e) {
      throw _fromCheck(e, reading: true);
    }
    if (bytes.length != blob.size) {
      throw const ApiException(
        502,
        'AGGREGATOR_INCOMPLETE',
        'Walrus sent only part of the file. Try again.',
      );
    }
    final contentType = sniffContentType(bytes);
    if (contentType == null) {
      throw const ApiException(
        415,
        'UNSUPPORTED_TYPE',
        'Only PDF, PNG, JPEG and WebP files can be stored.',
      );
    }

    final upload = store.recordUpload(
      ownerAddress: owner,
      blobId: blob.blobId,
      sha256: sha256.convert(bytes).toString(),
      sizeBytes: blob.size,
      contentType: contentType,
      objectId: blob.objectId,
      endEpoch: blob.endEpoch,
      registeredEpoch: blob.startEpoch,
      estimatedExpiresAt: blob.epochInfo?.estimateExpiry(blob.endEpoch),
      now: _clock(),
    );
    return jsonResponse({'upload': upload}, status: 201);
  }

  /// The statuses the example's `BlobShelf` uses, worded for people.
  static ApiException _fromCheck(
    BlobCheckException e, {
    required bool reading,
  }) => switch (e.problem) {
    // A full node or aggregator can trail the wallet by a moment; the app
    // retries a 404.
    BlobCheckProblem.notFound => ApiException(
      404,
      reading ? 'NOT_ON_WALRUS_YET' : 'BLOB_NOT_FOUND',
      reading
          ? 'Walrus is not serving this file yet. Try again in a moment.'
          : 'Sui does not show this file yet. Try again in a moment.',
    ),
    BlobCheckProblem.notCertified => const ApiException(
      409,
      'BLOB_NOT_CERTIFIED',
      'This file was paid for but not finished. Finish storing it, then try '
          'again.',
    ),
    BlobCheckProblem.expired => const ApiException(
      410,
      'BLOB_EXPIRED',
      'This file’s storage period has ended. Store it again before listing it.',
    ),
    BlobCheckProblem.wrongOwner ||
    BlobCheckProblem.notWalrusBlob => const ApiException(
      403,
      'NOT_YOUR_BLOB',
      'This file on Walrus does not belong to the signed-in account.',
    ),
    BlobCheckProblem.unavailable => const ApiException(
      502,
      'SUI_UNAVAILABLE',
      'Could not check the file on Sui and Walrus. Try again.',
    ),
  };
}
