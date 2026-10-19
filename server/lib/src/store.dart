import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'ids.dart';

/// Metadata storage in SQLite. File bytes live on Walrus, never here.
class Store {
  Store(this._db) {
    _migrate();
  }

  /// Opens (or creates) the database at [path].
  factory Store.open(String path) => Store(sqlite3.open(path));

  /// An in-memory database, for tests.
  factory Store.inMemory() => Store(sqlite3.openInMemory());

  final Database _db;

  /// The SQLite database, shared with the sign-in store (`sui_auth_*`
  /// tables).
  Database get db => _db;

  void close() => _db.dispose();

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON;');
    _db.execute('PRAGMA journal_mode = WAL;');
    final columns = _db
        .select('PRAGMA table_info(vaults)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.isNotEmpty && !columns.contains('owner_address')) {
      throw StateError(
        'This database was made by an earlier Credence that used secret admin '
        'links. Vaults now belong to Sui addresses and the old vaults cannot '
        'be given an owner automatically. Start with an empty DATA_DIR.',
      );
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS vaults (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('personal', 'organization')),
        about TEXT NOT NULL DEFAULT '',
        website TEXT NOT NULL DEFAULT '',
        owner_address TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS uploads (
        owner_address TEXT NOT NULL,
        blob_id TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        content_type TEXT NOT NULL,
        object_id TEXT,
        end_epoch INTEGER,
        registered_epoch INTEGER,
        uploaded_at TEXT NOT NULL,
        PRIMARY KEY (owner_address, blob_id)
      );
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        vault_id TEXT NOT NULL REFERENCES vaults(id),
        title TEXT NOT NULL,
        issuer_name TEXT NOT NULL,
        recipient_name TEXT NOT NULL,
        issue_date TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        file_name TEXT NOT NULL,
        content_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        blob_id TEXT NOT NULL,
        blob_object_id TEXT,
        end_epoch INTEGER,
        registered_epoch INTEGER,
        network TEXT NOT NULL,
        uploaded_at TEXT NOT NULL,
        revoked_at TEXT,
        revoke_reason TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS documents_vault ON documents (vault_id);
      CREATE INDEX IF NOT EXISTS vaults_by_owner
        ON vaults (owner_address, created_at);
      CREATE TABLE IF NOT EXISTS document_edits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        document_id TEXT NOT NULL REFERENCES documents(id),
        edited_at TEXT NOT NULL,
        note TEXT NOT NULL,
        changes TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS edits_document ON document_edits (document_id);
      CREATE UNIQUE INDEX IF NOT EXISTS uploads_by_object ON uploads (object_id);
    ''');
    // Since wallet-paid storage: who paid for and owns the Blob object.
    final documentColumns = _db
        .select('PRAGMA table_info(documents)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!documentColumns.contains('stored_by')) {
      _db.execute('ALTER TABLE documents ADD COLUMN stored_by TEXT');
    }
    if (!documentColumns.contains('request_id')) {
      _db.execute('ALTER TABLE documents ADD COLUMN request_id TEXT');
    }
    if (!documentColumns.contains('request_payload')) {
      _db.execute('ALTER TABLE documents ADD COLUMN request_payload TEXT');
    }
    if (!documentColumns.contains('estimated_expires_at')) {
      _db.execute('ALTER TABLE documents ADD COLUMN estimated_expires_at TEXT');
    }
    final uploadColumns = _db
        .select('PRAGMA table_info(uploads)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!uploadColumns.contains('estimated_expires_at')) {
      _db.execute('ALTER TABLE uploads ADD COLUMN estimated_expires_at TEXT');
    }
    _db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS documents_request '
      'ON documents (vault_id, request_id)',
    );
  }

  static String _now(DateTime? at) =>
      (at ?? DateTime.now()).toUtc().toIso8601String();

  // Vaults ------------------------------------------------------------------

  /// Creates a vault owned by [ownerAddress] (a verified Sui address).
  Map<String, Object?> createVault({
    required String name,
    required String kind,
    required String ownerAddress,
    String about = '',
    String website = '',
    DateTime? now,
  }) {
    final id = newId(10);
    final at = _now(now);
    _db.execute(
      'INSERT INTO vaults (id, name, kind, about, website, owner_address, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, name, kind, about, website, ownerAddress, at, at],
    );
    return findVault(id)!;
  }

  static const _vaultSelect =
      'SELECT v.*, '
      '(SELECT COUNT(*) FROM documents d WHERE d.vault_id = v.id '
      'AND d.revoked_at IS NULL) AS active_count, '
      '(SELECT COUNT(*) FROM documents d WHERE d.vault_id = v.id '
      'AND d.revoked_at IS NOT NULL) AS revoked_count '
      'FROM vaults v ';

  /// Vaults owned by [address], newest first: what `/app` lists.
  List<Map<String, Object?>> vaultsOwnedBy(String address) => [
    for (final row in _db.select(
      '$_vaultSelect WHERE v.owner_address = ? ORDER BY v.created_at DESC',
      [address],
    ))
      _vaultJson(row),
  ];

  Map<String, Object?>? findVault(String id) {
    final rows = _db.select('$_vaultSelect WHERE v.id = ?', [id]);
    return rows.isEmpty ? null : _vaultJson(rows.first);
  }

  /// The owner's Sui address, or null when the vault does not exist.
  String? ownerOf(String vaultId) {
    final rows = _db.select('SELECT owner_address FROM vaults WHERE id = ?', [
      vaultId,
    ]);
    return rows.isEmpty ? null : rows.first['owner_address'] as String;
  }

  Map<String, Object?> updateVault(
    String id, {
    String? name,
    String? about,
    String? website,
    DateTime? now,
  }) {
    final current = findVault(id)!;
    _db.execute(
      'UPDATE vaults SET name = ?, about = ?, website = ?, updated_at = ? '
      'WHERE id = ?',
      [
        name ?? current['name'],
        about ?? current['about'],
        website ?? current['website'],
        _now(now),
        id,
      ],
    );
    return findVault(id)!;
  }

  Map<String, Object?> _vaultJson(Row row) => {
    'id': row['id'],
    'name': row['name'],
    'kind': row['kind'],
    'about': row['about'],
    'website': row['website'],
    'ownerAddress': row['owner_address'],
    'createdAt': row['created_at'],
    'updatedAt': row['updated_at'],
    'documentCount': row['active_count'],
    'revokedCount': row['revoked_count'],
  };

  // Uploads -----------------------------------------------------------------

  /// Records a blob [ownerAddress] stored and paid for with their own
  /// wallet, after the claim checks. Facts come from Sui and the bytes on
  /// Walrus. Storing the same file again replaces the record with the new
  /// Blob object. Returns the record.
  Map<String, Object?> recordUpload({
    required String ownerAddress,
    required String blobId,
    required String sha256,
    required int sizeBytes,
    required String contentType,
    required String objectId,
    required int endEpoch,
    required int registeredEpoch,
    DateTime? estimatedExpiresAt,
    DateTime? now,
  }) {
    _db.execute(
      'INSERT INTO uploads (owner_address, blob_id, sha256, size_bytes, '
      'content_type, object_id, end_epoch, registered_epoch, uploaded_at, estimated_expires_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT (owner_address, blob_id) DO UPDATE SET '
      'sha256 = excluded.sha256, size_bytes = excluded.size_bytes, '
      'content_type = excluded.content_type, object_id = excluded.object_id, '
      'end_epoch = excluded.end_epoch, '
      'registered_epoch = excluded.registered_epoch, '
      'uploaded_at = excluded.uploaded_at, '
      'estimated_expires_at = excluded.estimated_expires_at',
      [
        ownerAddress,
        blobId,
        sha256,
        sizeBytes,
        contentType,
        objectId,
        endEpoch,
        registeredEpoch,
        _now(now),
        estimatedExpiresAt?.toUtc().toIso8601String(),
      ],
    );
    return findUpload(ownerAddress, blobId)!;
  }

  /// Whether a Blob object is already listed (as the latest upload of a
  /// file, or on a document).
  bool objectClaimed(String objectId) => _db.select(
    'SELECT 1 FROM uploads WHERE object_id = ? '
    'UNION SELECT 1 FROM documents WHERE blob_object_id = ? LIMIT 1',
    [objectId, objectId],
  ).isNotEmpty;

  Map<String, Object?>? findUpload(String ownerAddress, String blobId) {
    final rows = _db.select(
      'SELECT * FROM uploads WHERE owner_address = ? AND blob_id = ?',
      [ownerAddress, blobId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'ownerAddress': r['owner_address'],
      'blobId': r['blob_id'],
      'sha256': r['sha256'],
      'sizeBytes': r['size_bytes'],
      'contentType': r['content_type'],
      'objectId': r['object_id'],
      'endEpoch': (r['end_epoch'] as int?) == 0 ? null : r['end_epoch'],
      'registeredEpoch': r['registered_epoch'],
      'uploadedAt': r['uploaded_at'],
      'estimatedExpiresAt': r['estimated_expires_at'],
    };
  }

  int uploadsSince(String ownerAddress, DateTime since) {
    final rows = _db.select(
      'SELECT COUNT(*) AS n FROM uploads '
      'WHERE owner_address = ? AND uploaded_at >= ?',
      [ownerAddress, since.toUtc().toIso8601String()],
    );
    return rows.first['n'] as int;
  }

  // Documents ---------------------------------------------------------------

  Map<String, Object?> createDocument({
    required String vaultId,
    required String title,
    required String issuerName,
    required String recipientName,
    required String issueDate,
    required String notes,
    required String fileName,
    required Map<String, Object?> upload,
    required String network,
    String? requestId,
    String? requestPayload,
    DateTime? now,
  }) {
    final id = newId(12);
    final at = _now(now);
    _db.execute(
      'INSERT INTO documents (id, vault_id, title, issuer_name, '
      'recipient_name, issue_date, notes, file_name, content_type, '
      'size_bytes, sha256, blob_id, blob_object_id, end_epoch, '
      'registered_epoch, network, uploaded_at, updated_at, stored_by, '
      'request_id, request_payload, estimated_expires_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        vaultId,
        title,
        issuerName,
        recipientName,
        issueDate,
        notes,
        fileName,
        upload['contentType'],
        upload['sizeBytes'],
        upload['sha256'],
        upload['blobId'],
        upload['objectId'],
        upload['endEpoch'],
        upload['registeredEpoch'],
        network,
        upload['uploadedAt'] ?? at,
        at,
        upload['ownerAddress'],
        requestId,
        requestPayload,
        upload['estimatedExpiresAt'],
      ],
    );
    return findDocument(id)!;
  }

  ({Map<String, Object?> document, String payload})? documentForRequest(
    String vaultId,
    String requestId,
  ) {
    final rows = _db.select(
      'SELECT id, request_payload FROM documents '
      'WHERE vault_id = ? AND request_id = ?',
      [vaultId, requestId],
    );
    if (rows.isEmpty) return null;
    return (
      document: findDocument(rows.first['id'] as String)!,
      payload: rows.first['request_payload'] as String,
    );
  }

  Map<String, Object?>? findDocument(String id) {
    final rows = _db.select('SELECT * FROM documents WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return _documentJson(rows.first, edits: _edits(id));
  }

  String? documentVaultId(String id) {
    final rows = _db.select('SELECT vault_id FROM documents WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : rows.first['vault_id'] as String;
  }

  /// Documents in a vault, newest first. Revoked ones only when asked.
  List<Map<String, Object?>> listDocuments(
    String vaultId, {
    required bool includeRevoked,
  }) {
    final rows = _db.select(
      'SELECT * FROM documents WHERE vault_id = ? '
      '${includeRevoked ? '' : 'AND revoked_at IS NULL '}'
      'ORDER BY issue_date DESC, uploaded_at DESC',
      [vaultId],
    );
    return [for (final r in rows) _documentJson(r)];
  }

  /// Applies [changes] (field -> new value) and records an edit note.
  Map<String, Object?> editDocument(
    String id, {
    required Map<String, String> changes,
    required String note,
    DateTime? now,
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final current = findDocument(id)!;
      final diffs = <Map<String, String>>[];
      for (final entry in changes.entries) {
        final column = _editableColumns[entry.key]!;
        final before = current[entry.key] as String;
        if (before == entry.value) continue;
        diffs.add({'field': entry.key, 'from': before, 'to': entry.value});
        _db.execute('UPDATE documents SET $column = ? WHERE id = ?', [
          entry.value,
          id,
        ]);
      }
      if (diffs.isEmpty) {
        _db.execute('COMMIT');
        return current;
      }
      final at = _now(now);
      _db.execute('UPDATE documents SET updated_at = ? WHERE id = ?', [at, id]);
      _db.execute(
        'INSERT INTO document_edits (document_id, edited_at, note, changes) '
        'VALUES (?, ?, ?, ?)',
        [id, at, note, jsonEncode(diffs)],
      );
      final result = findDocument(id)!;
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, Object?> revokeDocument(
    String id, {
    required String reason,
    DateTime? now,
  }) {
    final at = _now(now);
    _db.execute(
      'UPDATE documents SET revoked_at = ?, revoke_reason = ?, updated_at = ? '
      'WHERE id = ? AND revoked_at IS NULL',
      [at, reason, at, id],
    );
    return findDocument(id)!;
  }

  static const _editableColumns = {
    'title': 'title',
    'issuerName': 'issuer_name',
    'recipientName': 'recipient_name',
    'issueDate': 'issue_date',
    'notes': 'notes',
  };

  static Set<String> get editableFields => _editableColumns.keys.toSet();

  List<Map<String, Object?>> _edits(String documentId) {
    final rows = _db.select(
      'SELECT * FROM document_edits WHERE document_id = ? ORDER BY id DESC',
      [documentId],
    );
    return [
      for (final r in rows)
        {
          'editedAt': r['edited_at'],
          'note': r['note'],
          'changes': jsonDecode(r['changes'] as String),
        },
    ];
  }

  Map<String, Object?> _documentJson(
    Row r, {
    List<Map<String, Object?>>? edits,
  }) => {
    'id': r['id'],
    'vaultId': r['vault_id'],
    'title': r['title'],
    'issuerName': r['issuer_name'],
    'recipientName': r['recipient_name'],
    'issueDate': r['issue_date'],
    'notes': r['notes'],
    'fileName': r['file_name'],
    'contentType': r['content_type'],
    'sizeBytes': r['size_bytes'],
    'sha256': r['sha256'],
    'blobId': r['blob_id'],
    'blobObjectId': r['blob_object_id'],
    'storedBy': r['stored_by'],
    'endEpoch': r['end_epoch'],
    'registeredEpoch': r['registered_epoch'],
    'network': r['network'],
    'uploadedAt': r['uploaded_at'],
    'estimatedExpiresAt': r['estimated_expires_at'],
    'revokedAt': r['revoked_at'],
    'revokeReason': r['revoke_reason'],
    'updatedAt': r['updated_at'],
    if (edits != null) 'editCount': edits.length,
    'edits': ?edits,
  };
}
