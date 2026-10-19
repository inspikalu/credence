/// Data shapes returned by the Credence API.
library;

T _req<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Field "$key" is missing or has the wrong type');
}

T? _opt<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is T ? value : null;
}

DateTime _date(Map<String, Object?> json, String key) =>
    DateTime.parse(_req<String>(json, key)).toUtc();

DateTime? _optDate(Map<String, Object?> json, String key) {
  final raw = _opt<String>(json, key);
  return raw == null ? null : DateTime.parse(raw).toUtc();
}

/// Server settings the client needs.
class AppConfig {
  const AppConfig({
    required this.aggregatorUrl,
    required this.network,
    required this.epochs,
    required this.epochDurationHours,
    required this.maxUploadBytes,
    required this.allowedTypes,
    this.publicBaseUrl,
    this.suiChain = 'sui:testnet',
    this.maxEpochs = 53,
  });

  factory AppConfig.fromJson(Map<String, Object?> json) => AppConfig(
    aggregatorUrl: Uri.parse(_req<String>(json, 'aggregatorUrl')),
    network: _req<String>(json, 'network'),
    epochs: _req<int>(json, 'epochs'),
    epochDurationHours: _req<int>(json, 'epochDurationHours'),
    maxUploadBytes: _req<int>(json, 'maxUploadBytes'),
    allowedTypes: [
      for (final t in _req<List<Object?>>(json, 'allowedTypes'))
        if (t is String) t,
    ],
    publicBaseUrl: _opt<String>(json, 'publicBaseUrl'),
    suiChain: _opt<String>(json, 'suiChain') ?? 'sui:testnet',
    maxEpochs: _opt<int>(json, 'maxEpochs') ?? 53,
  );

  final Uri aggregatorUrl;
  final String network;

  /// The storage period the app suggests, in Walrus epochs. Owners pay for
  /// their own storage and may choose another.
  final int epochs;

  /// Walrus stores at most this many epochs ahead.
  final int maxEpochs;
  final int epochDurationHours;
  final int maxUploadBytes;
  final List<String> allowedTypes;
  final String? publicBaseUrl;

  /// Wallet Standard chain for sign-in, e.g. `sui:testnet`.
  final String suiChain;

  String get networkLabel => switch (network) {
    'mainnet' => 'Walrus Mainnet',
    'testnet' => 'Walrus Testnet',
    _ => 'Walrus',
  };
}

enum VaultKind {
  personal,
  organization;

  static VaultKind parse(String raw) =>
      raw == 'organization' ? VaultKind.organization : VaultKind.personal;

  String get label => this == organization ? 'Organization' : 'Personal';
}

class Vault {
  const Vault({
    required this.id,
    required this.name,
    required this.kind,
    required this.about,
    required this.website,
    required this.createdAt,
    required this.documentCount,
    required this.revokedCount,
    this.ownerAddress,
  });

  factory Vault.fromJson(Map<String, Object?> json) => Vault(
    id: _req<String>(json, 'id'),
    ownerAddress: _opt<String>(json, 'ownerAddress'),
    name: _req<String>(json, 'name'),
    kind: VaultKind.parse(_req<String>(json, 'kind')),
    about: _opt<String>(json, 'about') ?? '',
    website: _opt<String>(json, 'website') ?? '',
    createdAt: _date(json, 'createdAt'),
    documentCount: _opt<int>(json, 'documentCount') ?? 0,
    revokedCount: _opt<int>(json, 'revokedCount') ?? 0,
  );

  final String id;
  final String name;
  final VaultKind kind;
  final String about;
  final String website;
  final DateTime createdAt;
  final int documentCount;
  final int revokedCount;

  /// The Sui address that owns the vault and its Walrus blob objects.
  final String? ownerAddress;

  Vault copyWith({
    String? name,
    String? about,
    String? website,
    int? documentCount,
    int? revokedCount,
  }) => Vault(
    id: id,
    name: name ?? this.name,
    kind: kind,
    about: about ?? this.about,
    website: website ?? this.website,
    createdAt: createdAt,
    documentCount: documentCount ?? this.documentCount,
    revokedCount: revokedCount ?? this.revokedCount,
    ownerAddress: ownerAddress,
  );
}

class FieldChange {
  const FieldChange(this.field, this.from, this.to);

  final String field;
  final String from;
  final String to;

  String get label => switch (field) {
    'title' => 'Title',
    'issuerName' => 'Issuer',
    'recipientName' => 'Recipient',
    'issueDate' => 'Issue date',
    'notes' => 'Notes',
    _ => field,
  };
}

class DocumentEdit {
  const DocumentEdit({
    required this.editedAt,
    required this.note,
    required this.changes,
  });

  factory DocumentEdit.fromJson(Map<String, Object?> json) => DocumentEdit(
    editedAt: _date(json, 'editedAt'),
    note: _req<String>(json, 'note'),
    changes: [
      for (final c in _req<List<Object?>>(json, 'changes'))
        if (c is Map<String, Object?>)
          FieldChange(
            _req<String>(c, 'field'),
            _opt<String>(c, 'from') ?? '',
            _opt<String>(c, 'to') ?? '',
          ),
    ],
  );

