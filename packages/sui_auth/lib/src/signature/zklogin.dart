import 'dart:convert';
import 'dart:typed_data';

import '../address.dart';
import '../bcs.dart';
import '../bytes.dart';
import 'scheme.dart';

/// The parts of a zkLogin signature that can be read without a prover.
///
/// The proof itself is checked by a Sui full node (through GraphQL); this
/// class only exposes what is needed to tie the signature to an address.
class ZkLoginSignatureParts {
  const ZkLoginSignatureParts({
    required this.iss,
    required this.addressSeed,
    required this.maxEpoch,
    required this.headerBase64,
    required this.userSignature,
  });

  /// OAuth issuer, normalised (`accounts.google.com` becomes
  /// `https://accounts.google.com`).
  final String iss;
  final BigInt addressSeed;
  final BigInt maxEpoch;
  final String headerBase64;

  /// The ephemeral key's own serialized signature.
  final Uint8List userSignature;

  /// The address Sui derives today (seed padded to 32 bytes).
  String get address => zkLoginAddress(iss, addressSeed);

  /// The older derivation, which strips leading zero bytes from the seed.
  /// Accounts created before the change still use it.
  String get legacyAddress => zkLoginAddress(iss, addressSeed, legacy: true);

  bool matchesAddress(String normalizedAddress) =>
      normalizedAddress == address || normalizedAddress == legacyAddress;
}

/// Parses BCS `ZkLoginSignature` bytes (without the leading 0x05 flag).
ZkLoginSignatureParts parseZkLoginSignature(Uint8List bytes) {
  final r = BcsReader(bytes);
  // inputs.proofPoints: a, b, c (strings; checked by the node, not here).
  r.vector((r) => r.string(), max: 16);
  r.vector((r) => r.vector((r) => r.string(), max: 16), max: 16);
  r.vector((r) => r.string(), max: 16);
  // inputs.issBase64Details
  final issValue = r.string();
  final issIndexMod4 = r.u8();
  final headerBase64 = r.string();
  final addressSeedText = r.string();
  final maxEpoch = r.u64();
  final userSignature = r.byteVector();
  r.expectEnd();

  final seed = BigInt.tryParse(addressSeedText);
  if (seed == null || seed.isNegative || seed.bitLength > 256) {
    throw const BcsFormatException('Invalid zkLogin address seed');
  }
  final iss = extractZkLoginClaim(issValue, issIndexMod4, 'iss');
  return ZkLoginSignatureParts(
    iss: normalizeZkLoginIssuer(iss),
    addressSeed: seed,
    maxEpoch: maxEpoch,
    headerBase64: headerBase64,
    userSignature: userSignature,
  );
}

String normalizeZkLoginIssuer(String iss) =>
    iss == 'accounts.google.com' ? 'https://accounts.google.com' : iss;

/// zkLogin public identifier bytes: `len(iss) || iss || seed`.
Uint8List zkLoginPublicIdentifier(
  String iss,
  BigInt addressSeed, {
  bool legacy = false,
}) {
  final issBytes = utf8.encode(normalizeZkLoginIssuer(iss));
  if (issBytes.length > 255) throw ArgumentError.value(iss, 'iss');
  var seed = bigIntToBytes(addressSeed, 32);
  if (legacy) {
    final first = seed.indexWhere((b) => b != 0);
    seed = first == -1 ? Uint8List(1) : Uint8List.fromList(seed.sublist(first));
  }
  return concatBytes([
    [issBytes.length],
    issBytes,
    seed,
  ]);
}

String zkLoginAddress(String iss, BigInt addressSeed, {bool legacy = false}) =>
    suiAddressFromFlaggedKey(
      SuiSignatureScheme.zkLogin.flag,
      zkLoginPublicIdentifier(iss, addressSeed, legacy: legacy),
    );

/// Decodes a claim from its base64url slice of the JWT payload.
///
/// zkLogin carries only the slice of the payload that holds the claim, plus
/// the slice's start position mod 4, so the slice may begin and end part-way
/// through a base64 character. This mirrors `decodeBase64URL` in Mysten's SDK.
String decodeZkLoginClaim(String value, int indexMod4) {
  if (value.length < 2) throw const FormatException('zkLogin claim too short');
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final bits = <int>[];
  for (final unit in value.codeUnits) {
    final index = alphabet.indexOf(String.fromCharCode(unit));
    if (index < 0) throw const FormatException('Invalid base64url character');
    for (var b = 5; b >= 0; b--) {
      bits.add((index >> b) & 1);
    }
  }
  var start = 0;
  var end = bits.length;
  switch (indexMod4 % 4) {
    case 0:
      break;
    case 1:
      start = 2;
    case 2:
      start = 4;
    default:
      throw const FormatException('zkLogin claim is not tightly packed');
  }
  switch ((indexMod4 + value.length - 1) % 4) {
    case 3:
      break;
    case 2:
      end -= 2;
    case 1:
      end -= 4;
    default:
      throw const FormatException('zkLogin claim is not tightly packed');
  }
  final used = bits.sublist(start, end);
  if (used.length % 8 != 0) {
    throw const FormatException('zkLogin claim has a partial byte');
  }
  final out = Uint8List(used.length ~/ 8);
  for (var i = 0; i < out.length; i++) {
    var byte = 0;
    for (var b = 0; b < 8; b++) {
      byte = (byte << 1) | used[i * 8 + b];
    }
    out[i] = byte;
  }
  return utf8.decode(out);
}

/// Reads `"name":value,` (or `...}`) and returns the value of [claimName].
String extractZkLoginClaim(String value, int indexMod4, String claimName) {
  final String claim;
  try {
    claim = decodeZkLoginClaim(value, indexMod4);
  } on FormatException {
    throw const BcsFormatException('Invalid zkLogin issuer claim');
  }
  if (!(claim.endsWith('}') || claim.endsWith(','))) {
    throw const BcsFormatException('Invalid zkLogin issuer claim');
  }
  Object? decoded;
  try {
    decoded = jsonDecode('{${claim.substring(0, claim.length - 1)}}');
  } on FormatException {
    throw const BcsFormatException('Invalid zkLogin issuer claim');
  }
  if (decoded is! Map || decoded.length != 1) {
    throw const BcsFormatException('Invalid zkLogin issuer claim');
  }
  final entry = decoded.entries.single;
  if (entry.key != claimName || entry.value is! String) {
    throw const BcsFormatException('Invalid zkLogin issuer claim');
  }
  return entry.value as String;
}
