/// Identifies allowed file types from their first bytes.
///
/// Dartus sends uploads as `application/octet-stream`, so the server cannot
/// trust a declared type. It reads the file signature instead.
library;

/// MIME types Credence accepts.
const allowedContentTypes = <String>[
  'application/pdf',
  'image/png',
  'image/jpeg',
  'image/webp',
];

/// Returns the MIME type for [bytes], or null when it is not an allowed type.
String? sniffContentType(List<int> bytes) {
  bool startsWith(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  // %PDF-
  if (startsWith(const [0x25, 0x50, 0x44, 0x46, 0x2D])) {
    return 'application/pdf';
  }
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  // RIFF....WEBP
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
