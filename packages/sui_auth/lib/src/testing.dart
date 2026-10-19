import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'address.dart';
import 'bytes.dart';
import 'crypto.dart';
import 'message.dart';
import 'signature/scheme.dart';
import 'signature/verifier.dart';

/// An Ed25519 Sui key for tests: signs personal messages exactly as a
/// wallet does (`flag || signature || publicKey`, base64).
///
/// Never use it for real funds; the seed is held in memory in plain form.
class TestSuiSigner {
  TestSuiSigner._(this.seed)
    : publicKey = signEd25519(seed: seed, message: const []).publicKey;

  /// A signer from a 32-byte seed (hex, with or without `0x`).
  factory TestSuiSigner.fromSeedHex(String hex) {
    final seed = fromHex(hex);
    if (seed.length != 32) throw ArgumentError.value(hex, 'hex', '32 bytes');
    return TestSuiSigner._(seed);
  }

  /// A signer with a fresh random seed.
  factory TestSuiSigner.random([Random? random]) {
    final r = random ?? Random.secure();
    return TestSuiSigner._(
      Uint8List.fromList(List.generate(32, (_) => r.nextInt(256))),
    );
  }

  final Uint8List seed;
  final Uint8List publicKey;

  String get address =>
      suiAddressFromFlaggedKey(SuiSignatureScheme.ed25519.flag, publicKey);

  /// Base64 Sui public key (flag byte + key), as wallets report it.
  String get suiPublicKey =>
      base64.encode([SuiSignatureScheme.ed25519.flag, ...publicKey]);

  /// Signs [message] as `sui:signPersonalMessage` would.
  String signPersonalMessage(List<int> message) {
    final digest = personalMessageDigest(message);
    final sig = signEd25519(seed: seed, message: digest).signature;
    return base64.encode([
      SuiSignatureScheme.ed25519.flag,
      ...sig,
      ...publicKey,
    ]);
  }

  /// Signs the text of a sign-in message.
  String signText(String text) => signPersonalMessage(utf8.encode(text));

  /// Signs a [SuiSignInMessage].
  String signMessage(SuiSignInMessage message) =>
      signPersonalMessage(message.toBytes());
}
