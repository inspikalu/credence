import 'dart:convert';
import 'dart:typed_data';

import '../bcs.dart';
import '../bytes.dart';
import '../crypto.dart';
import 'scheme.dart';

/// A decoded Sui passkey (WebAuthn) authenticator.
class PasskeyAuthenticatorParts {
  const PasskeyAuthenticatorParts({
    required this.authenticatorData,
    required this.clientDataJson,
    required this.userSignature,
  });

  final Uint8List authenticatorData;
  final String clientDataJson;

  /// `0x02 || r || s || compressedPublicKey` (a Secp256r1 signature).
  final Uint8List userSignature;

  Uint8List get compactSignature =>
      Uint8List.fromList(userSignature.sublist(1, 65));
  Uint8List get publicKey => Uint8List.fromList(userSignature.sublist(65));
}

/// Parses BCS `PasskeyAuthenticator` bytes (without the 0x06 flag).
PasskeyAuthenticatorParts parsePasskeyAuthenticator(Uint8List bytes) {
  final r = BcsReader(bytes);
  final authenticatorData = r.byteVector();
  final clientDataJson = r.string();
  final userSignature = r.byteVector();
  r.expectEnd();
  if (userSignature.length != 1 + 64 + 33 ||
      userSignature[0] != SuiSignatureScheme.secp256r1.flag) {
    throw const BcsFormatException('Invalid passkey user signature');
  }
  return PasskeyAuthenticatorParts(
    authenticatorData: authenticatorData,
    clientDataJson: clientDataJson,
    userSignature: userSignature,
  );
}

/// Checks a passkey assertion over a Sui intent-message [digest].
///
/// Same rules as Sui: `clientDataJSON.type` is `webauthn.get`, its challenge
/// is the digest, and the P-256 signature covers
/// `authenticatorData || sha256(clientDataJSON)`.
bool verifyPasskeyAuthenticator(
  PasskeyAuthenticatorParts parts,
  Uint8List digest,
) {
  Object? clientData;
  try {
    clientData = jsonDecode(parts.clientDataJson);
  } on FormatException {
    return false;
  }
  if (clientData is! Map) return false;
  if (clientData['type'] != 'webauthn.get') return false;
  final challenge = clientData['challenge'];
  if (challenge is! String) return false;
  Uint8List challengeBytes;
  try {
    challengeBytes = decodeBase64Url(challenge);
  } on FormatException {
    return false;
  }
  if (!bytesEqual(challengeBytes, digest)) return false;
  final payload = concatBytes([
    parts.authenticatorData,
    sha256Bytes(utf8.encode(parts.clientDataJson)),
  ]);
  return verifySecp256r1(
    publicKey: parts.publicKey,
    signature: parts.compactSignature,
    message: payload,
  );
}
