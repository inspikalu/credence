import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A public Walrus deployment and the endpoints this package reads from.
enum WalrusChain {
  testnet(
    graphql: 'https://graphql.testnet.sui.io/graphql',
    aggregator: 'https://aggregator.walrus-testnet.walrus.space',
    systemObject:
        '0x6c2547cbbc38025cf3adac45f63cb0a8d12ecf777cdc75a4971612bf97fdf6af',
    stakingObject:
        '0xbe46180321c30aab2f8b3501e24048377287fa708018a5b7c2792b35fe339ee3',
  ),
  mainnet(
    graphql: 'https://graphql.mainnet.sui.io/graphql',
    aggregator: 'https://aggregator.walrus-mainnet.walrus.space',
    systemObject:
        '0x2134d52768ea07e8c43570ef975eb3e4c27a39fa6396bef985b5abc58d03ddd2',
    stakingObject:
        '0x10b9d30c28448939ce6c4d6c6e0ffce4a7f8a4ada8248bdad09ef8b70e4a3904',
  );

  const WalrusChain({
    required this.graphql,
    required this.aggregator,
    required this.systemObject,
    required this.stakingObject,
  });

  final String graphql;
  final String aggregator;

  /// The Walrus `System` object; its type names the package that defines
  /// `Blob`.
  final String systemObject;

  /// The Walrus staking object holds the current epoch and its timing.
  final String stakingObject;

  /// `testnet` / `sui:testnet` (case-insensitive).
  static WalrusChain parse(String value) {
    final name = value.toLowerCase().replaceFirst('sui:', '');
    return WalrusChain.values.firstWhere(
      (chain) => chain.name == name,
      orElse: () => throw ArgumentError.value(value, 'chain', 'unknown'),
    );
  }
}

/// Current Walrus epoch timing, read from the staking contract.
class WalrusEpochInfo {
  const WalrusEpochInfo({
    required this.epoch,
    required this.duration,
    required this.startedAt,
    required this.observedAt,
  });

  final int epoch;
  final Duration duration;

  /// Null while the committee is synchronizing an epoch change.
  final DateTime? startedAt;
  final DateTime observedAt;

  /// An estimate based on the contract's epoch duration. Later epoch
  /// transitions can be delayed; the end epoch remains authoritative.
  DateTime? estimateExpiry(int endEpoch) => startedAt?.add(
    Duration(milliseconds: duration.inMilliseconds * (endEpoch - epoch)),
  );
}

/// A certified Walrus blob as recorded on Sui.
class StoredBlob {
  const StoredBlob({
    required this.objectId,
    required this.blobId,
    required this.size,
    required this.owner,
    required this.deletable,
    required this.registeredEpoch,
    required this.certifiedEpoch,
    required this.startEpoch,
    required this.endEpoch,
    this.epochInfo,
  });

  /// The Sui `Blob` object.
  final String objectId;

  /// URL-safe base64 blob ID, as aggregators use it.
  final String blobId;

  /// Unencoded size in bytes, as registered on chain.
  final int size;

  final String owner;
  final bool deletable;
  final int registeredEpoch;
  final int certifiedEpoch;

  /// First Walrus epoch of the storage period.
  final int startEpoch;

  /// Storage ends at the start of this Walrus epoch.
  final int endEpoch;

  /// Always present on results returned by [WalrusBlobChecker.check].
  /// Optional for callers constructing records themselves.
  final WalrusEpochInfo? epochInfo;

  Map<String, Object> toJson() => {
    'objectId': objectId,
    'blobId': blobId,
    'size': size,
    'owner': owner,
    'deletable': deletable,
    'registeredEpoch': registeredEpoch,
    'certifiedEpoch': certifiedEpoch,
    'startEpoch': startEpoch,
    'endEpoch': endEpoch,
  };
}

/// Why a blob was not accepted.
enum BlobCheckProblem {
  /// No object with that ID (or not visible yet).
  notFound,

