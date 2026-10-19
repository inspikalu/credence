import 'dart:convert';
import 'dart:typed_data';

import 'address.dart';

/// A "Sign in with Sui" message, modelled on EIP-4361 (Sign in with
/// Ethereum) and CAIP-122, so wallets show plain, readable text:
///
/// ```text
/// lectern.example wants you to sign in with your Sui account:
/// 0x1c5d…e9a1
///
/// Sign in to Lectern. This does not send a transaction or cost gas.
///
/// URI: https://lectern.example
/// Version: 1
/// Chain ID: sui:testnet
/// Nonce: 4f1c3a9b2d7e6f8a0b1c2d3e4f5a6b7c
/// Issued At: 2026-10-15T12:00:00.000Z
/// Expiration Time: 2026-10-15T12:10:00.000Z
/// ```
///
/// Optional trailing fields, in this order: `Not Before`, `Request ID`,
/// `Resources` (one `- <uri>` line each). Without a statement the address is
/// followed by two empty lines, as in EIP-4361.
class SuiSignInMessage {
  SuiSignInMessage({
    required this.domain,
    required this.address,
    this.statement,
    required this.uri,
    this.version = '1',
    required this.chainId,
    required this.nonce,
    required this.issuedAt,
    this.expirationTime,
    this.notBefore,
    this.requestId,
    this.resources = const [],
  }) {
    _validate();
  }

  /// `host` or `host:port` that asks for the sign-in (no scheme).
  final String domain;

  /// Full-length lowercase Sui address of the signer.
  final String address;

  /// One human-readable line, or null.
  final String? statement;

  /// Absolute URI of the site (usually its origin).
  final Uri uri;
  final String version;

  /// Wallet Standard chain id, for example `sui:testnet`.
  final String chainId;
  final String nonce;
  final DateTime issuedAt;
  final DateTime? expirationTime;
  final DateTime? notBefore;
  final String? requestId;
  final List<Uri> resources;

  static const _header = ' wants you to sign in with your Sui account:';

