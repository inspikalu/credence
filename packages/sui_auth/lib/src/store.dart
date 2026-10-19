import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto.dart';

/// A sign-in nonce waiting to be used.
class NonceRecord {
  const NonceRecord({
    required this.nonce,
    required this.createdAt,
    required this.expiresAt,
    this.address,
  });

  final String nonce;

  /// When set, only a message for this address may use the nonce.
  final String? address;
  final DateTime createdAt;
  final DateTime expiresAt;
}

/// Storage for single-use sign-in nonces.
abstract interface class NonceStore {
  Future<void> saveNonce(NonceRecord record);

  /// Removes the nonce and returns it, whether or not it has expired.
  ///
  /// Must be atomic: if two requests take the same nonce at once, only one
  /// of them gets the record. Returns null when the nonce is unknown or was
  /// already taken.
  Future<NonceRecord?> takeNonce(String nonce);

  /// Number of stored nonces (used to cap outstanding challenges).
  Future<int> countNonces();

  Future<int> deleteExpiredNonces(DateTime now);
}

/// A signed-in session. Only the SHA-256 hash of the token is stored.
class SuiSession {
  const SuiSession({
    required this.tokenHash,
    required this.address,
    required this.chainId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String tokenHash;

  /// The verified Sui address.
  final String address;
  final String chainId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'address': address,
    'chain': chainId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// Storage for sessions.
abstract interface class SessionStore {
  Future<void> saveSession(SuiSession session);
  Future<SuiSession?> findSession(String tokenHash);
  Future<void> deleteSession(String tokenHash);
  Future<int> deleteSessionsForAddress(String address);
  Future<int> deleteExpiredSessions(DateTime now);
}

/// Keeps nonces and sessions in memory. For tests and single-process tools;
/// everything is lost on restart.
class InMemorySuiAuthStore implements NonceStore, SessionStore {
  final _nonces = <String, NonceRecord>{};
  final _sessions = <String, SuiSession>{};

  @override
  Future<void> saveNonce(NonceRecord record) async {
    _nonces[record.nonce] = record;
  }

  @override
  Future<NonceRecord?> takeNonce(String nonce) async => _nonces.remove(nonce);

  @override
  Future<int> countNonces() async => _nonces.length;

  @override
  Future<int> deleteExpiredNonces(DateTime now) async {
    final before = _nonces.length;
    _nonces.removeWhere((_, r) => !now.isBefore(r.expiresAt));
    return before - _nonces.length;
  }

  @override
  Future<void> saveSession(SuiSession session) async {
    _sessions[session.tokenHash] = session;
  }

  @override
  Future<SuiSession?> findSession(String tokenHash) async =>
      _sessions[tokenHash];

  @override
  Future<void> deleteSession(String tokenHash) async {
    _sessions.remove(tokenHash);
  }

  @override
  Future<int> deleteSessionsForAddress(String address) async {
    final before = _sessions.length;
    _sessions.removeWhere((_, s) => s.address == address);
    return before - _sessions.length;
  }

  @override
  Future<int> deleteExpiredSessions(DateTime now) async {
    final before = _sessions.length;
    _sessions.removeWhere((_, s) => !now.isBefore(s.expiresAt));
    return before - _sessions.length;
  }
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

/// 128 random bits as 32 lowercase hex characters (alphanumeric, as
/// EIP-4361 requires).
String generateNonce(Random random) => toHex(_randomBytes(random, 16));

/// 256 random bits as base64url without padding (43 characters).
String generateSessionToken(Random random) =>
    encodeBase64UrlNoPad(_randomBytes(random, 32));

/// What is stored instead of the token: SHA-256, lowercase hex.
String hashSessionToken(String token) => toHex(sha256Bytes(utf8.encode(token)));