  /// The object exists but is not a Walrus `Blob` of this deployment.
  notWalrusBlob,

  /// The blob belongs to another address, or is not address-owned.
  wrongOwner,

  /// The blob was registered but never certified.
  notCertified,

  /// The storage period has ended on the Walrus chain.
  expired,

  /// Sui or the aggregator could not be reached or answered oddly.
  unavailable,
}

class BlobCheckException implements Exception {
  const BlobCheckException(this.problem, this.message);

  final BlobCheckProblem problem;
  final String message;

  @override
  String toString() => 'BlobCheckException(${problem.name}): $message';
}

/// Checks Walrus blobs on Sui (over GraphQL) and reads their first bytes
/// from an aggregator. For servers that let people store files with their
/// own wallet and then claim them: never trust the client's word for who
/// owns a blob, its size, or whether it was certified.
class WalrusBlobChecker {
  WalrusBlobChecker({
    required this.chain,
    http.Client? client,
    Uri? graphqlUrl,
    Uri? aggregatorUrl,
    this.timeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : graphqlUrl = graphqlUrl ?? Uri.parse(chain.graphql),
       aggregatorUrl = aggregatorUrl ?? Uri.parse(chain.aggregator),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  final WalrusChain chain;
  final Uri graphqlUrl;
  final Uri aggregatorUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  static const maxGraphqlBytes = 256 * 1024;

  String? _blobType;

  static const _query = r'''
query ($blob: SuiAddress!, $system: SuiAddress!, $staking: SuiAddress!) {
  blob: object(address: $blob) {
    owner { __typename ... on AddressOwner { address { address } } }
    asMoveObject { contents { type { repr } json } }
  }
  system: object(address: $system) {
    asMoveObject { contents { type { repr } } }
  }
  staking: object(address: $staking) {
    asMoveObject { contents { version: extract(path: "version") { json } } }
  }
}''';

  static const _stakingQuery = r'''
query ($staking: SuiAddress!) {
  staking: object(address: $staking) {
    asMoveObject { contents { version: extract(path: "version") { json } } }
  }
}''';

  static const _epochQuery = r'''
query ($staking: SuiAddress!, $version: Base64!) {
  staking: object(address: $staking) {
    dynamicField(name: {type: "u64", bcs: $version}) {
      value {
        ... on MoveValue {
          epoch: extract(path: "epoch") { json }
          duration: extract(path: "epoch_duration") { json }
          state: extract(path: "epoch_state") { json }
        }
      }
    }
  }
}''';

  /// Reads the current Walrus epoch. No epoch is cached across claims.
  Future<WalrusEpochInfo> currentEpoch() async {
    final data = await _graphql(_stakingQuery, {
      'staking': chain.stakingObject,
    });
    return _epochFromStaking(data['staking']);
  }

  Future<WalrusEpochInfo> _epochFromStaking(Object? staking) async {
    try {
      final version = BigInt.parse(
        '${_path(staking, ['asMoveObject', 'contents', 'version', 'json'])}',
      );
      if (version.isNegative || version.bitLength > 64) {
        throw const FormatException('staking version is out of range');
      }
      final versionBytes = Uint8List(8);
      var remaining = version;
      for (var i = 0; i < versionBytes.length; i++) {
        versionBytes[i] = (remaining & BigInt.from(255)).toInt();
        remaining >>= 8;
      }
      final data = await _graphql(_epochQuery, {
        'staking': chain.stakingObject,
        'version': base64.encode(versionBytes),
      });
      final value = _path(data, ['staking', 'dynamicField', 'value']);
      final epoch = _int(_path(value, ['epoch', 'json']));
      final duration = _int(_path(value, ['duration', 'json']));
      final state = _path(value, ['state', 'json']);
      if (epoch < 0 || duration <= 0 || state is! Map) {
        throw const FormatException('invalid Walrus epoch timing');
      }
      final variant = state['@variant'];
      DateTime? startedAt;
      if (variant == 'EpochChangeDone' || variant == 'NextParamsSelected') {
        final milliseconds = _int(state['pos0']);
        if (milliseconds < 0) {
          throw const FormatException('negative epoch start');
        }
        startedAt = DateTime.fromMillisecondsSinceEpoch(
          milliseconds,
          isUtc: true,
        );
      } else if (variant != 'EpochChangeSync') {
        throw const FormatException('unknown Walrus epoch state');
      }
      return WalrusEpochInfo(
        epoch: epoch,
        duration: Duration(milliseconds: duration),
        startedAt: startedAt,
        observedAt: _clock().toUtc(),
      );
    } on FormatException catch (e) {
      throw BlobCheckException(
        BlobCheckProblem.unavailable,
        'Unexpected Walrus epoch: ${e.message}',
      );
    } on ArgumentError {
      throw const BlobCheckException(
        BlobCheckProblem.unavailable,
        'Walrus returned an invalid epoch timestamp.',
      );
    }
  }

  /// The blob in object [objectId], after checking that it is a certified
  /// Walrus `Blob` owned by [owner]. Throws [BlobCheckException].
  Future<StoredBlob> check(String objectId, {required String owner}) async {
    final id = normalizeSuiAddress(objectId);
    final data = await _graphql(_query, {
      'blob': id,
      'system': chain.systemObject,
      'staking': chain.stakingObject,
    });

    final blobType = _blobType ??= _blobTypeFrom(data['system']);

    final object = data['blob'];
    if (object is! Map) {
      throw BlobCheckException(
        BlobCheckProblem.notFound,
        'No object $id on ${chain.name}.',
      );
    }
    final contents = _path(object, ['asMoveObject', 'contents']);
    final type = _path(contents, ['type', 'repr']);
    if (type != blobType) {
      throw BlobCheckException(
        BlobCheckProblem.notWalrusBlob,
        'Object $id is not a Walrus blob.',
      );
    }

    final ownerAddress = _path(object, ['owner', 'address', 'address']);
    if (ownerAddress is! String ||
        ownerAddress.toLowerCase() != normalizeSuiAddress(owner)) {
      throw BlobCheckException(
        BlobCheckProblem.wrongOwner,
        'Blob $id is not owned by $owner.',
      );
    }

    final json = _path(contents, ['json']);
    if (json is! Map) {
      throw const BlobCheckException(
        BlobCheckProblem.unavailable,
        'Sui returned a blob without contents.',
      );
    }
    final certified = json['certified_epoch'];
    if (certified == null) {
      throw BlobCheckException(
        BlobCheckProblem.notCertified,
        'Blob $id was registered but not certified.',
      );
    }
    final storage = json['storage'];
    if (storage is! Map) {
      throw const BlobCheckException(
        BlobCheckProblem.unavailable,
        'Sui returned a blob without storage.',
      );
    }
    final epochInfo = await _epochFromStaking(data['staking']);
    try {
      final endEpoch = _int(storage['end_epoch']);
      if (endEpoch <= epochInfo.epoch) {
        throw BlobCheckException(
          BlobCheckProblem.expired,
          'Blob $id expired at Walrus epoch $endEpoch.',
        );
      }
      return StoredBlob(
        objectId: id,
        blobId: blobIdFromDecimal('${json['blob_id']}'),
        size: _int(json['size']),
        owner: ownerAddress.toLowerCase(),
        deletable: json['deletable'] == true,
        registeredEpoch: _int(json['registered_epoch']),
        certifiedEpoch: _int(certified),
        startEpoch: _int(storage['start_epoch']),
        endEpoch: endEpoch,
        epochInfo: epochInfo,
      );
    } on FormatException catch (e) {
      throw BlobCheckException(
        BlobCheckProblem.unavailable,
        'Unexpected blob contents: ${e.message}',
      );
    }
  }

  /// The first [length] bytes of [blobId] from the aggregator (fewer if the
  /// blob is shorter), for checking its file type. Throws
  /// [BlobCheckException]: `notFound` when the aggregator does not have it.
  Future<Uint8List> readStart(String blobId, {int length = 64}) =>
      _readStart('v1/blobs/${Uri.encodeComponent(blobId)}', blobId, length);

  /// Like [readStart], for one file of a quilt. Check first that the patch
  /// belongs to a blob you verified: `quiltBlobIdOf(patchId) == blob.blobId`.
  Future<Uint8List> readPatchStart(String patchId, {int length = 64}) =>
      _readStart(
        'v1/blobs/by-quilt-patch-id/${Uri.encodeComponent(patchId)}',
        patchId,
        length,
      );

  /// Reads a patch's actual byte size. Returns at most [maxBytes] + 1
  /// when an aggregator ignores Range, enough to reject an oversized file.
  Future<int> readPatchSize(String patchId, {required int maxBytes}) async {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    final uri = aggregatorUrl.replace(
      path:
          '${aggregatorUrl.path.replaceFirst(RegExp(r'/$'), '')}'
          '/v1/blobs/by-quilt-patch-id/${Uri.encodeComponent(patchId)}',
    );
    final response = await _send(
      http.Request('GET', uri)..headers['Range'] = 'bytes=0-0',
      'Aggregator',
    );
    if (response.statusCode == 206) {
      unawaited(
        response.stream.listen(null).cancel().catchError((Object _) {}),
      );
      final range = RegExp(
        r'^bytes 0-0/([1-9][0-9]*)$',
      ).firstMatch(response.headers['content-range'] ?? '');
      final size = range == null ? null : int.tryParse(range.group(1)!);
      if (size == null) {
        throw const BlobCheckException(
          BlobCheckProblem.unavailable,
          'The aggregator returned an invalid patch size.',
        );
      }
      return size;
    }
    if (response.statusCode != 200) {
      unawaited(
        response.stream.listen(null).cancel().catchError((Object _) {}),
      );
      throw BlobCheckException(
        response.statusCode == 404
            ? BlobCheckProblem.notFound
            : BlobCheckProblem.unavailable,
        'Aggregator answered ${response.statusCode} for patch $patchId.',
      );
    }
    return (await _readBounded(
      response.stream,
      maxBytes + 1,
      prefix: true,
    )).length;
  }

  Future<Uint8List> _readStart(String route, String blobId, int length) async {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    final uri = aggregatorUrl.replace(
      path: '${aggregatorUrl.path.replaceFirst(RegExp(r'/$'), '')}/$route',
    );
    final request = http.Request('GET', uri)
      ..headers['Range'] = 'bytes=0-${length - 1}';
    final response = await _send(request, 'Aggregator');
    if (response.statusCode != 200 && response.statusCode != 206) {
      // Do not drain an unbounded error body before returning the error.
      unawaited(
        response.stream.listen(null).cancel().catchError((Object _) {}),
      );
      throw BlobCheckException(
        response.statusCode == 404
            ? BlobCheckProblem.notFound
            : BlobCheckProblem.unavailable,
        'Aggregator answered ${response.statusCode} for blob $blobId.',
      );
    }
    return _readBounded(response.stream, length, prefix: true);
  }

  Future<http.StreamedResponse> _send(
    http.Request request,
    String source,
  ) async {
    try {
      return await _client.send(request).timeout(timeout);
    } on Object catch (e) {
      throw BlobCheckException(
        BlobCheckProblem.unavailable,
        '$source unreachable: $e',
      );
    }
  }

  Future<Uint8List> _readBounded(
    Stream<List<int>> stream,
    int limit, {
    bool prefix = false,
  }) async {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (chunk) {
        if (done.isCompleted) return;
        final remaining = limit - bytes.length;
        if (!prefix && chunk.length > remaining) {
          done.completeError(
            const BlobCheckException(
              BlobCheckProblem.unavailable,
              'The response is too large.',
            ),
          );
          return;
        }
        // Copy only the bytes needed, even when the server ignores Range.
        bytes.add(
          chunk.length > remaining ? chunk.sublist(0, remaining) : chunk,
        );
        if (prefix && bytes.length == limit) done.complete(bytes.takeBytes());
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    try {
      // This is a total body deadline, including servers that trickle bytes.
      return await done.future.timeout(timeout);
    } on BlobCheckException {
      rethrow;
    } on Object catch (e) {
      throw BlobCheckException(
        BlobCheckProblem.unavailable,
        'Reading the response failed: $e',
      );
    } finally {
      // Cleanup must not extend the deadline or hide the read result.
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  /// Close the HTTP client if this checker created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<Object?, Object?>> _graphql(
    String query,
    Map<String, Object?> variables,
  ) async {
    final request = http.Request('POST', graphqlUrl)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({'query': query, 'variables': variables});
    final response = await _send(request, 'Sui GraphQL');
    if (response.statusCode != 200) {
      unawaited(
        response.stream.listen(null).cancel().catchError((Object _) {}),
      );
      throw BlobCheckException(
        BlobCheckProblem.unavailable,
        'Sui GraphQL answered ${response.statusCode}.',
      );
    }
    final bytes = await _readBounded(response.stream, maxGraphqlBytes);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      // Not JSON; reported below.
    }
    final errors = decoded is Map ? decoded['errors'] : null;
    final data = decoded is Map ? decoded['data'] : null;
    if (errors != null || data is! Map) {
      throw const BlobCheckException(
        BlobCheckProblem.unavailable,
        'Sui GraphQL returned an invalid response.',
      );
    }
    return data;
  }

  static Object? _path(Object? value, List<String> keys) {
    var current = value;
    for (final key in keys) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current;
  }

  /// `Blob` is defined in the package that first defined `System`, which
  /// the system object's type names.
  static String _blobTypeFrom(Object? system) {
    final type = _path(system, ['asMoveObject', 'contents', 'type', 'repr']);
    if (type is! String || !type.contains('::')) {
      throw const BlobCheckException(
        BlobCheckProblem.unavailable,
        'Could not read the Walrus system object.',
      );
    }
    return '${type.split('::').first}::blob::Blob';
  }

  static int _int(Object? value) => switch (value) {
    final int n => n,
    final String s => int.parse(s),
    _ => throw FormatException('not an integer: $value'),
  };
}

/// `0x` + 64 lowercase hex digits.
String normalizeSuiAddress(String address) {
  final hex = address.toLowerCase().replaceFirst('0x', '');
  if (hex.isEmpty || hex.length > 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(hex)) {
    throw ArgumentError.value(address, 'address', 'not a Sui address');
  }
  return '0x${hex.padLeft(64, '0')}';
}

/// The URL-safe base64 blob ID for a blob ID stored on chain as a decimal
/// u256 (little-endian bytes).
String blobIdFromDecimal(String decimal) {
  var value = BigInt.parse(decimal);
  if (value.isNegative || value.bitLength > 256) {
    throw FormatException('blob ID out of range: $decimal');
  }
  final bytes = Uint8List(32);
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (value & mask).toInt();
    value >>= 8;
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The blob ID of the quilt a quilt patch ID points into. A patch ID is the
/// quilt's 32-byte blob ID followed by a version and a column range.
String quiltBlobIdOf(String patchId) {
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(patchId));
  } on FormatException {
    throw FormatException('not a quilt patch ID: $patchId');
  }
  if (bytes.length != 37 || bytes[32] != 1) {
    throw FormatException('not a quilt patch ID: $patchId');
  }
  return base64Url.encode(bytes.sublist(0, 32)).replaceAll('=', '');
}
