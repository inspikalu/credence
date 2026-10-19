import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sui_auth/sui_auth.dart';

import 'config.dart';
import 'json.dart';
import 'origin.dart';
import 'rate_limit.dart';
import 'sniff.dart';
import 'store.dart';
import 'uploads.dart';
import 'validation.dart';

/// The JSON metadata API, mounted at `/api/`.
class Api {
  Api({
    required this.config,
    required this.store,
    required this.uploads,
    RateLimiter? vaultLimiter,
    DateTime Function()? clock,
  }) : _vaultLimiter =
           vaultLimiter ??
           RateLimiter(limit: 20, window: const Duration(hours: 1)),
       _clock = clock ?? DateTime.now;

  final ServerConfig config;
  final Store store;
  final UploadClaims uploads;
  final RateLimiter _vaultLimiter;
  final DateTime Function() _clock;

  Handler get handler {
    final router = Router(notFoundHandler: _notFound)
      ..get('/health', (Request r) => jsonResponse({'ok': true}))
      ..get('/config', _config)
      ..get('/my/vaults', _guard(_myVaults))
      ..post('/vaults', _guard(_createVault))
      ..post('/uploads', _guard(uploads.claim))
      ..get('/vaults/<id>', _guard1(_getVault))
      ..get('/vaults/<id>/manage', _guard1(_getVaultForOwner))
      ..patch('/vaults/<id>', _guard1(_updateVault))
      ..post('/vaults/<id>/documents', _guard1(_createDocument))
      ..get('/documents/<id>', _guard1(_getDocument))
      ..patch('/documents/<id>', _guard1(_editDocument))
      ..post('/documents/<id>/revoke', _guard1(_revokeDocument));
    return router.call;
  }

  static Response _notFound(Request request) => errorResponse(
    const ApiException(404, 'NOT_FOUND', 'No such API endpoint.'),
  );

  Handler _guard(Future<Response> Function(Request) inner) =>
      (Request request) async {
        try {
          return await inner(request);
        } on ApiException catch (e) {
          return errorResponse(e);
        }
      };

  Future<Response> Function(Request, String) _guard1(
    Future<Response> Function(Request, String) inner,
  ) => (Request request, String id) async {
    try {
      return await inner(request, id);
    } on ApiException catch (e) {
      return errorResponse(e);
    }
  };

  Response _config(Request request) => jsonResponse({
    'aggregatorUrl': config.aggregatorUrl.toString(),
    'network': config.network.name,
    // The suggested storage period; people pay for what they choose.
    'epochs': config.epochs,
    'maxEpochs': ServerConfig.maxEpochs,
    'epochDurationHours': config.epochDurationHours,
    'maxUploadBytes': config.maxUploadBytes,
    'allowedTypes': allowedContentTypes,
    'publicBaseUrl': config.publicBaseUrl,
    'suiChain': config.suiChain.id,
  });

  // Vaults ------------------------------------------------------------------

  /// The signed-in owner's vaults, on any device.
  Future<Response> _myVaults(Request request) async {
    final owner = _requireSignedIn(request, 'Sign in to see your vaults.');
    return jsonResponse({'vaults': store.vaultsOwnedBy(owner)});
  }

  Future<Response> _createVault(Request request) async {
    final owner = _requireSignedIn(
      request,
      'Sign in with your Sui wallet to create a vault.',
    );
    final body = await readJsonObject(request);
    final name = requireLine(
      body,
      'name',
      label: 'Vault name',
      min: 2,
      max: 80,
    );
    final kind = requireKind(body);
    final about = optionalText(body, 'about', label: 'About', max: 280);
    final website = optionalWebsite(body);
    if (!_vaultLimiter.allow(owner) ||
        !_vaultLimiter.allow('ip:${_clientKey(request)}')) {
      throw const ApiException(
        429,
        'RATE_LIMITED',
        'Too many vaults created from this connection. Try again in an hour.',
      );
    }
    final vault = store.createVault(
      name: name,
      kind: kind,
      // The owner is always the verified session address, never a value
      // from the request body.
      ownerAddress: owner,
      about: about,
      website: website,
      now: _clock(),
    );
    return jsonResponse({'vault': vault}, status: 201);
  }

  Future<Response> _getVault(Request request, String id) async {
    final vault = _vaultOr404(id);
    return jsonResponse({
      'vault': vault,
      'documents': store.listDocuments(id, includeRevoked: false),
    });
  }

  Future<Response> _getVaultForOwner(Request request, String id) async {
    final vault = _vaultOr404(id);
    _requireOwner(request, id);
    return jsonResponse({
      'vault': vault,
      'documents': store.listDocuments(id, includeRevoked: true),
    });
  }

  Future<Response> _updateVault(Request request, String id) async {
    _vaultOr404(id);
    _requireOwner(request, id);
    final body = await readJsonObject(request);
    final vault = store.updateVault(
      id,
      name: body.containsKey('name')
          ? requireLine(body, 'name', label: 'Vault name', min: 2, max: 80)
          : null,
      about: body.containsKey('about')
          ? optionalText(body, 'about', label: 'About', max: 280)
          : null,
      website: body.containsKey('website') ? optionalWebsite(body) : null,
      now: _clock(),
    );
    return jsonResponse({'vault': vault});
  }

  // Documents ---------------------------------------------------------------

