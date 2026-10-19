import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/services.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../widgets/checks_panel.dart';
import '../widgets/common.dart';
import '../widgets/focus_ring.dart';
import '../widgets/dialogs.dart';
import '../widgets/page_frame.dart';
import '../widgets/skeleton.dart';
import '../widgets/preview.dart';
import '../widgets/qr_block.dart';

/// The check page for one document.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  Future<DocumentPage>? _future;
  DocumentPage? _page;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _fetch();
  }

  Future<DocumentPage> _fetch() async {
    final page = await Services.of(context).api.document(widget.documentId);
    _page = page;
    return page;
  }

  void _retry() => setState(() => _future = _fetch());

  void _updated(DocumentRecord document) {
    final page = _page;
    if (!mounted || page == null || document.id != widget.documentId) return;
    setState(() {
      _page = DocumentPage(document, page.vault);
      _future = Future.value(_page);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentPage>(
      future: _future,
      builder: (context, snap) {
        final page = snap.connectionState == ConnectionState.done
            ? (_page ?? snap.data)
            : null;
        final title = page == null
            ? 'Check a document · Credence'
            : '${page.document.isRevoked ? 'Revoked: ' : ''}'
                  '${page.document.title} · Credence';
        return Title(
          title: title,
          color: C.ledger,
          child: PageFrame(
            context: 'Check page',
            child: switch (snap.connectionState) {
              ConnectionState.done when page != null => _DocumentBody(
                page: page,
                onUpdated: _updated,
              ),
              ConnectionState.done => _error(snap.error),
              _ => const DocumentSkeleton(),
            },
          ),
        );
      },
    );
  }

  Widget _error(Object? error) {
    if (error is ApiException && error.isNotFound) {
      return const NotFoundView(
        title: 'No document at this link',
        message:
            'Check that the link or QR code was copied in full. If it was, '
            'this document was never stored on this Credence server.',
      );
    }
    return ErrorView(
      title: 'Could not load this record',
      message: error is ApiException ? error.message : 'Try again in a moment.',
      onRetry: _retry,
    );
  }
}

class _DocumentBody extends StatelessWidget {
  const _DocumentBody({required this.page, required this.onUpdated});

  final DocumentPage page;
  final ValueChanged<DocumentRecord> onUpdated;

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final doc = page.document;
    final vault = page.vault;
    final desktop = Breakpoints.isDesktop(context);
    final owner = AccountScope.of(context).owns(vault.ownerAddress);
    final url = services.links.document(doc.id);

    final header = _Header(document: doc, vault: vault);
    final preview = DocumentPreview(document: doc);
    final checks = Column(
      children: [
        CopyCheck(document: doc, vault: vault),
        const SizedBox(height: S.x4),
        StoredFileCheck(document: doc, vault: vault),
      ],
    );
    final details = TitledPanel(
      title: 'Details',
      subtitle: 'Entered by the vault owner.',
      child: _DetailsLedger(document: doc, vault: vault),
    );
    final storage = TitledPanel(
      title: 'Storage',
      child: _StorageLedger(document: doc, vault: vault),
    );
    final share = TitledPanel(
      title: 'Share',
      child: QrBlock(url: url, fileStem: 'credence-${doc.id}'),
    );
    final history = _History(document: doc);
    final admin = owner ? _OwnerBar(document: doc, onUpdated: onUpdated) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: S.x6),
        if (doc.isRevoked) ...[
          _RevokedBanner(document: doc),
          const SizedBox(height: S.x6),
        ],
        header,
        if (admin != null) ...[const SizedBox(height: S.x4), admin],
        const SizedBox(height: S.x8),
        if (desktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 7,
                child: Column(
                  children: [
                    preview,
                    const SizedBox(height: S.x6),
                    checks,
                  ],
                ),
              ),
              const SizedBox(width: S.x8),
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    details,
                    const SizedBox(height: S.x6),
                    storage,
                    const SizedBox(height: S.x6),
                    share,
                    const SizedBox(height: S.x6),
                    history,
                  ],
                ),
              ),
            ],
          )
        else ...[
          preview,
          const SizedBox(height: S.x6),
          checks,
          const SizedBox(height: S.x6),
          details,
          const SizedBox(height: S.x6),
          storage,
          const SizedBox(height: S.x6),
          share,
          const SizedBox(height: S.x6),
          history,
        ],
      ],
    );
  }
}

