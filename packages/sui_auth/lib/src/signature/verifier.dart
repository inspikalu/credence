import 'dart:typed_data';

import '../address.dart';
import '../bcs.dart';
import '../bytes.dart';
import '../crypto.dart';
import 'graphql.dart';
import 'multisig.dart';
import 'passkey.dart';
import 'scheme.dart';
import 'zklogin.dart';

/// Intent prefix for personal messages: scope 3 (PersonalMessage),
/// version 0, app id 0 (Sui).
const personalMessageIntent = [3, 0, 0];

/// The bytes a wallet signs for `sui:signPersonalMessage`:
/// `intent || bcs(vector<u8> message)`.
Uint8List personalMessageIntentBytes(List<int> message) =>
    concatBytes([personalMessageIntent, bcsByteVector(message)]);

/// blake2b256 of [personalMessageIntentBytes]: what the key actually signs.
Uint8List personalMessageDigest(List<int> message) =>
    blake2b256(personalMessageIntentBytes(message));

/// Verifies Sui personal-message signatures.
///
/// Checked locally: Ed25519, Secp256k1, Secp256r1, passkey, and multisig
/// whose members are any of those. Checked through [remote] (Sui GraphQL):
/// zkLogin, and multisig with a zkLogin member. Not supported: BLS12-381
/// (validators only) and ML-DSA-65 (testnet only).
class SuiSignatureVerifier {
  const SuiSignatureVerifier({this.remote});

  /// Needed for zkLogin. Without it, zkLogin signatures fail with
  /// [SuiSignatureErrorCode.unsupportedScheme].
  final RemoteSignatureVerifier? remote;

