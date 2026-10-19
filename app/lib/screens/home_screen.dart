import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../services/account.dart';
import '../services/api_client.dart';
import '../services/services.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import '../widgets/focus_ring.dart';
import '../widgets/page_frame.dart';
import '../widgets/sign_in.dart';
import '../widgets/skeleton.dart';

/// `/app`: the owner's vaults when signed in; otherwise what Credence is,
/// how to sign in as an owner, and how to open a check link (no wallet).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final account = AccountScope.of(context);
    final signedIn = account.signedIn;
    return Title(
      title: signedIn
          ? 'Your vaults · Credence'
          : 'Credence · Certificate vault',
      color: C.ledger,
      child: PageFrame(
        child: signedIn
            ? _OwnerHome(address: account.address!)
            : _Welcome(checking: !account.checked),
      ),
    );
  }
}

/// Signed out (or still checking the session).
class _Welcome extends StatelessWidget {
  const _Welcome({required this.checking});

  final bool checking;

  @override
  Widget build(BuildContext context) {
    final desktop = Breakpoints.isDesktop(context);
    final side = checking ? const _PanelSkeleton() : const _SignInPanel();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: desktop ? S.x12 : S.x8),
        if (desktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(flex: 6, child: _Intro()),
              const SizedBox(width: S.x12),
              Expanded(flex: 5, child: side),
            ],
          )
        else ...[
          const _Intro(),
          const SizedBox(height: S.x6),
          side,
        ],
        const SizedBox(height: S.x12),
        const _HowItWorks(),
        const SizedBox(height: S.x12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
          child: const _OpenLink(),
        ),
      ],
    );
  }
}

/// Signed in: the owner's vaults and the form to create another.
class _OwnerHome extends StatelessWidget {
  const _OwnerHome({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final desktop = Breakpoints.isDesktop(context);
    // Keyed by address so switching accounts reloads the list.
    final list = _MyVaults(key: ValueKey(address));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: desktop ? S.x12 : S.x8),
        const Eyebrow('Vault owner', color: C.ledger),
        const SizedBox(height: S.x2),
        Semantics(
          header: true,
          child: Text('Your vaults', style: T.display(context)),
        ),
        const SizedBox(height: S.x2),
        OwnerAddressLine(address: address, prefix: 'Signed in as'),
        const SizedBox(height: S.x8),
        if (desktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: list),
              const SizedBox(width: S.x12),
              const Expanded(flex: 5, child: CreateVaultPanel()),
            ],
          )
        else ...[
          list,
          const SizedBox(height: S.x8),
          const CreateVaultPanel(),
        ],
        const SizedBox(height: S.x12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
          child: const _OpenLink(),
        ),
        const SizedBox(height: S.x12),
        const _HowItWorks(),
      ],
    );
  }
}

class _SignInPanel extends StatelessWidget {
  const _SignInPanel();

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text('Create or manage a vault', style: T.h2(context)),
        ),
        const SizedBox(height: S.x2),
        const Text(
          'Vault owners sign in with a Sui wallet, such as Slush. A vault '
          'belongs to your wallet\'s address, so you can manage it from any '
          'device where you sign in.',
          style: T.small,
        ),
        const SizedBox(height: S.x6),
        const SizedBox(width: double.infinity, child: SignInButton()),
        const SizedBox(height: S.x6),
        const Divider(),
        const SizedBox(height: S.x4),
        const Text('Checking a document?', style: T.smallStrong),
        const SizedBox(height: S.x1),
        const Text(
          'You do not need a wallet or an account. Open the check link or '
          'scan the QR code you were given, or paste the link below.',
          style: T.small,
        ),
      ],
    ),
  );
}

class _PanelSkeleton extends StatelessWidget {
  const _PanelSkeleton();

