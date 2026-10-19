import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// An error from the Credence API, with a message fit to show people.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, {this.field});

  final int status;
  final String code;
  final String message;
  final String? field;

  bool get isNotFound => status == 404;
  bool get isNetwork => status == 0;

  /// Not signed in, or the session ended.
  bool get isSignedOut => status == 401;

  /// Signed in, but as someone who does not own this vault.
  bool get isForbidden => status == 403;

  @override
  String toString() => message;
}

/// Fields for a new document record (file facts come from the checked
/// upload).
class NewDocument {
  const NewDocument({
    required this.title,
    required this.issuerName,
    required this.recipientName,
    required this.issueDate,
    required this.notes,
    required this.fileName,
    required this.sha256,
    required this.blobId,
    this.requestId,
  });

  final String title;
  final String issuerName;
  final String recipientName;
  final String issueDate;
  final String notes;
  final String fileName;
  final String sha256;
  final String blobId;
  final String? requestId;

  Map<String, Object?> toJson() => {
    'title': title,
    'issuerName': issuerName,
    'recipientName': recipientName,
    'issueDate': issueDate,
    'notes': notes,
    'fileName': fileName,
    'sha256': sha256,
    'blobId': blobId,
    if (requestId != null) 'requestId': requestId,
  };
}

/// A file the owner stored with their wallet, as the server listed it after
/// checking the Blob object on Sui and reading the bytes back from Walrus.
class ClaimedUpload {
  const ClaimedUpload({
    required this.blobId,
    required this.sha256,
    required this.contentType,
    required this.sizeBytes,
  });

  factory ClaimedUpload.fromJson(Map<String, Object?> json) => ClaimedUpload(
    blobId: json['blobId']! as String,
    sha256: json['sha256']! as String,
    contentType: json['contentType']! as String,
    sizeBytes: json['sizeBytes']! as int,
  );

  final String blobId;
  final String sha256;
  final String contentType;
  final int sizeBytes;
}

/// Talks to the Credence metadata API. Walrus traffic goes through Dartus.
///
/// Owner-only calls rely on the session cookie set by sign-in, which the
/// browser sends by itself; nothing secret is held in Dart.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String path) => baseUrl.resolve(path);

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, _uri(path));
    request.headers['accept'] = 'application/json';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on TimeoutException {
      throw const ApiException(
        0,
        'TIMEOUT',
        'Credence took too long to answer. Try again.',
      );
    } on Exception {
      throw const ApiException(
        0,
        'NETWORK',
        'Could not reach Credence. Check your connection and try again.',
      );
    }
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, Object?>) return decoded;
      throw ApiException(
        response.statusCode,
        'BAD_RESPONSE',
        'Credence sent a response the app could not read.',
      );
    }
    if (decoded is Map<String, Object?> && decoded['error'] is Map) {
      final e = decoded['error'] as Map;
      throw ApiException(
        response.statusCode,
        e['status'] is String ? e['status'] as String : 'ERROR',
        e['message'] is String
            ? e['message'] as String
            : 'Something went wrong. Try again.',
        field: e['field'] is String ? e['field'] as String : null,
      );
    }
    throw ApiException(
      response.statusCode,
      'HTTP_${response.statusCode}',
      response.statusCode >= 500
          ? 'Credence had a problem (HTTP ${response.statusCode}). Try again.'
          : 'The request failed (HTTP ${response.statusCode}).',
    );
  }

  Future<AppConfig> config() async =>
      AppConfig.fromJson(await _send('GET', '/api/config'));

  /// Creates a vault owned by the signed-in address.
  Future<Vault> createVault({
    required String name,
    required VaultKind kind,
    String about = '',
    String website = '',
  }) async {
    final json = await _send(
      'POST',
      '/api/vaults',
      body: {
        'name': name,
        'kind': kind.name,
        'about': about,
        'website': website,
      },
    );
    return Vault.fromJson(json['vault']! as Map<String, Object?>);
  }

  /// Vaults owned by the signed-in address.
  Future<List<Vault>> myVaults() async {
    final json = await _send('GET', '/api/my/vaults');
    return [
      for (final v in json['vaults']! as List<Object?>)
        Vault.fromJson(v! as Map<String, Object?>),
    ];
  }

  Future<VaultPage> vault(String id) async =>
      VaultPage.fromJson(await _send('GET', '/api/vaults/$id'));

  /// The owner's view of a vault, revoked documents included.
  Future<VaultPage> vaultForOwner(String id) async =>
      VaultPage.fromJson(await _send('GET', '/api/vaults/$id/manage'));

  Future<Vault> updateVault(
    String id, {
    String? name,
    String? about,
    String? website,
  }) async {
    final json = await _send(
      'PATCH',
      '/api/vaults/$id',
      body: {'name': ?name, 'about': ?about, 'website': ?website},
    );
    return Vault.fromJson(json['vault']! as Map<String, Object?>);
  }

  /// Asks the server to list a Blob object the signed-in owner stored with
  /// their wallet. A full node or aggregator can trail the wallet by a
  /// moment, so a 404 (or "not certified yet") is retried [attempts] times,
  /// [pause] apart. Returns
  /// null when the object was already listed (an earlier try got through).
  Future<ClaimedUpload?> claimUpload(
    String objectId, {
    int attempts = 15,
    Duration pause = const Duration(seconds: 2),
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final json = await _send(
          'POST',
          '/api/uploads',
          body: {'objectId': objectId},
        );
        return ClaimedUpload.fromJson(json['upload']! as Map<String, Object?>);
      } on ApiException catch (e) {
        if (e.code == 'ALREADY_CLAIMED') return null;
        // Sui's GraphQL can trail the wallet: right after the certify
        // transaction it may not show the object (404) or still show it
        // as uncertified (409 BLOB_NOT_CERTIFIED, seen on testnet).
        final lagging = e.isNotFound || e.code == 'BLOB_NOT_CERTIFIED';
        if (!lagging || attempt >= attempts) rethrow;
        await Future<void>.delayed(pause);
      }
    }
  }

  Future<DocumentRecord> createDocument(
    String vaultId,
    NewDocument document,
  ) async {
    final json = await _send(
      'POST',
      '/api/vaults/$vaultId/documents',
      body: document.toJson(),
    );
    return DocumentRecord.fromJson(json['document']! as Map<String, Object?>);
  }

  Future<DocumentPage> document(String id) async =>
      DocumentPage.fromJson(await _send('GET', '/api/documents/$id'));

  Future<DocumentRecord> editDocument(
    String id, {
    required Map<String, String> changes,
    required String note,
  }) async {
    final json = await _send(
      'PATCH',
      '/api/documents/$id',
      body: {...changes, 'note': note},
    );
    return DocumentRecord.fromJson(json['document']! as Map<String, Object?>);
  }

  Future<DocumentRecord> revokeDocument(String id, {String reason = ''}) async {
    final json = await _send(
      'POST',
      '/api/documents/$id/revoke',
      body: {'reason': reason},
    );
    return DocumentRecord.fromJson(json['document']! as Map<String, Object?>);
  }
}
