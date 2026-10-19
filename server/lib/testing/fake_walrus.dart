/// An in-memory stand-in for Walrus and the bit of Sui the claim check
/// reads: Blob objects (over a GraphQL endpoint) and an aggregator.
///
/// Used by the server tests (through [client]), the browser test and local
/// development (through [handler], see `tool/credence_fake_walrus.dart`).
/// There is no wallet here: [store] plays the part of a person who stored a
/// file with their own wallet, and returns the Blob object's ID.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';

/// The package that defines Walrus `System` (and so `Blob`) on testnet.
const fakeWalrusPackage =
    '0xd84704c17fc870b8764832c535aa6b11f21a95cd6f5bb38a9b07d2cf42220c66';

/// A Blob object on the fake chain.
class FakeBlobObject {
  FakeBlobObject({
    required this.owner,
    required this.blobId,
    required this.decimalBlobId,
    required this.size,
    required this.startEpoch,
    required this.endEpoch,
    this.certified = true,
    this.type = '$fakeWalrusPackage::blob::Blob',
  });

  String owner;
  final String blobId;
  final String decimalBlobId;
  final int size;
  final int startEpoch;
  final int endEpoch;
  bool certified;

  /// Set to another package's type to test look-alike objects.
  String type;
}

class FakeWalrus {
  FakeWalrus({this.currentEpoch = 100});

  /// The epoch new blobs start in.
  int currentEpoch;

  /// Blob bytes by blob ID, as the aggregator serves them.
  final Map<String, Uint8List> blobs = {};

  /// Blob objects by object ID.
  final Map<String, FakeBlobObject> objects = {};

  /// Blob IDs whose reads return 404, as if their storage had ended (or the
  /// aggregator had not caught up yet).
  final Set<String> expired = {};

  /// When set, GraphQL answers with this HTTP status (Sui is down).
  int? graphqlStatus;

  /// GraphQL requests seen, for tests that count chain reads.
  int graphqlRequests = 0;

  int _objects = 0;

  /// The blob ID Walrus would give [bytes] (here: their SHA-256), and its
  /// on-chain form, a little-endian u256 in decimal.
  static ({String blobId, String decimal}) blobIdFor(List<int> bytes) {
    final digest = sha256.convert(bytes).bytes;
    var value = BigInt.zero;
    for (var i = digest.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(digest[i]);
    }
    return (
      blobId: base64Url.encode(digest).replaceAll('=', ''),
      decimal: value.toString(),
    );
  }

  /// Stores [bytes] as if [owner] had paid for them with their wallet, and
  /// returns the new Blob object's ID.
  String store(
    List<int> bytes, {
    required String owner,
    int epochs = 1,
    bool certified = true,
  }) {
    final id = blobIdFor(bytes);
    blobs[id.blobId] = Uint8List.fromList(bytes);
    final objectId =
        '0x${(++_objects).toRadixString(16).padLeft(4, '0')}'
        '${'f' * 60}';
    objects[objectId] = FakeBlobObject(
      owner: owner.toLowerCase(),
      blobId: id.blobId,
      decimalBlobId: id.decimal,
      size: bytes.length,
      startEpoch: currentEpoch,
      endEpoch: currentEpoch + epochs,
      certified: certified,
    );
    return objectId;
  }

  /// The fake as an HTTP client: GraphQL at `/graphql` and the aggregator
  /// at `/v1/blobs/…` on any host.
  late final http.Client client = MockClient((request) async {
    final response = await handler(
      Request(
        request.method,
        request.url,
        headers: request.headers,
        body: request.bodyBytes,
      ),
    );
    return http.Response.bytes(
      await response.read().expand((c) => c).toList(),
      response.statusCode,
      headers: response.headers,
    );
  });