  @override
  Widget build(BuildContext context) => const Panel(
    child: Skeleton(
      label: 'Checking whether you are signed in',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Bone(width: 220, height: 26),
          SizedBox(height: S.x3),
          Bone(height: 14),
          SizedBox(height: S.x2),
          Bone(width: 260, height: 14),
          SizedBox(height: S.x6),
          Bone(height: 44),
        ],
      ),
    ),
  );
}

/// The signed-in owner's vaults, from the server (any device).
class _MyVaults extends StatefulWidget {
  const _MyVaults({super.key});

  @override
  State<_MyVaults> createState() => _MyVaultsState();
}

class _MyVaultsState extends State<_MyVaults> {
  List<Vault>? _vaults;
  ApiException? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      Future.microtask(_load);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final services = Services.of(context);
    final forAddress = services.account.address;
    setState(() {
      _vaults = null;
      _error = null;
    });
    try {
      final vaults = await services.api.myVaults();
      if (mounted && services.account.address == forAddress) {
        setState(() => _vaults = vaults);
      }
    } on ApiException catch (e) {
      if (!mounted || services.account.address != forAddress) return;
      if (e.isSignedOut) {
        services.account.sessionEnded();
        return;
      }
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vaults = _vaults;
    final error = _error;
    if (error != null) {
      return ErrorView(
        title: 'Could not load your vaults',
        message: error.message,
        onRetry: _load,
      );
    }
    if (vaults == null) {
      return Skeleton(
        label: 'Loading your vaults',
        child: Column(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(height: S.x3),
              const Bone(height: 88, radius: R.panel),
            ],
          ],
        ),
      );
    }
    if (vaults.isEmpty) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No vaults yet', style: T.h3),
            const SizedBox(height: S.x1),
            const Text(
              'Create your first vault. It belongs to your address, and you '
              'can manage it from any device where you sign in with this '
              'wallet.',
              style: T.small,
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        border: Border.all(color: C.rule),
        borderRadius: BorderRadius.circular(R.panel),
      ),
      child: Column(
        children: [
          for (var i = 0; i < vaults.length; i++)
            _VaultRow(vault: vaults[i], divider: i > 0),
        ],
      ),
    );
  }
}

class _VaultRow extends StatelessWidget {
  const _VaultRow({required this.vault, required this.divider});

  final Vault vault;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final phone = Breakpoints.isPhone(context);
    final meta =
        '${vault.kind.label} vault · '
        '${plural(vault.documentCount, 'listed document')}'
        '${vault.revokedCount > 0 ? ' · ${vault.revokedCount} revoked' : ''}'
        ' · created ${formatDate(vault.createdAt)}';
    final actions = Wrap(
      spacing: S.x2,
      runSpacing: S.x2,
      children: [
        OutlinedButton(
          onPressed: () => context.go('/v/${vault.id}/manage'),
          child: Text('Manage', semanticsLabel: 'Manage ${vault.name}'),
        ),
        TextButton(
          onPressed: () => context.go('/v/${vault.id}'),
          child: Text(
            'Public page',
            semanticsLabel: 'Public page of ${vault.name}',
          ),
        ),
      ],
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(vault.name, style: T.h3),
        const SizedBox(height: S.x1),
        Text(meta, style: T.small),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        border: divider ? const Border(top: BorderSide(color: C.rule)) : null,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: phone ? S.x4 : S.x6,
        vertical: S.x4,
      ),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                const SizedBox(height: S.x3),
                actions,
              ],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: S.x4),
                actions,
              ],
            ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final config = Services.of(context).config;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: Breakpoints.maxProse),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Certificate vault', color: C.ledger),
          const SizedBox(height: S.x3),
          Semantics(
            header: true,
            child: Text(
              'Keep certificates where anyone can check them.',
              style: T.display(context),
            ),
          ),
          const SizedBox(height: S.x4),
          const Text(
            'Store course certificates, attendance records, awards and '
            'receipts. Each one gets a link and a QR code. Whoever opens it '
            'can check, in their own browser, that the file they hold is the '
            'one you stored.',
            style: T.bodyMuted,
          ),
          const SizedBox(height: S.x4),
          Wrap(
            spacing: S.x2,
            runSpacing: S.x2,
            children: [
              const Tag('PDF · PNG · JPEG · WebP'),
              Tag('Up to ${formatBytes(config.maxUploadBytes)}'),
              Tag('Stored on ${config.networkLabel}'),
            ],
          ),
          const SizedBox(height: S.x8),
          const Notice(
            tone: Tone.info,
            title: 'What a match proves, and what it does not',
            body:
                'A match proves a file is identical to the one the vault owner '
                'stored, on the date shown. It does not prove who issued it, '
                'unless you know the issuer runs the vault. Credence does not '
                'vouch for anyone.',
          ),
        ],
      ),
    );
  }
}