class _RevokedBanner extends StatelessWidget {
  const _RevokedBanner({required this.document});

  final DocumentRecord document;

  @override
  Widget build(BuildContext context) {
    final reason = document.revokeReason;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Notice(
        tone: Tone.danger,
        large: true,
        title:
            'Revoked by the vault owner on ${formatDate(document.revokedAt!)}',
        body:
            '${reason.isEmpty ? '' : 'Reason given: $reason. '}The owner no '
            'longer stands behind this document. The record stays visible so '
            'anyone holding a copy can see that.',
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.document, required this.vault});

  final DocumentRecord document;
  final Vault vault;

  @override
  Widget build(BuildContext context) {
    final d = document;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: S.x1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Eyebrow('Document record in', color: C.ledger),
            Semantics(
              link: true,
              linkUrl: Uri.parse('/v/${vault.id}'),
              child: FocusRing(
                child: InkWell(
                  onTap: () => context.go('/v/${vault.id}'),
                  // 14 + 16 + 14 = a 44 px hit target around the label.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 2,
                    ),
                    child: Text(
                      vault.name.toUpperCase(),
                      style: T.label.copyWith(
                        color: C.ledger,
                        decoration: TextDecoration.underline,
                        decorationColor: C.ledger,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // The link row already carries 14 px of hit-target padding.
        Semantics(header: true, child: Text(d.title, style: T.h1(context))),
        const SizedBox(height: S.x2),
        Text(
          'Issued by ${d.issuerName} to ${d.recipientName} on '
          '${formatIssueDate(d.issueDate)}',
          style: T.bodyMuted,
        ),
        if ((d.storedBy ?? vault.ownerAddress) != null)
          OwnerAddressLine(
            address: (d.storedBy ?? vault.ownerAddress)!,
            prefix: 'Stored by',
          )
        else
          const SizedBox(height: S.x3),
        Wrap(
          spacing: S.x2,
          runSpacing: S.x2,
          children: [
            Tag(d.typeLabel),
            Tag('${vault.kind.label} vault'),
            if (d.isRevoked)
              const Tag('Revoked', color: C.crimson, fill: C.crimsonTint)
            else
              const Tag('Not revoked', color: C.ledger),
          ],
        ),
      ],
    );
  }
}

class _OwnerBar extends StatelessWidget {
  const _OwnerBar({required this.document, required this.onUpdated});

  final DocumentRecord document;
  final ValueChanged<DocumentRecord> onUpdated;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x1),
    decoration: BoxDecoration(
      border: Border.all(color: C.rule),
      borderRadius: BorderRadius.circular(R.control),
      color: C.surface,
    ),
    child: Wrap(
      spacing: S.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('You own this vault.', style: T.small),
        TextButton(
          onPressed: () async {
            final updated = await showEditDocumentDialog(
              context,
              document: document,
            );
            if (updated != null) onUpdated(updated);
          },
          child: const Text('Edit details'),
        ),
        if (!document.isRevoked)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: C.crimson),
            onPressed: () async {
              final updated = await showRevokeDialog(
                context,
                document: document,
              );
              if (updated != null) onUpdated(updated);
            },
            child: const Text('Revoke'),
          ),
      ],
    ),
  );
}

class _DetailsLedger extends StatelessWidget {
  const _DetailsLedger({required this.document, required this.vault});

  final DocumentRecord document;
  final Vault vault;

  @override
  Widget build(BuildContext context) {
    final d = document;
    return Ledger(
      labelWidth: 120,
      rows: [
        LedgerRow('Title', Text(d.title, style: T.body)),
        LedgerRow('Issued by', Text(d.issuerName, style: T.body)),
        LedgerRow('Issued to', Text(d.recipientName, style: T.body)),
        LedgerRow(
          'Issue date',
          Text(formatIssueDate(d.issueDate), style: T.body),
        ),
        if (d.notes.isNotEmpty)
          LedgerRow('Notes', Text(d.notes, style: T.body)),
        LedgerRow(
          'Vault',
          Text(
            '${vault.name} (${vault.kind.label.toLowerCase()})',
            style: T.body,
          ),
        ),
        LedgerRow(
          'File',
          Text(
            '${d.fileName}\n${d.typeLabel} · ${formatBytes(d.sizeBytes)}',
            style: T.body,
          ),
        ),
      ],
    );
  }
}

class _StorageLedger extends StatelessWidget {
  const _StorageLedger({required this.document, required this.vault});