  static final _domain = RegExp(
    r'^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*'
    r'|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?$',
  );
  static final _nonce = RegExp(r'^[A-Za-z0-9]{8,128}$');
  static final _chain = RegExp(r'^sui:[a-z0-9-]{1,32}$');
  static final _timestamp = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$',
  );

  void _validate() {
    if (!_domain.hasMatch(domain)) {
      throw SuiSignInMessageFormatException('Invalid domain: $domain');
    }
    if (!isCanonicalSuiAddress(address)) {
      throw SuiSignInMessageFormatException(
        'Address must be 0x followed by 64 lowercase hex digits',
      );
    }
    final s = statement;
    if (s != null &&
        (s.isEmpty ||
            s.length > 500 ||
            s.contains('\n') ||
            s.contains('\r') ||
            s.startsWith('URI: '))) {
      throw SuiSignInMessageFormatException(
        'Statement must be one non-empty line',
      );
    }
    _checkUri(uri, 'URI');
    if (version != '1') {
      throw SuiSignInMessageFormatException('Unsupported version: $version');
    }
    if (!_chain.hasMatch(chainId)) {
      throw SuiSignInMessageFormatException('Invalid chain id: $chainId');
    }
    if (!_nonce.hasMatch(nonce)) {
      throw SuiSignInMessageFormatException(
        'Nonce must be 8 to 128 letters and digits',
      );
    }
    final r = requestId;
    if (r != null && (r.isEmpty || r.contains('\n') || r.contains('\r'))) {
      throw SuiSignInMessageFormatException('Request ID must be one line');
    }
    for (final resource in resources) {
      _checkUri(resource, 'Resource');
    }
  }

  static void _checkUri(Uri value, String label) {
    final text = value.toString();
    if (!value.isAbsolute && !value.hasScheme) {
      throw SuiSignInMessageFormatException('$label must be an absolute URI');
    }
    if (text.contains('\n') || text.contains('\r') || text.contains(' ')) {
      throw SuiSignInMessageFormatException('$label must be one line');
    }
  }

  /// The exact text the wallet shows and signs.
  String toMessage() {
    final lines = <String>[
      '$domain$_header',
      address,
      '',
      if (statement != null) ...[statement!, ''] else '',
      'URI: $uri',
      'Version: $version',
      'Chain ID: $chainId',
      'Nonce: $nonce',
      'Issued At: ${formatTimestamp(issuedAt)}',
      if (expirationTime != null)
        'Expiration Time: ${formatTimestamp(expirationTime!)}',
      if (notBefore != null) 'Not Before: ${formatTimestamp(notBefore!)}',
      if (requestId != null) 'Request ID: $requestId',
      if (resources.isNotEmpty) ...[
        'Resources:',
        for (final r in resources) '- $r',
      ],
    ];
    return lines.join('\n');
  }

  /// UTF-8 bytes of [toMessage], ready for `sui:signPersonalMessage`.
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toMessage()));

  @override
  String toString() => toMessage();

  /// Parses a message produced by [toMessage] (or by another implementation
  /// of the same format). Throws [SuiSignInMessageFormatException].
  static SuiSignInMessage parse(String text) {
    if (text.contains('\r')) {
      throw SuiSignInMessageFormatException('Use \\n line endings only');
    }
    final lines = text.split('\n');
    var i = 0;
    String next(String what) {
      if (i >= lines.length) {
        throw SuiSignInMessageFormatException('Missing $what');
      }
      return lines[i++];
    }

    final header = next('header');
    if (!header.endsWith(_header)) {
      throw SuiSignInMessageFormatException('Not a Sign in with Sui message');
    }
    final domain = header.substring(0, header.length - _header.length);
    final address = next('address');
    if (next('blank line') != '') {
      throw SuiSignInMessageFormatException('Expected a blank line');
    }
    String? statement;
    final afterBlank = next('statement or blank line');
    if (afterBlank.isNotEmpty) {
      statement = afterBlank;
      if (next('blank line') != '') {
        throw SuiSignInMessageFormatException(
          'Expected a blank line after the statement',
        );
      }
    }

    String field(String name) {
      final line = next(name);
      final prefix = '$name: ';
      if (!line.startsWith(prefix)) {
        throw SuiSignInMessageFormatException('Expected "$name"');
      }
      return line.substring(prefix.length);
    }

    String? optional(String name) {
      if (i < lines.length && lines[i].startsWith('$name: ')) {
        return field(name);
      }
      return null;
    }

    final uri = _parseUri(field('URI'), 'URI');
    final version = field('Version');
    final chainId = field('Chain ID');
    final nonce = field('Nonce');
    final issuedAt = parseTimestamp(field('Issued At'));
    final expiration = optional('Expiration Time');
    final notBefore = optional('Not Before');
    final requestId = optional('Request ID');
    final resources = <Uri>[];
    if (i < lines.length && lines[i] == 'Resources:') {
      i++;
      while (i < lines.length && lines[i].startsWith('- ')) {
        resources.add(_parseUri(lines[i++].substring(2), 'Resource'));
      }
      if (resources.isEmpty) {
        throw SuiSignInMessageFormatException('Empty Resources list');
      }
    }
    if (i != lines.length) {
      throw SuiSignInMessageFormatException('Unexpected line: ${lines[i]}');
    }

    return SuiSignInMessage(
      domain: domain,
      address: address,
      statement: statement,
      uri: uri,
      version: version,
      chainId: chainId,
      nonce: nonce,
      issuedAt: issuedAt,
      expirationTime: expiration == null ? null : parseTimestamp(expiration),
      notBefore: notBefore == null ? null : parseTimestamp(notBefore),
      requestId: requestId,
      resources: resources,
    );
  }

  /// Like [parse], but returns null instead of throwing.
  static SuiSignInMessage? tryParse(String text) {
    try {
      return parse(text);
    } on SuiSignInMessageFormatException {
      return null;
    }
  }

  static Uri _parseUri(String text, String label) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      throw SuiSignInMessageFormatException('$label must be an absolute URI');
    }
    return uri;
  }

  /// RFC 3339 in UTC with milliseconds, for example
  /// `2026-10-15T12:00:00.000Z`.
  static String formatTimestamp(DateTime time) {
    final t = time.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-'
        '${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}Z';
  }

  /// Parses an RFC 3339 timestamp that has a time zone.
  static DateTime parseTimestamp(String text) {
    if (!_timestamp.hasMatch(text)) {
      throw SuiSignInMessageFormatException('Invalid timestamp: $text');
    }
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      throw SuiSignInMessageFormatException('Invalid timestamp: $text');
    }
    return parsed.toUtc();
  }
}

class SuiSignInMessageFormatException implements Exception {
  SuiSignInMessageFormatException(this.message);
  final String message;

  @override
  String toString() => 'SuiSignInMessageFormatException: $message';
}