  Future<Response> _createDocument(Request request, String vaultId) async {
    _vaultOr404(vaultId);
    _requireOwner(request, vaultId);
    final body = await readJsonObject(request);
    final title = requireLine(body, 'title', label: 'Title');
    final issuer = requireLine(body, 'issuerName', label: 'Issuer name');
    final recipient = requireLine(
      body,
      'recipientName',
      label: 'Recipient name',
    );
    final issueDate = requireIssueDate(body, now: _clock());
    final notes = optionalText(
      body,
      'notes',
      label: 'Notes',
      max: 1000,
      multiline: true,
    );
    final sha = requireSha256(body);
    final blobId = requireBlobId(body);
    final fileName = cleanFileName(body['fileName']);
    final requestId = body['requestId'];
    if (requestId != null &&
        (requestId is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId))) {
      throw badField('requestId', 'The save request ID is invalid.');
    }
    final payload = jsonEncode([
      title,
      issuer,
      recipient,
      issueDate,
      notes,
      fileName,
      sha,
      blobId,
    ]);
    if (requestId is String) {
      final previous = store.documentForRequest(vaultId, requestId);
      if (previous != null) {
        if (previous.payload != payload) {
          throw const ApiException(
            409,
            'DOCUMENT_ALREADY_SAVED',
            'This document was already saved. Reload the vault to edit it.',
          );
        }
        return jsonResponse({'document': previous.document}, status: 201);
      }
    }
    final upload = store.findUpload(store.ownerOf(vaultId)!, blobId);
    if (upload == null) {
      throw const ApiException(
        409,
        'UNKNOWN_BLOB',
        'That file was not stored by this vault\'s owner. Store it again.',
        field: 'blobId',
      );
    }
    if (upload['sha256'] != sha) {
      throw const ApiException(
        409,
        'FINGERPRINT_MISMATCH',
        'The SHA-256 fingerprint does not match the uploaded file. '
            'Upload the file again.',
        field: 'sha256',
      );
    }
    final document = store.createDocument(
      vaultId: vaultId,
      title: title,
      issuerName: issuer,
      recipientName: recipient,
      issueDate: issueDate,
      notes: notes,
      fileName: fileName,
      upload: upload,
      network: config.network.name,
      now: _clock(),
      requestId: requestId as String?,
      requestPayload: requestId == null ? null : payload,
    );
    return jsonResponse({'document': document}, status: 201);
  }

  Future<Response> _getDocument(Request request, String id) async {
    final document = _documentOr404(id);
    final vault = store.findVault(document['vaultId'] as String)!;
    return jsonResponse({'document': document, 'vault': vault});
  }

  Future<Response> _editDocument(Request request, String id) async {
    final document = _documentOr404(id);
    _requireOwner(request, document['vaultId'] as String);
    final body = await readJsonObject(request);
    final note = requireLine(
      body,
      'note',
      label: 'A note about this change',
      min: 3,
      max: 280,
    );
    final changes = <String, String>{};
    if (body.containsKey('title')) {
      changes['title'] = requireLine(body, 'title', label: 'Title');
    }
    if (body.containsKey('issuerName')) {
      changes['issuerName'] = requireLine(
        body,
        'issuerName',
        label: 'Issuer name',
      );
    }
    if (body.containsKey('recipientName')) {
      changes['recipientName'] = requireLine(
        body,
        'recipientName',
        label: 'Recipient name',
      );
    }
    if (body.containsKey('issueDate')) {
      changes['issueDate'] = requireIssueDate(body, now: _clock());
    }
    if (body.containsKey('notes')) {
      changes['notes'] = optionalText(
        body,
        'notes',
        label: 'Notes',
        max: 1000,
        multiline: true,
      );
    }
    final unchanged = changes.entries.every((e) => document[e.key] == e.value);
    if (changes.isEmpty || unchanged) {
      throw const ApiException(
        400,
        'NO_CHANGES',
        'Nothing changed. Edit a detail before saving.',
      );
    }
    final updated = store.editDocument(
      id,
      changes: changes,
      note: note,
      now: _clock(),
    );
    return jsonResponse({'document': updated});
  }

  Future<Response> _revokeDocument(Request request, String id) async {
    final document = _documentOr404(id);
    _requireOwner(request, document['vaultId'] as String);
    if (document['revokedAt'] != null) {
      throw const ApiException(
        409,
        'ALREADY_REVOKED',
        'This document is already revoked.',
      );
    }
    final body = await readJsonObject(request);
    final reason = optionalText(body, 'reason', label: 'Reason', max: 280);
    final updated = store.revokeDocument(id, reason: reason, now: _clock());
    return jsonResponse({'document': updated});
  }

  // Helpers -----------------------------------------------------------------

  Map<String, Object?> _vaultOr404(String id) {
    final vault = id.length <= 40 ? store.findVault(id) : null;
    if (vault == null) {
      throw const ApiException(404, 'NOT_FOUND', 'No vault has this link.');
    }
    return vault;
  }

  Map<String, Object?> _documentOr404(String id) {
    final document = id.length <= 40 ? store.findDocument(id) : null;
    if (document == null) {
      throw const ApiException(404, 'NOT_FOUND', 'No document has this link.');
    }
    return document;
  }

  /// The signed-in address, or a 401 with [message].
  String _requireSignedIn(Request request, String message) {
    final address = request.suiAddress;
    if (address == null) {
      throw ApiException(401, 'UNAUTHENTICATED', message);
    }
    return address;
  }

  /// 401 when signed out, 403 when the vault belongs to someone else.
  void _requireOwner(Request request, String vaultId) {
    final address = _requireSignedIn(
      request,
      'Sign in with your Sui wallet to manage this vault.',
    );
    if (store.ownerOf(vaultId) != address) {
      throw const ApiException(
        403,
        'FORBIDDEN',
        'This vault belongs to another account.',
      );
    }
  }

  String _clientKey(Request request) {
    final info = request.context['shelf.io.connection_info'];
    final direct = info is HttpConnectionInfo
        ? info.remoteAddress.address
        : 'local';
    return clientAddress(request, config, direct);
  }
}
