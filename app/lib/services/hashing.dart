import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Computes the SHA-256 of [bytes] as 64 lowercase hex characters.
///
/// Hashes in chunks and yields to the event loop between them, so the page
/// stays responsive and [onProgress] (0.0 to 1.0) can drive a progress bar.
/// Runs entirely on this device.
Future<String> sha256Hex(
  Uint8List bytes, {
  void Function(double progress)? onProgress,
  int chunkSize = 256 * 1024,
}) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  var offset = 0;
  onProgress?.call(0);
  while (offset < bytes.length) {
    final end = offset + chunkSize < bytes.length
        ? offset + chunkSize
        : bytes.length;
    input.add(Uint8List.sublistView(bytes, offset, end));
    offset = end;
    onProgress?.call(bytes.isEmpty ? 1 : offset / bytes.length);
    if (offset < bytes.length) await Future<void>.delayed(Duration.zero);
  }
  input.close();
  onProgress?.call(1);
  return out.value.toString();
}

/// Splits a fingerprint into groups of [size] for reading aloud or by eye.
List<String> groupFingerprint(String hex, {int size = 8}) => [
  for (var i = 0; i < hex.length; i += size)
    hex.substring(i, i + size > hex.length ? hex.length : i + size),
];

/// Index of the first group (of [size]) where two fingerprints differ, or -1.
int firstDifferentGroup(String a, String b, {int size = 8}) {
  final ga = groupFingerprint(a, size: size);
  final gb = groupFingerprint(b, size: size);
  for (var i = 0; i < ga.length && i < gb.length; i++) {
    if (ga[i] != gb[i]) return i;
  }
  return ga.length == gb.length
      ? -1
      : (ga.length < gb.length ? ga.length : gb.length);
}
