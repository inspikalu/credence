import 'dart:convert';
import 'dart:typed_data';

/// Thrown when BCS bytes are truncated or malformed.
class BcsFormatException extends FormatException {
  const BcsFormatException(super.message);
}

/// A minimal reader for the parts of BCS that Sui signatures use.
class BcsReader {
  BcsReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int get offset => _offset;
  int get remaining => _bytes.length - _offset;

  void _need(int n) {
    if (n < 0 || n > remaining) {
      throw const BcsFormatException('Unexpected end of BCS data');
    }
  }

  int u8() {
    _need(1);
    return _bytes[_offset++];
  }

  int u16() {
    _need(2);
    final v = _bytes[_offset] | (_bytes[_offset + 1] << 8);
    _offset += 2;
    return v;
  }

  BigInt u64() {
    _need(8);
    var v = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | BigInt.from(_bytes[_offset + i]);
    }
    _offset += 8;
    return v;
  }

  /// ULEB128, limited to 32 bits like Sui's BCS.
  int uleb128() {
    var value = 0;
    var shift = 0;
    while (true) {
      if (shift > 28) throw const BcsFormatException('ULEB128 too long');
      final byte = u8();
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        if (shift > 0 && byte == 0) {
          throw const BcsFormatException('Non-canonical ULEB128');
        }
        break;
      }
      shift += 7;
    }
    if (value > 0xffffffff) throw const BcsFormatException('ULEB128 overflow');
    return value;
  }

  Uint8List fixedBytes(int n) {
    _need(n);
    final out = Uint8List.sublistView(_bytes, _offset, _offset + n);
    _offset += n;
    return Uint8List.fromList(out);
  }

  Uint8List byteVector() => fixedBytes(uleb128());

  String string() {
    try {
      return utf8.decode(byteVector());
    } on FormatException {
      throw const BcsFormatException('Invalid UTF-8 in BCS string');
    }
  }

  List<T> vector<T>(T Function(BcsReader reader) read, {int max = 1 << 16}) {
    final length = uleb128();
    if (length > max) throw const BcsFormatException('BCS vector too long');
    return [for (var i = 0; i < length; i++) read(this)];
  }

  void expectEnd() {
    if (remaining != 0) {
      throw const BcsFormatException('Trailing bytes after BCS value');
    }
  }
}

/// ULEB128 encoding of a non-negative length.
Uint8List encodeUleb128(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  final out = <int>[];
  var v = value;
  do {
    var byte = v & 0x7f;
    v >>= 7;
    if (v != 0) byte |= 0x80;
    out.add(byte);
  } while (v != 0);
  return Uint8List.fromList(out);
}

/// BCS `vector<u8>`: ULEB128 length followed by the bytes.
Uint8List bcsByteVector(List<int> bytes) {
  final prefix = encodeUleb128(bytes.length);
  final out = Uint8List(prefix.length + bytes.length)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + bytes.length, bytes);
  return out;
}