  static const _cors = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, HEAD, POST, PUT, OPTIONS',
    'access-control-allow-headers': '*',
  };

  /// The fake as a shelf handler:
  /// * `POST /graphql`: the Blob object query `WalrusBlobChecker` sends;
  /// * `GET /v1/blobs/<blobId>`: the aggregator;
  /// * `PUT /v1/store?owner=0x…&epochs=N`: test-only, stands in for a
  ///   wallet-paid write; answers `{objectId, blobId}`.
  Handler get handler => (Request request) async {
    if (request.method == 'OPTIONS') return Response(204, headers: _cors);
    final path = request.url.path;
    if (request.method == 'POST' && path == 'graphql') {
      return _graphql(
        jsonDecode(await request.readAsString()) as Map<Object?, Object?>,
      );
    }
    if (request.method == 'PUT' && path == 'v1/store') {
      final bytes = await request.read().expand((c) => c).toList();
      final query = request.url.queryParameters;
      final owner = query['owner'];
      if (owner == null) return Response(400, body: 'owner is required');
      final objectId = store(
        bytes,
        owner: owner,
        epochs: int.tryParse(query['epochs'] ?? '') ?? 1,
      );
      return Response.ok(
        jsonEncode({'objectId': objectId, 'blobId': objects[objectId]!.blobId}),
        headers: {..._cors, 'content-type': 'application/json'},
      );
    }
    if ((request.method == 'GET' || request.method == 'HEAD') &&
        path.startsWith('v1/blobs/')) {
      final id = path.substring('v1/blobs/'.length);
      final data = blobs[id];
      if (data == null || expired.contains(id)) {
        return Response.notFound(
          jsonEncode({
            'error': {
              'code': 404,
              'status': 'NOT_FOUND',
              'message': 'blob not found',
            },
          }),
          headers: {..._cors, 'content-type': 'application/json'},
        );
      }
      // Like some aggregators, ignore Range and send the whole blob.
      return Response.ok(
        request.method == 'HEAD' ? null : data,
        headers: {
          ..._cors,
          'content-type': 'application/octet-stream',
          'content-length': '${data.length}',
        },
      );
    }
    return Response.notFound('not found', headers: _cors);
  };

  Response _graphql(Map<Object?, Object?> body) {
    graphqlRequests++;
    final status = graphqlStatus;
    if (status != null) {
      return Response(status, body: 'unavailable', headers: _cors);
    }
    final variables = body['variables'] as Map;
    if (variables.containsKey('version')) {
      return Response.ok(
        jsonEncode({
          'data': {
            'staking': {
              'dynamicField': {
                'value': {
                  'epoch': {'json': currentEpoch},
                  'duration': {'json': 86400000},
                  'state': {
                    'json': {
                      '@variant': 'EpochChangeDone',
                      'pos0': DateTime.utc(2026, 10, 15).millisecondsSinceEpoch,
                    },
                  },
                },
              },
            },
          },
        }),
        headers: {..._cors, 'content-type': 'application/json'},
      );
    }
    final id = (variables['blob'] as String).toLowerCase();
    final blob = objects[id];
    final data = {
      'staking': {
        'asMoveObject': {
          'contents': {
            'version': {'json': '1'},
          },
        },
      },
      'system': {
        'asMoveObject': {
          'contents': {
            'type': {'repr': '$fakeWalrusPackage::system::System'},
          },
        },
      },
      'blob': blob == null
          ? null
          : {
              'owner': {
                '__typename': 'AddressOwner',
                'address': {'address': blob.owner},
              },
              'asMoveObject': {
                'contents': {
                  'type': {'repr': blob.type},
                  'json': {
                    'blob_id': blob.decimalBlobId,
                    'size': '${blob.size}',
                    'registered_epoch': blob.startEpoch,
                    'certified_epoch': blob.certified ? blob.startEpoch : null,
                    'storage': {
                      'start_epoch': blob.startEpoch,
                      'end_epoch': blob.endEpoch,
                    },
                    'deletable': true,
                  },
                },
              },
            },
    };
    return Response.ok(
      jsonEncode({'data': data}),
      headers: {..._cors, 'content-type': 'application/json'},
    );
  }
}
