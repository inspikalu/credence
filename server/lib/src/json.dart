import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'validation.dart';

const _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

Response jsonResponse(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

Response errorResponse(ApiException e) =>
    jsonResponse(e.toJson(), status: e.status);

/// Reads a JSON object body of at most [maxBytes].
Future<Map<String, Object?>> readJsonObject(
  Request request, {
  int maxBytes = 64 * 1024,
}) async {
  final length = request.contentLength;
  if (length != null && length > maxBytes) {
    throw const ApiException(413, 'TOO_LARGE', 'Request body is too large.');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw const ApiException(413, 'TOO_LARGE', 'Request body is too large.');
    }
  }
  if (builder.isEmpty) return <String, Object?>{};
  try {
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Reported below.
  }
  throw const ApiException(
    400,
    'BAD_JSON',
    'Request body must be a JSON object.',
  );
}
