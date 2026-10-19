import 'bytes.dart';
import 'crypto.dart';

final _canonicalAddress = RegExp(r'^0x[0-9a-f]{64}$');
final _looseAddress = RegExp(r'^(0x|0X)?[0-9a-fA-F]{1,64}$');

/// Whether [address] is a full-length, lowercase Sui address
/// (`0x` followed by 64 hex digits), the form wallets return.
bool isCanonicalSuiAddress(String address) =>
    _canonicalAddress.hasMatch(address);

/// Normalises a Sui address to `0x` + 64 lowercase hex digits.
///
/// Accepts short forms such as `0x2`. Throws [FormatException] for anything
/// that is not hex.
String normalizeSuiAddress(String address) {
  final trimmed = address.trim();
  if (!_looseAddress.hasMatch(trimmed)) {
    throw FormatException('Not a Sui address', address);
  }
  final hex = trimmed.startsWith('0x') || trimmed.startsWith('0X')
      ? trimmed.substring(2)
      : trimmed;
  return '0x${hex.toLowerCase().padLeft(64, '0')}';
}

/// Returns the normalised address, or null when [address] is not one.
String? tryNormalizeSuiAddress(String? address) {
  if (address == null) return null;
  try {
    return normalizeSuiAddress(address);
  } on FormatException {
    return null;
  }
}

/// `0x` + hex(blake2b256(flag || publicKeyBytes)): how Sui derives an address
/// from a public key of any scheme (for multisig and zkLogin, the "public
/// key" is the scheme's own identifier bytes).
String suiAddressFromFlaggedKey(int flag, List<int> publicKeyBytes) =>
    '0x${toHex(blake2b256([flag, ...publicKeyBytes]))}';
