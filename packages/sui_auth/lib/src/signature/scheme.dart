/// Sui signature schemes, keyed by the flag byte that starts a serialized
/// signature (and that prefixes a public key when deriving an address).
enum SuiSignatureScheme {
  ed25519(0x00, 'ED25519'),
  secp256k1(0x01, 'Secp256k1'),
  secp256r1(0x02, 'Secp256r1'),
  multisig(0x03, 'MultiSig'),
  bls12381(0x04, 'BLS12381'),
  zkLogin(0x05, 'ZkLogin'),
  passkey(0x06, 'Passkey'),
  mldsa65(0x07, 'MLDSA65');

  const SuiSignatureScheme(this.flag, this.label);

  final int flag;

  /// The name Mysten's SDKs use for the scheme.
  final String label;

  static SuiSignatureScheme? fromFlag(int flag) {
    for (final s in values) {
      if (s.flag == flag) return s;
    }
    return null;
  }

  @override
  String toString() => label;
}

/// Why a signature was not accepted.
enum SuiSignatureErrorCode {
  /// The bytes are not a well-formed Sui signature.
  malformed,

  /// The scheme is known but this verifier cannot check it.
  unsupportedScheme,

  /// The signature does not verify for this message.
  invalidSignature,

  /// The signature is from a different address than the one claimed.
  addressMismatch,

  /// A remote check (zkLogin through GraphQL) could not be completed.
  verifierUnavailable,
}

class SuiSignatureException implements Exception {
  const SuiSignatureException(this.code, this.message, {this.scheme});

  final SuiSignatureErrorCode code;
  final String message;
  final SuiSignatureScheme? scheme;

  @override
  String toString() =>
      'SuiSignatureException(${code.name}'
      '${scheme == null ? '' : ', ${scheme!.label}'}): $message';
}

/// A signature that verified, and what it verified as.
class VerifiedSignature {
  const VerifiedSignature({
    required this.address,
    required this.scheme,
    this.verifiedRemotely = false,
  });

  /// Normalised signer address.
  final String address;
  final SuiSignatureScheme scheme;

  /// True when a Sui GraphQL endpoint did the cryptographic check.
  final bool verifiedRemotely;
}
