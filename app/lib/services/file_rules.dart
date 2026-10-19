import 'dart:typed_data';

import '../util/format.dart';

/// A file chosen or dropped by the person, held in memory only.
class LocalFile {
  const LocalFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;

  int get size => bytes.length;
}

/// File types Credence stores, identified by signature, not by name.
const storableTypes = {
  'application/pdf': 'PDF',
  'image/png': 'PNG',
  'image/jpeg': 'JPEG',
  'image/webp': 'WebP',
};

/// Value for a file input's `accept` attribute.
const storableAccept =
    '.pdf,.png,.jpg,.jpeg,.webp,application/pdf,image/png,'
    'image/jpeg,image/webp';

/// Returns the MIME type of [bytes] when it is a PDF, PNG, JPEG or WebP.
String? sniffType(List<int> bytes) {
  bool at(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(const [0x25, 0x50, 0x44, 0x46, 0x2D])) return 'application/pdf';
  if (at(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (at(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(const [0x52, 0x49, 0x46, 0x46]) &&
      at(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

/// A short name for what a rejected file seems to be, for error messages.
String describeUnknown(String fileName, List<int> bytes) {
  bool at(List<int> sig) =>
      bytes.length >= sig.length &&
      List.generate(sig.length, (i) => bytes[i] == sig[i]).every((x) => x);
  if (at(const [0x47, 0x49, 0x46, 0x38])) return 'a GIF image';
  if (at(const [0x50, 0x4B, 0x03, 0x04])) {
    return 'a ZIP or Office document';
  }
  final dot = fileName.lastIndexOf('.');
  if (dot > 0 && dot < fileName.length - 1) {
    return 'a .${fileName.substring(dot + 1).toLowerCase()} file';
  }
  return 'a type Credence does not store';
}

/// The outcome of checking a file before upload.
sealed class FileCheck {
  const FileCheck();
}

class FileAccepted extends FileCheck {
  const FileAccepted(this.contentType);
  final String contentType;
  String get label => storableTypes[contentType] ?? 'File';
}

class FileRejected extends FileCheck {
  const FileRejected(this.message);
  final String message;
}

/// Checks type (by signature) and size before anything is uploaded.
FileCheck checkForUpload(LocalFile file, {required int maxBytes}) {
  if (file.size == 0) {
    return const FileRejected('This file is empty. Choose another file.');
  }
  if (file.size > maxBytes) {
    return FileRejected(
      'This file is ${formatBytes(file.size)}. The limit is '
      '${formatBytes(maxBytes)}. Export a smaller PDF or image and try again.',
    );
  }
  final type = sniffType(file.bytes);
  if (type == null) {
    return FileRejected(
      'This looks like ${describeUnknown(file.name, file.bytes)}. Credence '
      'stores PDF, PNG, JPEG and WebP files.',
    );
  }
  return FileAccepted(type);
}

/// Largest copy the "check a copy" panel will hash (it is never uploaded).
const maxCheckBytes = 100 * 1024 * 1024;