  /// Verifies that [signature] (base64 serialized Sui signature) signs
  /// [message] as a personal message, and that it comes from [address].
  ///
  /// Returns the verified signer. Throws [SuiSignatureException] otherwise.
  Future<VerifiedSignature> verifyPersonalMessage({
    required List<int> message,
    required String signature,
    required String address,
  }) async {
    final expected = tryNormalizeSuiAddress(address);
    if (expected == null) {
      throw const SuiSignatureException(
        SuiSignatureErrorCode.malformed,
        'The claimed address is not a Sui address.',
      );
    }
    Uint8List bytes;
    try {
      bytes = decodeBase64(signature);
    } on FormatException {
      throw const SuiSignatureException(
        SuiSignatureErrorCode.malformed,
        'The signature is not valid base64.',
      );
    }
    if (bytes.isEmpty) {
      throw const SuiSignatureException(
        SuiSignatureErrorCode.malformed,
        'The signature is empty.',
      );
    }
    final scheme = SuiSignatureScheme.fromFlag(bytes[0]);
    if (scheme == null) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.unsupportedScheme,
        'Unsupported signature scheme (flag 0x'
        '${bytes[0].toRadixString(16).padLeft(2, '0')}).',
      );
    }
    final body = Uint8List.sublistView(bytes, 1);
    final digest = personalMessageDigest(message);

    try {
      switch (scheme) {
        case SuiSignatureScheme.ed25519:
        case SuiSignatureScheme.secp256k1:
        case SuiSignatureScheme.secp256r1:
          return _verifyKeyPair(scheme, body, digest, expected);
        case SuiSignatureScheme.passkey:
          return _verifyPasskey(body, digest, expected);
        case SuiSignatureScheme.multisig:
          return await _verifyMultiSig(
            body,
            digest,
            expected,
            message,
            signature,
          );
        case SuiSignatureScheme.zkLogin:
          return await _verifyZkLogin(body, expected, message, signature);
        case SuiSignatureScheme.bls12381:
        case SuiSignatureScheme.mldsa65:
          throw SuiSignatureException(
            SuiSignatureErrorCode.unsupportedScheme,
            'Unsupported signature scheme: ${scheme.label}.',
            scheme: scheme,
          );
      }
    } on BcsFormatException catch (e) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.malformed,
        'Malformed ${scheme.label} signature: ${e.message}.',
        scheme: scheme,
      );
    }
  }

  VerifiedSignature _verifyKeyPair(
    SuiSignatureScheme scheme,
    Uint8List body,
    Uint8List digest,
    String expected,
  ) {
    final keyLength = scheme == SuiSignatureScheme.ed25519 ? 32 : 33;
    if (body.length != 64 + keyLength) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.malformed,
        'A ${scheme.label} signature must be ${1 + 64 + keyLength} bytes.',
        scheme: scheme,
      );
    }
    final sig = Uint8List.sublistView(body, 0, 64);
    final publicKey = Uint8List.sublistView(body, 64);
    final signer = suiAddressFromFlaggedKey(scheme.flag, publicKey);
    if (signer != expected) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.addressMismatch,
        'The signature is from $signer, not $expected.',
        scheme: scheme,
      );
    }
    if (!_verifyRaw(scheme, publicKey, sig, digest)) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.invalidSignature,
        'The ${scheme.label} signature does not match the message.',
        scheme: scheme,
      );
    }
    return VerifiedSignature(address: signer, scheme: scheme);
  }

  static bool _verifyRaw(
    SuiSignatureScheme scheme,
    List<int> publicKey,
    List<int> sig,
    Uint8List digest,
  ) => switch (scheme) {
    SuiSignatureScheme.ed25519 => verifyEd25519(
      publicKey: publicKey,
      signature: sig,
      message: digest,
    ),
    SuiSignatureScheme.secp256k1 => verifySecp256k1(
      publicKey: publicKey,
      signature: sig,
      message: digest,
    ),
    SuiSignatureScheme.secp256r1 => verifySecp256r1(
      publicKey: publicKey,
      signature: sig,
      message: digest,
    ),
    _ => false,
  };

  VerifiedSignature _verifyPasskey(
    Uint8List body,
    Uint8List digest,
    String expected,
  ) {
    final parts = parsePasskeyAuthenticator(body);
    final signer = suiAddressFromFlaggedKey(
      SuiSignatureScheme.passkey.flag,
      parts.publicKey,
    );
    if (signer != expected) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.addressMismatch,
        'The passkey signature is from $signer, not $expected.',
        scheme: SuiSignatureScheme.passkey,
      );
    }
    if (!verifyPasskeyAuthenticator(parts, digest)) {
      throw const SuiSignatureException(
        SuiSignatureErrorCode.invalidSignature,
        'The passkey signature does not match the message.',
        scheme: SuiSignatureScheme.passkey,
      );
    }
    return VerifiedSignature(
      address: signer,
      scheme: SuiSignatureScheme.passkey,
    );
  }

  Future<VerifiedSignature> _verifyMultiSig(
    Uint8List body,
    Uint8List digest,
    String expected,
    List<int> message,
    String signature,
  ) async {
    const scheme = SuiSignatureScheme.multisig;
    final parts = parseMultiSig(body);
    final signer = parts.address;
    if (signer != expected) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.addressMismatch,
        'The multisig signature is from $signer, not $expected.',
        scheme: scheme,
      );
    }
    final needsRemote = parts.partials.any(
      (p) => p.scheme == SuiSignatureScheme.zkLogin,
    );
    if (parts.partials.any((p) => p.scheme == SuiSignatureScheme.mldsa65)) {
      throw const SuiSignatureException(
        SuiSignatureErrorCode.unsupportedScheme,
        'Unsupported signature scheme: MLDSA65 inside a multisig.',
        scheme: scheme,
      );
    }
    if (needsRemote) {
      // The whole multisig goes to a full node, which checks every member.
      return _remoteCheck(scheme, message, signature, signer);
    }

    var weight = 0;
    for (final partial in parts.partials) {
      final member = parts.members[partial.memberIndex];
      final ok = switch (partial.scheme) {
        SuiSignatureScheme.passkey => _multisigPasskeyOk(
          partial.signature,
          member.publicKey,
          digest,
        ),
        _ => _verifyRaw(
          partial.scheme,
          member.publicKey,
          partial.signature,
          digest,
        ),
      };
      if (!ok) {
        throw SuiSignatureException(
          SuiSignatureErrorCode.invalidSignature,
          'Multisig member ${partial.memberIndex} '
          '(${partial.scheme.label}) did not sign this message.',
          scheme: scheme,
        );
      }
      weight += member.weight;
    }
    if (weight < parts.threshold) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.invalidSignature,
        'The multisig has weight $weight; it needs ${parts.threshold}.',
        scheme: scheme,
      );
    }
    return VerifiedSignature(address: signer, scheme: scheme);
  }

  static bool _multisigPasskeyOk(
    Uint8List bytes,
    Uint8List memberKey,
    Uint8List digest,
  ) {
    // Mysten's SDK stores the passkey signature with its 0x06 flag. A BCS
    // authenticator itself can never start with 0x06 (authenticator data is
    // at least 37 bytes), so stripping it is unambiguous.
    final body = bytes.isNotEmpty && bytes[0] == SuiSignatureScheme.passkey.flag
        ? Uint8List.sublistView(bytes, 1)
        : bytes;
    final parts = parsePasskeyAuthenticator(body);
    if (!bytesEqual(parts.publicKey, memberKey)) return false;
    return verifyPasskeyAuthenticator(parts, digest);
  }

  Future<VerifiedSignature> _verifyZkLogin(
    Uint8List body,
    String expected,
    List<int> message,
    String signature,
  ) async {
    const scheme = SuiSignatureScheme.zkLogin;
    final parts = parseZkLoginSignature(body);
    if (!parts.matchesAddress(expected)) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.addressMismatch,
        'The zkLogin signature is for ${parts.address}, not $expected.',
        scheme: scheme,
      );
    }
    return _remoteCheck(scheme, message, signature, expected);
  }

  Future<VerifiedSignature> _remoteCheck(
    SuiSignatureScheme scheme,
    List<int> message,
    String signature,
    String address,
  ) async {
    final remote = this.remote;
    if (remote == null) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.unsupportedScheme,
        'Unsupported signature scheme: ${scheme.label} needs a Sui GraphQL '
        'verifier, and none is configured.',
        scheme: scheme,
      );
    }
    final result = await remote.verifyPersonalMessage(
      message: message,
      signature: signature,
      address: address,
    );
    if (!result.valid) {
      throw SuiSignatureException(
        SuiSignatureErrorCode.invalidSignature,
        'Sui rejected the ${scheme.label} signature'
        '${result.reason == null ? '' : ': ${result.reason}'}.',
        scheme: scheme,
      );
    }
    return VerifiedSignature(
      address: address,
      scheme: scheme,
      verifiedRemotely: true,
    );
  }
}
