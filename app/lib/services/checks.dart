import '../models/models.dart';
import '../util/format.dart';

/// Where the checked bytes came from.
enum CheckSource {
  /// Fetched from Walrus by blob ID.
  stored,

  /// A file the person has, hashed on their device.
  copy,
}

/// The outcome of comparing a computed fingerprint with the record.
class CheckResult {
  const CheckResult({
    required this.source,
    required this.expected,
    required this.computed,
    required this.sizeBytes,
    required this.checkedAt,
    this.fileName,
  });

  final CheckSource source;
  final String expected;
  final String computed;
  final int sizeBytes;
  final DateTime checkedAt;
  final String? fileName;

  bool get match => expected.toLowerCase() == computed.toLowerCase();
}

/// Plain-language meaning of a [CheckResult]. Kept in one place so the
/// wording stays honest: a match proves the bytes are identical to what the
/// vault owner stored, nothing more.
class Explanation {
  const Explanation({
    required this.headline,
    required this.summary,
    required this.shows,
    required this.doesNotShow,
    this.issuerNote,
    this.websiteNote,
  });

  final String headline;
  final String summary;
  final List<String> shows;
  final List<String> doesNotShow;
  final String? issuerNote;
  final String? websiteNote;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Whether the vault name matches the issuer name (ignoring case and
/// punctuation). This is a hint for wording only, never proof.
bool vaultNameMatchesIssuer(Vault vault, DocumentRecord doc) =>
    _norm(vault.name).isNotEmpty && _norm(vault.name) == _norm(doc.issuerName);

Explanation explain(CheckResult result, DocumentRecord doc, Vault vault) {
  final stored = formatDate(doc.uploadedAt);
  final owner = '“${vault.name}”';
  final revoked = doc.revokedAt;
  final revokedNote = revoked == null
      ? ''
      : ' The vault owner revoked this document on ${formatDate(revoked)}.';

  final doesNotShow = <String>[
    'That ${doc.issuerName} issued it. Credence does not check who runs a '
        'vault or who issued a document.',
    'That the details on this page are true. The vault owner typed them in.',
  ];

  final String issuerNote;
  if (vaultNameMatchesIssuer(vault, doc)) {
    issuerNote =
        'This vault is named $owner, the same as the issuer. If you know '
        '${doc.issuerName} runs this vault, for example because they gave you '
        'this link or list it on their own website, a match also shows the '
        'file came from them.';
  } else {
    issuerNote =
        'This vault is run by $owner, not necessarily by ${doc.issuerName}. '
        'A match shows the file came from ${doc.issuerName} only if you know '
        'the issuer runs this vault.';
  }
  final websiteNote = vault.website.isEmpty
      ? null
      : 'The vault owner says this vault is listed on ${vault.website}. '
            'Credence has not checked that. Visit the site to confirm.';

  if (result.source == CheckSource.copy) {
    if (result.match) {
      return Explanation(
        headline: revoked == null ? 'Match' : 'Match, but revoked',
        summary:
            'This file is identical, byte for byte, to the file the owner of '
            '$owner stored on $stored.$revokedNote',
        shows: [
          'Your copy is the same file this record describes.',
          'It has not changed by a single byte since $stored.',
        ],
        doesNotShow: doesNotShow,
        issuerNote: issuerNote,
        websiteNote: websiteNote,
      );
    }
    return Explanation(
      headline: 'No match',
      summary:
          'This file is not the file stored in this vault. Its fingerprint '
          'is different.$revokedNote',
      shows: ['Your copy differs from the stored file by at least one byte.'],
      doesNotShow: [
        'That your copy is forged. Re-saving, compressing, scanning or '
            'printing to PDF also changes the fingerprint.',
        'Which part changed. Compare it with the stored file by eye, or ask '
            'the sender for the original file.',
      ],
    );
  }

  if (result.match) {
    return Explanation(
      headline: 'Stored file matches the record',
      summary:
          'The file Walrus returned has the same SHA-256 fingerprint as this '
          'record. It is the file the owner of $owner stored on $stored.'
          '$revokedNote',
      shows: [
        'The file on Walrus has not changed since it was stored.',
        'The preview on this page shows that same file.',
      ],
      doesNotShow: doesNotShow,
      issuerNote: issuerNote,
      websiteNote: websiteNote,
    );
  }
  return Explanation(
    headline: 'Stored file does not match',
    summary:
        'The file Walrus returned has a different fingerprint from this '
        'record. Do not rely on this record until the vault owner explains '
        'it.$revokedNote',
    shows: ['The bytes Walrus returned are not the bytes this record names.'],
    doesNotShow: ['Who changed what. Ask the vault owner to check the upload.'],
  );
}