/// Form to create a personal or organization vault.
class CreateVaultPanel extends StatefulWidget {
  const CreateVaultPanel({super.key});

  @override
  State<CreateVaultPanel> createState() => _CreateVaultPanelState();
}

class _CreateVaultPanelState extends State<CreateVaultPanel> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _website = TextEditingController();
  VaultKind _kind = VaultKind.personal;
  bool _busy = false;
  String? _error;
  String? _nameError;
  String? _websiteError;

  @override
  void dispose() {
    _name.dispose();
    _website.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _nameError = null;
      _websiteError = null;
    });
    if (!(_form.currentState?.validate() ?? false)) return;
    final services = Services.of(context);
    setState(() => _busy = true);
    try {
      final created = await services.api.createVault(
        name: _name.text.trim(),
        kind: _kind,
        website: _website.text.trim(),
      );
      if (!mounted) return;
      context.go('/v/${created.id}/manage?new=1');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isSignedOut) {
        services.account.sessionEnded();
        return;
      }
      setState(() {
        _busy = false;
        if (e.field == 'name') {
          _nameError = e.message;
        } else if (e.field == 'website') {
          _websiteError = e.message;
        } else {
          _error = e.message;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final org = _kind == VaultKind.organization;
    return Panel(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('Create a vault', style: T.h2(context)),
            ),
            const SizedBox(height: S.x1),
            Text(
              'It belongs to your Sui address '
              '${shortAddress(Services.of(context).account.address ?? '')}. '
              'Anyone with its public link can check its documents.',
              style: T.small,
            ),
            const SizedBox(height: S.x6),
            const Eyebrow('Who is this vault for?'),
            const SizedBox(height: S.x2),
            KindToggle(
              value: _kind,
              onChanged: _busy ? null : (k) => setState(() => _kind = k),
            ),
            const SizedBox(height: S.x6),
            TextFormField(
              controller: _name,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: org ? 'Organization name' : 'Your name',
                hintText: org
                    ? 'e.g. Northgate Coding Club'
                    : 'e.g. Ada Okafor',
                errorText: _nameError,
                counterText: '',
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
              validator: (v) => (v ?? '').trim().length < 2
                  ? (org ? 'Enter the organization name.' : 'Enter your name.')
                  : null,
            ),
            const SizedBox(height: S.x4),
            TextFormField(
              controller: _website,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Website (optional)',
                hintText: org
                    ? 'e.g. northgate.example'
                    : 'e.g. adaokafor.example',
                helperText:
                    'Link to this vault from your own site so checkers can '
                    'tell it is yours. Credence does not check this.',
                errorText: _websiteError,
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: S.x4),
              Notice(tone: Tone.danger, title: 'Not created', body: _error),
            ],
            const SizedBox(height: S.x6),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: C.inkMuted,
                          semanticsLabel: 'Creating vault',
                        ),
                      )
                    : const Text('Create vault'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-option toggle for the vault kind.
class KindToggle extends StatelessWidget {
  const KindToggle({super.key, required this.value, required this.onChanged});

  final VaultKind value;
  final ValueChanged<VaultKind>? onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(VaultKind kind, String title, String sub) {
      final selected = value == kind;
      return Expanded(
        child: Semantics(
          inMutuallyExclusiveGroup: true,
          checked: selected,
          button: true,
          label: '$title vault. $sub',
          excludeSemantics: true,
          child: FocusRing(
            child: InkWell(
              onTap: onChanged == null ? null : () => onChanged!(kind),
              borderRadius: BorderRadius.circular(R.control),
              child: AnimatedContainer(
                duration: Motion.of(context, Motion.quick),
                padding: const EdgeInsets.all(S.x3),
                decoration: BoxDecoration(
                  color: selected ? C.mint : C.surface,
                  border: Border.all(
                    color: selected ? C.ledger : C.control,
                    width: selected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(R.control),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected ? C.ledger : C.inkMuted,
                    ),
                    const SizedBox(width: S.x2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: T.smallStrong),
                          Text(sub, style: T.small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        option(VaultKind.personal, 'Personal', 'Your own documents'),
        const SizedBox(width: S.x3),
        option(VaultKind.organization, 'Organization', 'Documents you issue'),
      ],
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final steps = [
      (
        'You store the file',
        'Your browser computes its SHA-256 fingerprint, a 64-character code '
            'that only these exact bytes produce, and saves it with the record. '
            'The file goes to Walrus.',
      ),
      (
        'You share the link',
        'Each document gets a check page with a QR code. If you revoke a '
            'document, its page says so and stays visible.',
      ),
      (
        'Anyone checks a copy',
        'They drop the file they received on the check page. It is hashed on '
            'their device and never uploaded. Same fingerprint, same file.',
      ),
    ];
    final desktop = Breakpoints.isDesktop(context);
    final cards = [
      for (var i = 0; i < steps.length; i++)
        _Step(number: i + 1, title: steps[i].$1, body: steps[i].$2),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('How checking works'),
        if (desktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: S.x6),
                  Expanded(child: cards[i]),
                ],
              ],
            ),
          )
        else
          for (final c in cards) ...[c, const SizedBox(height: S.x4)],
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title, required this.body});

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(top: S.x3),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: C.ink, width: 2)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$number',
          style: const TextStyle(
            fontFamily: Fonts.serif,
            fontWeight: FontWeight.w600,
            fontSize: 28,
            height: 1.1,
            color: C.ledger,
          ),
        ),
        const SizedBox(height: S.x2),
        Text(title, style: T.h3),
        const SizedBox(height: S.x1),
        Text(body, style: T.small),
      ],
    ),
  );
}

