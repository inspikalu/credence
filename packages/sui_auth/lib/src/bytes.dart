import 'dart:convert';
import 'dart:typed_data';

const _hexDigits = '0123456789abcdef';

/// Lowercase hex without a `0x` prefix.
String toHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(_hexDigits[(b >> 4) & 0xf])
      ..write(_hexDigits[b & 0xf]);
  }
  return out.toString();
}

/// Parses hex with or without a `0x` prefix. Throws [FormatException].
Uint8List fromHex(String input) {
  var hex = input.startsWith('0x') || input.startsWith('0X')
      ? input.substring(2)
      : input;
  if (hex.length.isOdd) hex = '0$hex';
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _nibble(hex.codeUnitAt(i * 2));
    final lo = _nibble(hex.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) throw FormatException('Invalid hex', input);
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// Decodes standard base64 (padding optional). Throws [FormatException].
Uint8List decodeBase64(String input) {
  final s = input.trim();
  if (s.contains('-') || s.contains('_')) {
    throw FormatException('Expected standard base64', input);
  }
  return base64.decode(base64.normalize(s));
}

/// Decodes base64url (padding optional). Throws [FormatException].
Uint8List decodeBase64Url(String input) =>
    base64Url.decode(base64Url.normalize(input.trim()));

/// base64url without padding, as used by WebAuthn and session tokens.
String encodeBase64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Compares two byte lists in time that depends only on their lengths.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List concatBytes(List<List<int>> parts) {
  final total = parts.fold<int>(0, (sum, p) => sum + p.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

/// Unsigned big-endian bytes to [BigInt].
BigInt bigIntFromBytes(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

/// Unsigned little-endian bytes to [BigInt].
BigInt bigIntFromLittleEndian(List<int> bytes) =>
    bigIntFromBytes(bytes.reversed.toList());

/// [value] as unsigned big-endian bytes, left-padded to [length].
Uint8List bigIntToBytes(BigInt value, int length) {
  if (value.isNegative) throw ArgumentError.value(value, 'value');
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  if (v != BigInt.zero) {
    throw ArgumentError.value(value, 'value', 'does not fit in $length bytes');
  }
  return out;
}
