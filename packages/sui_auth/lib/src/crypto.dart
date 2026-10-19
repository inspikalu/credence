import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pinenacl/ed25519.dart' as nacl;
import 'package:pointycastle/digests/blake2b.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/signers/ecdsa_signer.dart';

import 'bytes.dart';

/// Blake2b with a 32-byte output, as Sui uses for digests and addresses.
Uint8List blake2b256(List<int> data) =>
    Blake2bDigest(digestSize: 32).process(Uint8List.fromList(data));

Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

/// Order of the Ed25519 base point.
final _ed25519L = BigInt.parse(
  '7237005577332262213973186563042994240857116359379907606001950938285454250989',
);

/// Verifies a pure Ed25519 signature (RFC 8032).
///
/// Rejects a non-canonical `S` (S >= L), which is what Sui's verifier does.
bool verifyEd25519({
  required List<int> publicKey,
  required List<int> signature,
  required List<int> message,
}) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final s = bigIntFromLittleEndian(signature.sublist(32));
  if (s >= _ed25519L) return false;
  try {
    return nacl.VerifyKey(Uint8List.fromList(publicKey)).verify(
      signature: nacl.Signature(Uint8List.fromList(signature)),
      message: Uint8List.fromList(message),
    );
  } catch (_) {
    // pinenacl throws on a forged or malformed signature.
    return false;
  }
}

/// Signs [message] with an Ed25519 key derived from a 32-byte [seed].
/// Used by the test helpers; servers never hold private keys.
({Uint8List publicKey, Uint8List signature}) signEd25519({
  required List<int> seed,
  required List<int> message,
}) {
  final key = nacl.SigningKey.fromSeed(Uint8List.fromList(seed));
  final signed = key.sign(Uint8List.fromList(message));
  return (
    publicKey: Uint8List.fromList(key.verifyKey.asTypedList),
    signature: Uint8List.fromList(signed.signature.asTypedList),
  );
}

final ECDomainParameters _secp256k1 = ECCurve_secp256k1();
final ECDomainParameters _secp256r1 = ECCurve_secp256r1();

/// Verifies a Secp256k1 ECDSA signature over `sha256(message)`.
///
/// [signature] is the 64-byte compact `r || s`; [publicKey] is the 33-byte
/// compressed point. High-S signatures are rejected, as in Sui.
bool verifySecp256k1({
  required List<int> publicKey,
  required List<int> signature,
  required List<int> message,
}) => _verifyEcdsa(_secp256k1, publicKey, signature, message);

/// Verifies a Secp256r1 (P-256) ECDSA signature over `sha256(message)`.
bool verifySecp256r1({
  required List<int> publicKey,
  required List<int> signature,
  required List<int> message,
}) => _verifyEcdsa(_secp256r1, publicKey, signature, message);

bool _verifyEcdsa(
  ECDomainParameters params,
  List<int> publicKey,
  List<int> signature,
  List<int> message,
) {
  if (publicKey.length != 33 || signature.length != 64) return false;
  if (publicKey[0] != 0x02 && publicKey[0] != 0x03) return false;
  final n = params.n;
  final r = bigIntFromBytes(signature.sublist(0, 32));
  final s = bigIntFromBytes(signature.sublist(32));
  if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
  if (s > (n >> 1)) return false; // Only low-S (normalised) signatures.

  final curve = params.curve as fp.ECCurve;
  final x = bigIntFromBytes(publicKey.sublist(1));
  if (x >= curve.q!) return false;

  ECPoint? q;
  try {
    q = params.curve.decodePoint(publicKey);
  } catch (_) {
    return false;
  }
  if (q == null || q.isInfinity) return false;

  final signer = ECDSASigner()
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, params)));
  try {
    return signer.verifySignature(sha256Bytes(message), ECSignature(r, s));
  } catch (_) {
    return false;
  }
}
