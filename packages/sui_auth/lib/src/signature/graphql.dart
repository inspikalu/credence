import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../chain.dart';
import 'scheme.dart';

/// Result of asking a Sui node whether a signature is valid.
class RemoteVerification {
  const RemoteVerification({required this.valid, this.reason, this.endpoint});

  final bool valid;

  /// The node's explanation when [valid] is false.
  final String? reason;
  final Uri? endpoint;
}

/// Checks signatures that cannot be verified locally (zkLogin).
abstract interface class RemoteSignatureVerifier {
  /// Returns whether [signature] (base64, with its flag byte) is a valid
  /// personal-message signature by [address] over the raw [message] bytes.
  ///
  /// Throws [SuiSignatureException] with
  /// [SuiSignatureErrorCode.verifierUnavailable] when no answer could be had.
  Future<RemoteVerification> verifyPersonalMessage({
    required List<int> message,
    required String signature,
    required String address,
  });
}

/// Which GraphQL field to call.
enum SuiGraphQLVerifyQuery {
  /// `verifySignature(message, signature, intentScope, author)`: the field on
  /// Mysten's current GraphQL service (all schemes, including zkLogin).
  verifySignature,

  /// `verifyZkLoginSignature(bytes, signature, intentScope, author)`: the
  /// field on the older `sui-graphql-rpc` service.
  verifyZkLoginSignature,
}

const _verifySignatureQuery = r'''
query SuiAuthVerifySignature($message: Base64!, $signature: Base64!, $author: SuiAddress!) {
  verifySignature(message: $message, signature: $signature, intentScope: PERSONAL_MESSAGE, author: $author) {
    success
  }
}''';

const _verifyZkLoginQuery = r'''
query SuiAuthVerifyZkLogin($bytes: Base64!, $signature: Base64!, $author: SuiAddress!) {
  verifyZkLoginSignature(bytes: $bytes, signature: $signature, intentScope: PERSONAL_MESSAGE, author: $author) {
    success
    errors
  }
}''';

/// Verifies signatures through Sui GraphQL.
///
/// [endpoints] are tried in order. The first endpoint that says "valid" wins.
/// If every endpoint that answered said "invalid", the signature is invalid.
/// If none answered, [SuiSignatureException] (`verifierUnavailable`) is thrown.
///
/// The message is sent as raw bytes (base64). That is what the live
/// `verifySignature` field expects for `PERSONAL_MESSAGE`; the BCS-wrapped
/// form is rejected (checked against testnet on 2026-10-15).
class SuiGraphQLVerifier implements RemoteSignatureVerifier {
  SuiGraphQLVerifier({
    required List<Uri> endpoints,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.query = SuiGraphQLVerifyQuery.verifySignature,
  }) : endpoints = List.unmodifiable(endpoints),
       _client = client ?? http.Client() {
    if (endpoints.isEmpty) throw ArgumentError('No GraphQL endpoints');
  }

  /// Uses Mysten's public endpoint for [chain], then any [fallbacks].
  factory SuiGraphQLVerifier.forChain(
    SuiChain chain, {
    List<Uri> fallbacks = const [],
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) => SuiGraphQLVerifier(
    endpoints: [chain.graphqlEndpoint, ...fallbacks],
    client: client,
    timeout: timeout,
  );

  final List<Uri> endpoints;
  final Duration timeout;
  final SuiGraphQLVerifyQuery query;
  final http.Client _client;

  @override
  Future<RemoteVerification> verifyPersonalMessage({
    required List<int> message,
    required String signature,
    required String address,
  }) async {
    RemoteVerification? firstInvalid;
    final problems = <String>[];
    for (final endpoint in endpoints) {
      try {
        final result = await _ask(endpoint, message, signature, address);
        if (result.valid) return result;
        firstInvalid ??= result;
      } on _Unavailable catch (e) {
        problems.add('${endpoint.host}: ${e.reason}');
      }
    }
    if (firstInvalid != null) return firstInvalid;
    throw SuiSignatureException(
      SuiSignatureErrorCode.verifierUnavailable,
      'Could not reach Sui GraphQL to verify the signature '
      '(${problems.join('; ')}).',
    );
  }

  Future<RemoteVerification> _ask(
    Uri endpoint,
    List<int> message,
    String signature,
    String address,
  ) async {
    final encodedMessage = base64.encode(message);
    final body = switch (query) {
      SuiGraphQLVerifyQuery.verifySignature => {
        'query': _verifySignatureQuery,
        'variables': {
          'message': encodedMessage,
          'signature': signature,
          'author': address,
        },
      },
      SuiGraphQLVerifyQuery.verifyZkLoginSignature => {
        'query': _verifyZkLoginQuery,
        'variables': {
          'bytes': encodedMessage,
          'signature': signature,
          'author': address,
        },
      },
    };

    http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: const {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const _Unavailable('timed out');
    } catch (e) {
      throw _Unavailable('request failed (${e.runtimeType})');
    }

    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw _Unavailable('HTTP ${response.statusCode}, not JSON');
    }
    if (json is! Map) throw _Unavailable('HTTP ${response.statusCode}');

    final field = query.name;
    final data = json['data'];
    final result = data is Map ? data[field] : null;
    if (result is Map && result['success'] == true) {
      final errors = result['errors'];
      if (errors is List && errors.isNotEmpty) {
        return RemoteVerification(
          valid: false,
          reason: errors.join('; '),
          endpoint: endpoint,
        );
      }
      return RemoteVerification(valid: true, endpoint: endpoint);
    }

    final errors = json['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message = first is Map ? '${first['message']}' : '$first';
      final extensions = first is Map ? first['extensions'] : null;
      final code = extensions is Map ? extensions['code'] : null;
      if (code == 'BAD_USER_INPUT') {
        // The node looked at the signature and refused it.
        return RemoteVerification(
          valid: false,
          reason: message,
          endpoint: endpoint,
        );
      }
      throw _Unavailable('${code ?? 'error'}: $message');
    }
    if (result is Map && result['success'] == false) {
      final errors = result['errors'];
      return RemoteVerification(
        valid: false,
        reason: errors is List && errors.isNotEmpty ? errors.join('; ') : null,
        endpoint: endpoint,
      );
    }
    if (response.statusCode != 200) {
      throw _Unavailable('HTTP ${response.statusCode}');
    }
    throw const _Unavailable('unexpected response');
  }
}

class _Unavailable implements Exception {
  const _Unavailable(this.reason);
  final String reason;
}