  final DocumentRecord document;
  final Vault vault;

  @override
  Widget build(BuildContext context) {
    final d = document;
    final endsAround = d.estimatedExpiresAt;
    final network = switch (d.network) {
      'mainnet' => 'Walrus Mainnet',
      'testnet' => 'Walrus Testnet',
      _ => 'Walrus',
    };
    final mayHaveEnded =
        endsAround != null && endsAround.isBefore(DateTime.now().toUtc());
    // The payer, from the Blob object on Sui; older records fall back to the
    // vault owner (the publisher sent the object there).
    final storedBy = d.storedBy ?? vault.ownerAddress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Ledger(
          labelWidth: 120,
          rows: [
            LedgerRow('Stored on', Text(network, style: T.body)),
            LedgerRow(
              'Uploaded',
              Text(formatDateTime(d.uploadedAt), style: T.body),
            ),
            LedgerRow(
              'Blob ID',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableValue(d.blobId, style: T.monoSmall),
                  CopyButton(
                    text: d.blobId,
                    compact: true,
                    label: 'Copy blob ID',
                  ),
                ],
              ),
            ),
            LedgerRow(
              'SHA-256',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FingerprintText(d.sha256, style: T.monoSmall),
                  CopyButton(
                    text: d.sha256,
                    compact: true,
                    label: 'Copy fingerprint',
                  ),
                ],
              ),
            ),
            if (storedBy != null)
              LedgerRow(
                'Stored by',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableValue(storedBy, style: T.monoSmall),
                    Text(
                      d.storedBy != null
                          ? 'The Sui address that paid for storage. It owns '
                                'the blob object on Walrus.'
                          : 'The Sui address that owns this vault. The blob '
                                'object on Walrus was sent to it.',
                      style: T.small,
                    ),
                    CopyButton(
                      text: storedBy,
                      compact: true,
                      label: 'Copy address',
                      semanticLabel: 'Copy the owner\'s Sui address',
                    ),
                  ],
                ),
              ),
            if (d.blobObjectId != null)
              LedgerRow(
                'Blob object',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableValue(d.blobObjectId!, style: T.monoSmall),
                    CopyButton(
                      text: d.blobObjectId!,
                      compact: true,
                      label: 'Copy object ID',
                    ),
                  ],
                ),
              ),
            LedgerRow(
              'Paid until',
              Text(
                d.endEpoch == null
                    ? 'Not recorded'
                    : 'Epoch ${d.endEpoch}'
                          '${endsAround == null ? '' : ' (about ${formatDate(endsAround)})'}',
                style: T.body,
              ),
            ),
          ],
        ),
        const SizedBox(height: S.x3),
        if (mayHaveEnded)
          const Notice(
            tone: Tone.warning,
            title: 'Storage may have ended',
            body:
                'The paid storage period has probably passed. If the stored '
                'file cannot be fetched, a copy can no longer be checked here.',
          )
        else
          Text(
            'The file stays on Walrus until its storage period ends, or until '
            'the owner deletes the blob with their wallet. Revoking a '
            'document does not delete the file.',
            style: T.small,
          ),
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.document});

  final DocumentRecord document;

  @override
  Widget build(BuildContext context) {
    final edits = document.edits;
    return TitledPanel(
      title: 'Edit history',
      subtitle: edits.isEmpty
          ? 'No details have changed since the file was stored.'
          : 'Details changed ${plural(edits.length, 'time')}. The file '
                'itself cannot change.',
      child: edits.isEmpty
          ? Text(
              'Stored ${formatDateTime(document.uploadedAt)}.',
              style: T.small,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in edits)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: C.rule)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(formatDateTime(e.editedAt), style: T.label),
                        const SizedBox(height: S.x1),
                        Text('“${e.note}”', style: T.body),
                        const SizedBox(height: S.x1),
                        for (final c in e.changes)
                          Text(
                            '${c.label} changed from '
                            '“${c.from.isEmpty ? '(empty)' : c.from}” to '
                            '“${c.to.isEmpty ? '(empty)' : c.to}”',
                            style: T.small,
                          ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.only(top: S.x3),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: C.rule)),
                  ),
                  width: double.infinity,
                  child: Text(
                    'Stored ${formatDateTime(document.uploadedAt)}.',
                    style: T.small,
                  ),
                ),
              ],
            ),
    );
  }
}
