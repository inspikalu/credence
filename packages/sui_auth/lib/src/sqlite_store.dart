import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' as native;

import 'store.dart';

/// Nonces and sessions in SQLite (works with `package:sqlite3` 2.x and 3.x).
///
/// Pass the app's own database to keep everything in one file. Tables are
/// prefixed `sui_auth_` and created if missing; `PRAGMA user_version` is left
/// alone for the app's own migrations.
class SqliteSuiAuthStore implements NonceStore, SessionStore {
  SqliteSuiAuthStore(this.db) : _owned = false {
    _migrate();
  }

  SqliteSuiAuthStore._owned(this.db) : _owned = true {
    _migrate();
  }

  /// Opens (creating if needed) a database file just for sign-in data.
  factory SqliteSuiAuthStore.open(String path) {
    final db = native.sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    return SqliteSuiAuthStore._owned(db);
  }

  factory SqliteSuiAuthStore.inMemory() =>
      SqliteSuiAuthStore._owned(native.sqlite3.openInMemory());

  final CommonDatabase db;
  final bool _owned;

  void _migrate() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS sui_auth_nonces (
        nonce TEXT PRIMARY KEY,
        address TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS sui_auth_nonces_by_expiry
        ON sui_auth_nonces(expires_at);
      CREATE TABLE IF NOT EXISTS sui_auth_sessions (
        token_hash TEXT PRIMARY KEY,
        address TEXT NOT NULL,
        chain TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS sui_auth_sessions_by_address
        ON sui_auth_sessions(address);
      CREATE INDEX IF NOT EXISTS sui_auth_sessions_by_expiry
        ON sui_auth_sessions(expires_at);
    ''');
  }

  /// Closes the database if this store opened it.
  void close() {
    if (!_owned) return;
    final dynamic d = db;
    try {
      d.close(); // sqlite3 3.x
    } on NoSuchMethodError {
      d.dispose(); // sqlite3 2.x
    }
  }

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;
  static DateTime _time(Object? ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);

  @override
  Future<void> saveNonce(NonceRecord record) async {
    db.execute(
      'INSERT INTO sui_auth_nonces (nonce, address, created_at, expires_at) '
      'VALUES (?, ?, ?, ?)',
      [
        record.nonce,
        record.address,
        _ms(record.createdAt),
        _ms(record.expiresAt),
      ],
    );
  }

  @override
  Future<NonceRecord?> takeNonce(String nonce) async {
    final rows = db.select(
      'SELECT address, created_at, expires_at FROM sui_auth_nonces '
      'WHERE nonce = ?',
      [nonce],
    );
    if (rows.isEmpty) return null;
    db.execute('DELETE FROM sui_auth_nonces WHERE nonce = ?', [nonce]);
    // Another process may have taken it between the two statements; only
    // the one whose DELETE removed the row may use it.
    if (db.updatedRows != 1) return null;
    final row = rows.first;
    return NonceRecord(
      nonce: nonce,
      address: row['address'] as String?,
      createdAt: _time(row['created_at']),
      expiresAt: _time(row['expires_at']),
    );
  }

  @override
  Future<int> countNonces() async =>
      db.select('SELECT COUNT(*) AS n FROM sui_auth_nonces').first['n'] as int;

  @override
  Future<int> deleteExpiredNonces(DateTime now) async {
    db.execute('DELETE FROM sui_auth_nonces WHERE expires_at <= ?', [_ms(now)]);
    return db.updatedRows;
  }

  @override
  Future<void> saveSession(SuiSession session) async {
    db.execute(
      'INSERT OR REPLACE INTO sui_auth_sessions '
      '(token_hash, address, chain, created_at, expires_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        session.tokenHash,
        session.address,
        session.chainId,
        _ms(session.createdAt),
        _ms(session.expiresAt),
      ],
    );
  }

  @override
  Future<SuiSession?> findSession(String tokenHash) async {
    final rows = db.select(
      'SELECT address, chain, created_at, expires_at FROM sui_auth_sessions '
      'WHERE token_hash = ?',
      [tokenHash],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SuiSession(
      tokenHash: tokenHash,
      address: row['address'] as String,
      chainId: row['chain'] as String,
      createdAt: _time(row['created_at']),
      expiresAt: _time(row['expires_at']),
    );
  }

  @override
  Future<void> deleteSession(String tokenHash) async {
    db.execute('DELETE FROM sui_auth_sessions WHERE token_hash = ?', [
      tokenHash,
    ]);
  }

  @override
  Future<int> deleteSessionsForAddress(String address) async {
    db.execute('DELETE FROM sui_auth_sessions WHERE address = ?', [address]);
    return db.updatedRows;
  }

  @override
  Future<int> deleteExpiredSessions(DateTime now) async {
    db.execute('DELETE FROM sui_auth_sessions WHERE expires_at <= ?', [
      _ms(now),
    ]);
    return db.updatedRows;
  }
}
