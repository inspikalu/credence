import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';

import '../services/account.dart';
import '../services/services.dart';
import '../theme/tokens.dart';
import 'common.dart';
import 'page_frame.dart';

/// Opens the sign-in dialog. Returns true once signed in.
Future<bool> showSignInDialog(BuildContext context) async {
  final account = Services.of(context).account;
  final result = await showDialog<bool>(
    context: context,
    animationStyle: Motion.dialogStyle(context),
    builder: (_) => SignInDialog(account: account),
  );
  return result ?? false;
}

/// Sign in with Sui: pick a wallet, then sign a short message.
class SignInDialog extends StatefulWidget {
  const SignInDialog({super.key, required this.account});

  final Account account;

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  SuiSignInStep? _step;
  String? _message;
  String? _error;

  SuiWalletController get _wallet => widget.account.wallet;

  @override
  void initState() {
    super.initState();
    _wallet.addListener(_onWallet);
  }

  @override
  void dispose() {
    _wallet.removeListener(_onWallet);
    super.dispose();
  }

  void _onWallet() {
    if (mounted) setState(() {});
  }

  Future<void> _sign() async {
    setState(() {
      _error = null;
      _message = null;
      _step = SuiSignInStep.requestingChallenge;
    });
    try {
      await widget.account.signIn(
        onProgress: (step, {message}) {
          if (!mounted) return;
          setState(() {
            _step = step;
            _message = message ?? _message;
          });
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } on SuiSignInException catch (e) {
      if (!mounted) return;
      setState(() {
        _step = null;
        _error = e.message;
      });
    }
  }

  Future<void> _useAnother() async {
    await _wallet.disconnect();
    if (mounted) setState(() => _error = null);
  }

  String _stepText(SuiSignInStep step) => switch (step) {
    SuiSignInStep.connecting => 'Waiting for your wallet to connect…',
    SuiSignInStep.requestingChallenge => 'Preparing the message…',
    SuiSignInStep.signing =>
      'Approve the message in ${_wallet.wallet?.name ?? 'your wallet'}.',
    SuiSignInStep.verifying => 'Checking the signature…',
    SuiSignInStep.done => 'Signed in.',
  };

  @override
  Widget build(BuildContext context) {
    final busy = _step != null;
    final connected = _wallet.isConnected;
    final account = _wallet.account;
    final title = Theme.of(context).dialogTheme.titleTextStyle;
    // Narrower insets on phones so wallet names have room.
    final phone = Breakpoints.isPhone(context);

    return Dialog(
      insetPadding: phone
          ? const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x6)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(S.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text('Sign in to manage your vaults', style: title),
              ),
              const SizedBox(height: S.x2),
              const Text(
                'Your wallet signs a short message to show that you control '
                'its address. It does not send a transaction or cost gas. '
                'Checking a document never needs a wallet.',
                style: T.small,
              ),
              const SizedBox(height: S.x6),
              if (busy)
                _Progress(text: _stepText(_step!), message: _message)
              else if (connected && account != null)
                _Connected(
                  walletName: _wallet.wallet?.name ?? 'Wallet',
                  address: account.address,
                  onSign: _sign,
                  onUseAnother: _useAnother,
                )
              else
                SuiWalletPicker(
                  controller: _wallet,
                  showTitle: false,
                  strings: const SuiWalletPickerStrings(
                    title: 'Choose a wallet',
                    noWallet: 'No Sui wallet found in this browser.',
                    installHint: 'Then reload this page and sign in.',
                  ),
                  onConnected: (_) => _sign(),
                  onError: (e) => setState(() => _error = e.message),
                ),
              if (_error != null) ...[
                const SizedBox(height: S.x4),
                Semantics(
                  liveRegion: true,
                  child: Notice(
                    tone: Tone.danger,
                    title: 'Not signed in',
                    body: _error,
                  ),
                ),
              ],
              const SizedBox(height: S.x6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({
    required this.walletName,
    required this.address,
    required this.onSign,
    required this.onUseAnother,
  });

  final String walletName;
  final String address;
  final VoidCallback onSign;
  final VoidCallback onUseAnother;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Eyebrow('Connected wallet'),
      const SizedBox(height: S.x1),
      Text(walletName, style: T.smallStrong),
      SelectableText(address, style: T.monoSmall),
      const SizedBox(height: S.x4),
      Wrap(
        spacing: S.x2,
        runSpacing: S.x2,
        children: [
          FilledButton(
            onPressed: onSign,
            child: const Text('Sign the message'),
          ),
          TextButton(
            onPressed: onUseAnother,
            child: const Text('Use another wallet'),
          ),
        ],
      ),
    ],
  );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.text, this.message});