  final DateTime editedAt;
  final String note;
  final List<FieldChange> changes;
}

class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.vaultId,
    required this.title,
    required this.issuerName,
    required this.recipientName,
    required this.issueDate,
    required this.notes,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.sha256,
    required this.blobId,
    required this.network,
    required this.uploadedAt,
    this.blobObjectId,
    this.storedBy,
    this.endEpoch,
    this.registeredEpoch,
    this.estimatedExpiresAt,
    this.revokedAt,
    this.revokeReason = '',
    this.edits = const [],
    this.editCount,
  });

  factory DocumentRecord.fromJson(Map<String, Object?> json) {
    final edits = _opt<List<Object?>>(json, 'edits');
    return DocumentRecord(
      id: _req<String>(json, 'id'),
      vaultId: _req<String>(json, 'vaultId'),
      title: _req<String>(json, 'title'),
      issuerName: _req<String>(json, 'issuerName'),
      recipientName: _req<String>(json, 'recipientName'),
      issueDate: _req<String>(json, 'issueDate'),
      notes: _opt<String>(json, 'notes') ?? '',
      fileName: _req<String>(json, 'fileName'),
      contentType: _req<String>(json, 'contentType'),
      sizeBytes: _req<int>(json, 'sizeBytes'),
      sha256: _req<String>(json, 'sha256'),
      blobId: _req<String>(json, 'blobId'),
      blobObjectId: _opt<String>(json, 'blobObjectId'),
      storedBy: _opt<String>(json, 'storedBy'),
      endEpoch: _opt<int>(json, 'endEpoch'),
      registeredEpoch: _opt<int>(json, 'registeredEpoch'),
      estimatedExpiresAt: _optDate(json, 'estimatedExpiresAt'),
      network: _opt<String>(json, 'network') ?? 'testnet',
      uploadedAt: _date(json, 'uploadedAt'),
      revokedAt: _optDate(json, 'revokedAt'),
      revokeReason: _opt<String>(json, 'revokeReason') ?? '',
      edits: [
        for (final e in edits ?? const <Object?>[])
          if (e is Map<String, Object?>) DocumentEdit.fromJson(e),
      ],
      editCount: _opt<int>(json, 'editCount'),
    );
  }

  final String id;
  final String vaultId;
  final String title;
  final String issuerName;
  final String recipientName;

  /// `YYYY-MM-DD`.
  final String issueDate;
  final String notes;
  final String fileName;
  final String contentType;
  final int sizeBytes;
  final String sha256;
  final String blobId;
  final String? blobObjectId;

  /// The Sui address that paid for the file and owns its Blob object.
  /// Older records (stored through a publisher) have none.
  final String? storedBy;
  final int? endEpoch;
  final int? registeredEpoch;

  /// Estimated from the live Walrus epoch timing, never the upload date.
  final DateTime? estimatedExpiresAt;
  final String network;
  final DateTime uploadedAt;
  final DateTime? revokedAt;
  final String revokeReason;
  final List<DocumentEdit> edits;
  final int? editCount;

  bool get isRevoked => revokedAt != null;

  /// Uploaded within the last two hours. Walrus aggregators can take a
  /// little while to serve a newly certified blob, so a missing file on a
  /// recent record means "not readable yet", not "storage ended".
  bool get isRecent =>
      DateTime.now().toUtc().difference(uploadedAt) < const Duration(hours: 2);

  /// How long to keep retrying a missing blob before giving up.
  Duration get readPatience =>
      isRecent ? const Duration(seconds: 45) : Duration.zero;
  bool get isPdf => contentType == 'application/pdf';
  bool get isImage => contentType.startsWith('image/');

  String get typeLabel => switch (contentType) {
    'application/pdf' => 'PDF',
    'image/png' => 'PNG',
    'image/jpeg' => 'JPEG',
    'image/webp' => 'WebP',
    _ => 'File',
  };
}

/// A public vault page: the vault and its listed documents.
class VaultPage {
  const VaultPage(this.vault, this.documents);

  factory VaultPage.fromJson(Map<String, Object?> json) =>
      VaultPage(Vault.fromJson(_req<Map<String, Object?>>(json, 'vault')), [
        for (final d in _req<List<Object?>>(json, 'documents'))
          if (d is Map<String, Object?>) DocumentRecord.fromJson(d),
      ]);

  final Vault vault;
  final List<DocumentRecord> documents;
}

/// A document check page: the record and the vault that holds it.
class DocumentPage {
  const DocumentPage(this.document, this.vault);

  factory DocumentPage.fromJson(Map<String, Object?> json) => DocumentPage(
    DocumentRecord.fromJson(_req<Map<String, Object?>>(json, 'document')),
    Vault.fromJson(_req<Map<String, Object?>>(json, 'vault')),
  );

  final DocumentRecord document;
  final Vault vault;
}
