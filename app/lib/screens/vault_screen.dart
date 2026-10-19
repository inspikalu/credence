import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/services.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/focus_ring.dart';
import '../widgets/page_frame.dart';
import '../widgets/skeleton.dart';

/// The public vault page: lists documents that are not revoked.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key, required this.vaultId});

  final String vaultId;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  Future<VaultPage>? _future;
  final _filter = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= Services.of(context).api.vault(widget.vaultId);
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _retry() =>
      setState(() => _future = Services.of(context).api.vault(widget.vaultId));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VaultPage>(
      future: _future,
      builder: (context, snap) {
        final page = snap.data;
        return Title(
          title: page == null
              ? 'Vault · Credence'
              : '${page.vault.name} · Credence vault',
          color: C.ledger,
          child: PageFrame(
            context: 'Vault',
            child: switch (snap.connectionState) {
              ConnectionState.done when page != null => _body(context, page),
              ConnectionState.done => _error(snap.error),
              _ => const VaultSkeleton(),
            },
          ),
        );
      },
    );
  }

  Widget _error(Object? error) {
    if (error is ApiException && error.isNotFound) {
      return const NotFoundView(
        title: 'No vault at this link',
        message:
            'Check that the link was copied in full. If it was, the vault may '
            'never have existed on this server.',
      );
    }
    return ErrorView(
      title: 'Could not load this vault',
      message: error is ApiException ? error.message : 'Try again in a moment.',
      onRetry: _retry,
    );
  }

  Widget _body(BuildContext context, VaultPage page) {
    final vault = page.vault;
    final canManage = AccountScope.of(context).owns(vault.ownerAddress);
    final query = _filter.text.trim().toLowerCase();
    final docs = query.isEmpty
        ? page.documents
        : page.documents
              .where(
                (d) =>
                    d.title.toLowerCase().contains(query) ||
                    d.recipientName.toLowerCase().contains(query) ||
                    d.issuerName.toLowerCase().contains(query),
              )
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: S.x8),
        VaultHeader(vault: vault),
        if (canManage) ...[
          const SizedBox(height: S.x3),
          TextButton.icon(
            onPressed: () => context.go('/v/${vault.id}/manage'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Manage this vault'),
          ),
        ],
        const SizedBox(height: S.x8),
        SectionTitle(
          'Documents',
          trailing: Text(
            plural(page.documents.length, 'document'),
            style: T.small,
          ),
        ),
        if (page.documents.length > 6) ...[
          TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Filter by name or title',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: S.x4),
        ],
        if (page.documents.isEmpty)
          const Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No documents yet', style: T.h3),
                SizedBox(height: S.x1),
                Text(
                  'The owner has not stored any documents in this vault.',
                  style: T.small,
                ),
              ],
            ),
          )
        else if (docs.isEmpty)
          Text('No documents match “${_filter.text.trim()}”.', style: T.small)
        else
          Container(
            decoration: BoxDecoration(
              color: C.surface,
              border: Border.all(color: C.rule),
              borderRadius: BorderRadius.circular(R.panel),
            ),
            child: Column(
              children: [
                for (var i = 0; i < docs.length; i++)
                  DocumentRow(document: docs[i], divider: i > 0),
              ],
            ),
          ),
        const SizedBox(height: S.x4),
        Text(
          vault.revokedCount > 0
              ? '${plural(vault.revokedCount, 'revoked document')} '
                    '${vault.revokedCount == 1 ? 'is' : 'are'} not listed. '
                    'Their check links still work and show the revocation.'
              : 'Revoked documents are not listed here. Their check links '
                    'still work and show the revocation.',
          style: T.small,
        ),
      ],
    );
  }
}

/// Vault name, kind, about text and website claim.
class VaultHeader extends StatelessWidget {
  const VaultHeader({super.key, required this.vault, this.compact = false});

  final Vault vault;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow('${vault.kind.label} vault', color: C.ledger),
        const SizedBox(height: S.x2),
        Semantics(header: true, child: Text(vault.name, style: T.h1(context))),
        if (vault.about.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
            child: Text(vault.about, style: T.bodyMuted),
          ),
        ],
        const SizedBox(height: S.x2),
        Text(
          'Created ${formatDate(vault.createdAt)} · '
          '${plural(vault.documentCount, 'listed document')}',
          style: T.small,
        ),
        if (vault.ownerAddress != null)
          OwnerAddressLine(address: vault.ownerAddress!),
        if (vault.website.isNotEmpty && !compact) ...[
          const SizedBox(height: S.x4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
            child: Notice(
              tone: Tone.info,
              title: 'Owner’s website: ${vault.website}',
              body:
                  'The owner says this vault is listed on that site. Credence '
                  'has not checked this. Visit the site to confirm the vault '
                  'is theirs.',
            ),
          ),
        ],
      ],
    );
  }
}

/// One document in a list.
class DocumentRow extends StatelessWidget {
  const DocumentRow({
    super.key,
    required this.document,
    this.divider = false,
    this.trailing,
    this.onTap,
  });

  final DocumentRecord document;
  final bool divider;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final d = document;
    final phone = Breakpoints.isPhone(context);
    final meta =
        'Issued by ${d.issuerName} to ${d.recipientName} · '
        '${formatIssueDate(d.issueDate)}';
    return Container(
      decoration: BoxDecoration(
        border: divider ? const Border(top: BorderSide(color: C.rule)) : null,
      ),
      child: FocusRing(
        radius: 0,
        inset: true,
        child: InkWell(
          onTap: onTap ?? () => context.go('/d/${d.id}'),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: phone ? S.x4 : S.x6,
              vertical: S.x4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    link: true,
                    linkUrl: Uri.parse('/d/${d.id}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: S.x2,
                          runSpacing: S.x1,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              d.title,
                              style: T.h3.copyWith(
                                fontFamily: Fonts.serif,
                                fontSize: 18,
                              ),
                            ),
                            Tag(d.typeLabel),
                            if (d.isRevoked)
                              const Tag(
                                'Revoked',
                                color: C.crimson,
                                fill: C.crimsonTint,
                              ),
                          ],
                        ),
                        const SizedBox(height: S.x1),
                        Text(meta, style: T.small),
                      ],
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: S.x2),
                  trailing!,
                ] else
                  const ExcludeSemantics(
                    child: Icon(Icons.chevron_right, color: C.inkMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