  final String text;
  final String? message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: S.x3),
            Expanded(child: Text(text, style: T.body)),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: S.x4),
          const Eyebrow('The message your wallet shows'),
          const SizedBox(height: S.x1),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(S.x3),
            decoration: BoxDecoration(
              color: C.paper,
              border: Border.all(color: C.rule),
              borderRadius: BorderRadius.circular(R.control),
            ),
            child: Text(message!, style: T.monoSmall),
          ),
        ],
      ],
    ),
  );
}

/// The primary call to action for owners who are signed out.
class SignInButton extends StatelessWidget {
  const SignInButton({super.key, this.label = 'Sign in with a Sui wallet'});

  final String label;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: () => showSignInDialog(context),
    icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
    label: Text(label),
  );
}

/// The top-bar account control: "Sign in", or the signed-in address with a
/// menu.
class AccountChip extends StatelessWidget {
  const AccountChip({super.key});

  @override
  Widget build(BuildContext context) {
    final account = AccountScope.maybeOf(context);
    if (account == null || !account.checked) return const SizedBox.shrink();
    final session = account.session;
    if (session == null) {
      return TextButton(
        onPressed: () => showSignInDialog(context),
        child: const Text('Sign in'),
      );
    }
    final short = shortAddress(session.address);
    // On phones the address lives in the menu, so the logo keeps its room.
    final phone = Breakpoints.isPhone(context);
    return PopupMenuButton<String>(
      tooltip: 'Account: signed in as $short',
      position: PopupMenuPosition.under,
      popUpAnimationStyle: Motion.reduced(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Motion.quick,
              reverseDuration: Motion.exit,
            ),
      onSelected: (value) async {
        switch (value) {
          case 'vaults':
            context.go('/app');
          case 'copy':
            final copied = await copyText(context, session.address);
            if (context.mounted && copied) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(const SnackBar(content: Text('Address copied')));
            }
          case 'out':
            final signedOut = await account.signOut();
            if (!context.mounted) return;
            if (signedOut) {
              context.go('/app');
            } else {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(account.signOutError!)));
            }
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Signed in as', style: T.small),
              Text(short, style: T.monoSmall.copyWith(color: C.ink)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'vaults', child: Text('Your vaults')),
        const PopupMenuItem(value: 'copy', child: Text('Copy address')),
        const PopupMenuItem(value: 'out', child: Text('Sign out')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: S.x3),
        decoration: BoxDecoration(
          color: C.surface,
          border: Border.all(color: C.rule),
          borderRadius: BorderRadius.circular(R.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.account_balance_wallet_outlined,
              size: 16,
              color: C.ledger,
            ),
            if (!phone) ...[
              const SizedBox(width: S.x2),
              Text(short, style: T.monoSmall.copyWith(color: C.ink)),
            ],
            const SizedBox(width: S.x1),
            const Icon(Icons.expand_more, size: 18, color: C.inkMuted),
          ],
        ),
      ),
    );
  }
}

/// Shown when the wallet switched accounts while signed in.
class AccountSwitchNotice extends StatelessWidget {
  const AccountSwitchNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final account = AccountScope.maybeOf(context);
    final switched = account?.switchedTo;
    final session = account?.session;
    if (account == null || switched == null || session == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: S.x6),
      child: Semantics(
        liveRegion: true,
        child: Notice(
          tone: Tone.warning,
          title: 'Your wallet switched to ${shortAddress(switched)}',
          body:
              'You are still signed in as ${shortAddress(session.address)}, '
              'so Credence shows that account\'s vaults. Sign in again to '
              'manage the vaults of ${shortAddress(switched)}.',
          action: Wrap(
            spacing: S.x2,
            runSpacing: S.x2,
            children: [
              FilledButton(
                onPressed: () => showSignInDialog(context),
                child: Text('Sign in as ${shortAddress(switched)}'),
              ),
              TextButton(
                onPressed: account.dismissSwitch,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