/// Paste a check link or vault link and open it. No wallet needed.
class _OpenLink extends StatefulWidget {
  const _OpenLink();

  @override
  State<_OpenLink> createState() => _OpenLinkState();
}

class _OpenLinkState extends State<_OpenLink> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    final services = Services.of(context);
    final raw = _controller.text.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    final segments =
        uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? [];
    if (segments.length == 3 &&
        segments[0] == 'v' &&
        (segments[2] == 'manage' || segments[2] == 'admin')) {
      // Old admin links (…/admin#key=…) carry a key that no longer counts:
      // the manage page asks the owner to sign in with their wallet.
      context.go('/v/${segments[1]}/manage');
      return;
    }
    if (segments.length == 2 && (segments[0] == 'd' || segments[0] == 'v')) {
      context.go('/${segments[0]}/${segments[1]}');
      return;
    }
    setState(
      () => _error =
          'That is not a Credence link. Check links look like '
          '${Links.display(services.links.document('abc123'))}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Open a link'),
        const Text(
          'Paste a check link or vault link. No wallet or account needed.',
          style: T.small,
        ),
        const SizedBox(height: S.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _open(),
                decoration: InputDecoration(
                  labelText: 'Link',
                  hintText: 'https://…/d/…',
                  errorText: _error,
                ),
              ),
            ),
            const SizedBox(width: S.x2),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: _open,
                child: const Text('Open'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
