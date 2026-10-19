/// Input checks for the metadata API.
library;

/// An error the API reports to the client as JSON.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message, {this.field});

  final int status;
  final String code;
  final String message;
  final String? field;

  Map<String, Object?> toJson() => {
    'error': {
      'code': status,
      'status': code,
      'message': message,
      'field': ?field,
    },
  };

  @override
  String toString() => 'ApiException($status $code: $message)';
}

ApiException badField(String field, String message) =>
    ApiException(400, 'INVALID_FIELD', message, field: field);

/// Collapses inner whitespace and trims. Removes control characters.
String cleanText(String input) => input
    .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '')
    .trim();

String cleanLine(String input) =>
    cleanText(input).replaceAll(RegExp(r'\s+'), ' ');

/// Reads a required one-line string field.
String requireLine(
  Map<String, Object?> body,
  String field, {
  required String label,
  int min = 1,
  int max = 120,
}) {
  final raw = body[field];
  if (raw is! String) throw badField(field, '$label is required.');
  final value = cleanLine(raw);
  if (value.length < min) {
    throw badField(
      field,
      min <= 1
          ? '$label is required.'
          : '$label needs at least $min characters.',
    );
  }
  if (value.length > max) {
    throw badField(field, '$label can be at most $max characters.');
  }
  return value;
}

/// Reads an optional string field. Multi-line when [multiline] is true.
String optionalText(
  Map<String, Object?> body,
  String field, {
  required String label,
  int max = 280,
  bool multiline = false,
}) {
  final raw = body[field];
  if (raw == null) return '';
  if (raw is! String) throw badField(field, '$label must be text.');
  final value = multiline ? cleanText(raw) : cleanLine(raw);
  if (value.length > max) {
    throw badField(field, '$label can be at most $max characters.');
  }
  return value;
}

const vaultKinds = {'personal', 'organization'};

String requireKind(Map<String, Object?> body) {
  final raw = body['kind'];
  if (raw is! String || !vaultKinds.contains(raw)) {
    throw badField('kind', 'Choose personal or organization.');
  }
  return raw;
}

/// A website the owner says links to this vault. Stored as `host/path`
/// without a scheme, or empty.
String optionalWebsite(Map<String, Object?> body) {
  var value = optionalText(body, 'website', label: 'Website', max: 120);
  if (value.isEmpty) return '';
  value = value.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  if (value.endsWith('/')) value = value.substring(0, value.length - 1);
  final ok = RegExp(
    r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(/[^\s]*)?$',
    caseSensitive: false,
  ).hasMatch(value);
  if (!ok) {
    throw badField('website', 'Enter a website like example.org.');
  }
  return value;
}

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _blobIdPattern = RegExp(r'^[A-Za-z0-9_-]{20,100}$');

String requireSha256(Map<String, Object?> body) {
  final raw = body['sha256'];
  if (raw is! String || !_sha256Pattern.hasMatch(raw.toLowerCase())) {
    throw badField('sha256', 'SHA-256 must be 64 hexadecimal characters.');
  }
  return raw.toLowerCase();
}

bool isBlobId(String value) => _blobIdPattern.hasMatch(value);

String requireBlobId(Map<String, Object?> body) {
  final raw = body['blobId'];
  if (raw is! String || !isBlobId(raw)) {
    throw badField('blobId', 'Blob ID is missing or malformed.');
  }
  return raw;
}

/// An issue date as `YYYY-MM-DD`, not after tomorrow (UTC).
String requireIssueDate(Map<String, Object?> body, {DateTime? now}) {
  final raw = body['issueDate'];
  final match = raw is String
      ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw)
      : null;
  if (match == null) {
    throw badField('issueDate', 'Issue date must be a date like 2026-05-31.');
  }
  final y = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  final date = DateTime.utc(y, m, d);
  if (date.year != y || date.month != m || date.day != d || y < 1900) {
    throw badField('issueDate', 'Issue date is not a real date.');
  }
  final today = (now ?? DateTime.now()).toUtc();
  if (date.isAfter(DateTime.utc(today.year, today.month, today.day + 1))) {
    throw badField('issueDate', 'Issue date cannot be in the future.');
  }
  return raw as String;
}

/// A file name safe to show: no path, no control characters.
String cleanFileName(Object? raw) {
  if (raw is! String) return 'document';
  var name = cleanLine(raw).split(RegExp(r'[\\/]')).last;
  if (name.length > 160) name = name.substring(name.length - 160);
  return name.isEmpty ? 'document' : name;
}
