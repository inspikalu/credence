import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';
import 'package:upload_recovery/pending_uploads_panel.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/services.dart';
import '../services/account.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/dialogs.dart';
import '../widgets/page_frame.dart';
import '../widgets/sign_in.dart';
import '../widgets/skeleton.dart';
import '../widgets/upload_panel.dart';
import 'vault_screen.dart';

/// Manage a vault: add documents, edit and revoke. Only the Sui address
/// that owns the vault gets past the sign-in check.
class ManageScreen extends StatefulWidget {
  const ManageScreen({
    super.key,
    required this.vaultId,
    this.justCreated = false,
  });

  final String vaultId;
  final bool justCreated;

  @override
  State<ManageScreen> createState() => _ManageScreenState();
}

class _ManageScreenState extends State<ManageScreen> {
  VaultPage? _page;
  ApiException? _error;
  bool _loading = false;
  late bool _showWelcome = widget.justCreated;

  /// The address the current page (or error) was loaded for.
  String? _loadedFor;
  String? _pageOwner;
  int _loadGeneration = 0;
  int _recoveryRefresh = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload authorization when the session changes. Keep the old upload
    // mounted but hidden so the same owner can resume after signing in.
    final account = AccountScope.of(context);
    final address = account.address;
    if (address != _loadedFor) {
      _loadGeneration++;
      _loadedFor = address;
      _error = null;
      if (address != null) {
        _loading = true;
        // Start after this frame: _load calls setState.
        Future.microtask(_load);
      } else {
        _loading = false;
      }
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final services = Services.of(context);
    final forAddress = services.account.address;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await services.api.vaultForOwner(widget.vaultId);
      if (!mounted ||
          generation != _loadGeneration ||
          services.account.address != forAddress) {
        return;
      }
      setState(() {
        _page = page;
        _pageOwner = forAddress;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted ||
          generation != _loadGeneration ||
          services.account.address != forAddress) {
        return;
      }
      if (e.isSignedOut) {
        // The session ended (expired, or signed out in another tab).
        services.account.sessionEnded();
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _replaceDocument(DocumentRecord updated) {
    final page = _page;
    if (page == null) return;
    setState(() {
      final documents = [
        for (final d in page.documents) d.id == updated.id ? updated : d,
      ];
      _page = VaultPage(
        page.vault.copyWith(
          documentCount: documents.where((d) => d.revokedAt == null).length,
          revokedCount: documents.where((d) => d.revokedAt != null).length,
        ),
        documents,
      );
    });
  }

  void _addDocument(DocumentRecord created) {
    final page = _page;
    if (page == null) return;
    final v = page.vault;
    setState(() {
      _page = VaultPage(v.copyWith(documentCount: v.documentCount + 1), [
        created,
        ...page.documents,
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final account = AccountScope.of(context);
    final canManage =
        page != null &&
        account.signedIn &&
        account.address == _pageOwner &&
        !_loading &&
        _error == null;
    return Title(
      title: !canManage
          ? 'Manage vault · Credence'
          : 'Manage ${page.vault.name} · Credence',
      color: C.ledger,
      child: PageFrame(
        context: 'Manage',
        child: Column(
          children: [
            if (page != null)
              TickerMode(
                enabled: canManage,
                child: Offstage(
                  offstage: !canManage,
                  child: ExcludeFocus(
                    excluding: !canManage,
                    child: KeyedSubtree(
                      key: ValueKey(_pageOwner),
                      child: _body(context, page, canManage: canManage),
                    ),
                  ),
                ),
              ),
            if (!canManage)
              Builder(
                builder: (context) {
                  final account = AccountScope.of(context);
                  if (!account.checked || _loading) {
                    return const VaultSkeleton(label: 'Opening vault');
                  }
                  if (!account.signedIn) {
                    return _SignInToManage(vaultId: widget.vaultId);
                  }
                  final error = _error;
                  if (error != null) {
                    if (error.isNotFound) {
                      return const NotFoundView(
                        title: 'No vault at this link',
                        message: 'Check that the link was copied in full.',
                      );
                    }
                    if (error.isForbidden) {
                      return _NotYourVault(
                        vaultId: widget.vaultId,
                        address: account.address!,
                      );
                    }
                    return ErrorView(
                      title: 'Could not open this vault',
                      message: error.message,
                      onRetry: _load,
                    );
                  }
                  return const VaultSkeleton(label: 'Opening vault');
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    VaultPage page, {
    required bool canManage,
  }) {
    final services = Services.of(context);
    final vault = page.vault;
    final links = services.links;
    final recoveryOwner = _pageOwner;

    final share = LinkField(
      label: 'Public vault link',
      url: links.vault(vault.id),
      help: 'Anyone with this link sees the documents that are not revoked.',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: S.x8),
        if (_showWelcome) ...[
          Notice(
            tone: Tone.success,
            large: true,
            title: 'Vault created',
            body:
                'It belongs to your Sui address '
                '${shortAddress(services.account.address ?? '')}. Sign in '
                'with the same wallet on any device to manage it. Share the '
                'public link below with anyone who needs to check your '
                'documents.',
            action: FilledButton(
              onPressed: () => setState(() => _showWelcome = false),
              child: const Text('Got it'),
            ),
          ),
          const SizedBox(height: S.x8),
        ],
        Wrap(
          spacing: S.x6,
          runSpacing: S.x4,
          crossAxisAlignment: WrapCrossAlignment.end,
          alignment: WrapAlignment.spaceBetween,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: VaultHeader(vault: vault, compact: true),
            ),
            Wrap(
              spacing: S.x2,
              runSpacing: S.x2,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.go('/v/${vault.id}'),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View public page'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final forAddress = services.account.address;
                    final updated = await showEditVaultDialog(
                      context,
                      vault: vault,
                    );
                    if (updated != null &&
                        mounted &&
                        services.account.address == forAddress) {
                      setState(
                        () => _page = VaultPage(updated, page.documents),
                      );
                    }
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit vault details'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: S.x8),
        if (services.recovery != null && recoveryOwner != null)
          PendingUploadsPanel(
            recovery: services.recovery!,
            owner: recoveryOwner,
            filter: (job) => job.metadata['vaultId'] == vault.id,
            canContinue: () =>
                mounted && services.account.address == recoveryOwner,
            beforeResume: () async {
              if (!services.account.wallet.isConnected) {
                await showSuiWalletPicker(
                  context,
                  controller: services.account.wallet,
                );
              }
              return mounted && services.account.address == recoveryOwner;
            },
            onCompleted: (_, _) async {
              if (mounted) setState(() => _recoveryRefresh++);
              await _load();
            },
          ),
        UploadPanel(
          key: ValueKey(_recoveryRefresh),
          vault: vault,
          onCreated: _addDocument,
          enabled: canManage,
        ),
        const SizedBox(height: S.x6),
        TitledPanel(title: 'Share', child: share),
        const SizedBox(height: S.x12),
        SectionTitle(
          'Documents in this vault',
          trailing: Text(
            '${vault.documentCount} listed · ${vault.revokedCount} revoked',
            style: T.small,
          ),
        ),
        if (page.documents.isEmpty)
          const Text(
            'Nothing stored yet. Add the first document above.',
            style: T.small,
          )
        else
          Container(
            decoration: BoxDecoration(
              color: C.surface,
              border: Border.all(color: C.rule),
              borderRadius: BorderRadius.circular(R.panel),
            ),
            child: Column(
              children: [
                for (var i = 0; i < page.documents.length; i++)
                  DocumentRow(
                    document: page.documents[i],
                    divider: i > 0,
                    trailing: _DocumentActions(
                      document: page.documents[i],
                      onChanged: _replaceDocument,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: S.x4),
        Text(
          'Revoking removes a document from the public list and marks its '
          'check page as revoked. The file stays on '
          '${services.config.networkLabel} until its storage period ends. '
          'Its blob object belongs to your address, so only your wallet could '
          'delete it early; Credence never does.',
          style: T.small,
        ),
      ],
    );
  }
}

class _DocumentActions extends StatelessWidget {
  const _DocumentActions({required this.document, required this.onChanged});

  final DocumentRecord document;
  final ValueChanged<DocumentRecord> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Actions for ${document.title}',
      popUpAnimationStyle: Motion.reduced(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Motion.quick,
              reverseDuration: Motion.exit,
            ),
      icon: const Icon(Icons.more_horiz),
      onSelected: (action) async {
        final account = Services.of(context).account;
        final forAddress = account.address;
        switch (action) {
          case 'open':
            context.go('/d/${document.id}');
          case 'edit':
            final updated = await showEditDocumentDialog(
              context,
              document: document,
            );
            if (updated != null &&
                context.mounted &&
                account.address == forAddress) {
              onChanged(updated);
            }
          case 'revoke':
            final updated = await showRevokeDialog(context, document: document);
            if (updated != null &&
                context.mounted &&
                account.address == forAddress) {
              onChanged(updated);
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'open', child: Text('Open check page')),
        const PopupMenuItem(value: 'edit', child: Text('Edit details')),
        if (!document.isRevoked)
          const PopupMenuItem(
            value: 'revoke',
            child: Text('Revoke', style: TextStyle(color: C.crimson)),
          ),
      ],
    );
  }
}

/// Shown on the manage page when nobody is signed in.
class _SignInToManage extends StatelessWidget {
  const _SignInToManage({required this.vaultId});

  final String vaultId;

  @override
  Widget build(BuildContext context) => _Gate(
    eyebrow: 'Manage vault',
    title: 'Sign in to manage this vault',
    body:
        'Only the Sui address that owns this vault can add, edit or revoke '
        'its documents. Sign in with that wallet. Checking a document never '
        'needs a wallet.',
    actions: [
      const SignInButton(),
      OutlinedButton(
        onPressed: () => context.go('/v/$vaultId'),
        child: const Text('View public page'),
      ),
    ],
  );
}

/// Shown when the signed-in address does not own the vault.
class _NotYourVault extends StatelessWidget {
  const _NotYourVault({required this.vaultId, required this.address});

  final String vaultId;
  final String address;

  @override
  Widget build(BuildContext context) {
    final account = Services.of(context).account;
    return _Gate(
      eyebrow: 'Manage vault',
      title: 'This vault belongs to another account',
      body:
          'You are signed in as ${shortAddress(address)}, which does not own '
          'this vault. If you created it with another wallet or account, sign '
          'out and sign in with that one.',
      actions: [
        OutlinedButton(
          onPressed: () => context.go('/v/$vaultId'),
          child: const Text('View public page'),
        ),
        TextButton(
          onPressed: () async {
            final signedOut = await account.signOut();
            if (!signedOut && context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(account.signOutError!)));
            }
          },
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.actions,
  });

  final String eyebrow;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(eyebrow),
            const SizedBox(height: S.x2),
            Semantics(header: true, child: Text(title, style: T.h1(context))),
            const SizedBox(height: S.x3),
            Text(body, style: T.bodyMuted),
            const SizedBox(height: S.x6),
            Wrap(spacing: S.x3, runSpacing: S.x3, children: actions),
          ],
        ),
      ),
    ),
  );
}
