/// Recovery guidance when a submitted transaction's response was lost.
const walletSubmissionUnknownMessage =
    'Your wallet may have completed this step. Keep this page open and check '
    'its transaction history. Do not start another upload or pay again until '
    'the result is confirmed.';

/// What went wrong with a wallet request.
enum SuiWalletErrorKind {
  /// No Sui wallet is installed in this browser.
  notInstalled,

  /// The wallet disappeared (extension disabled or removed).
  walletNotFound,

  /// The wallet lacks a feature this site needs.
  unsupported,

  /// The person cancelled or rejected the request in the wallet.
  rejected,

  /// The wallet is locked.
  locked,

  /// The wallet connected but shared no Sui account.
  noAccounts,

  /// The account is no longer connected (switched or revoked).
  accountNotFound,

  /// The wallet did not answer in time.
  timeout,

  /// Another wallet request is still open.
  busy,

  /// No wallet is connected.
  notConnected,

  /// Not on the web, so there are no wallets to talk to.
  unavailable,

  /// The transaction executed on-chain and failed atomically.
  transactionFailed,
  unknown,
}

/// A wallet request failed. [message] is short, plain text for people;
/// [detail] is what the wallet itself said, for logs.
class SuiWalletException implements Exception {
  const SuiWalletException(
    this.kind,
    this.message, {
    this.detail,
    this.walletName,
    this.definitelyNotSubmitted = false,
    this.transactionDigest,
  });

  final SuiWalletErrorKind kind;
  final String message;
  final String? detail;
  final String? walletName;
  final String? transactionDigest;

  /// True only for a controller precheck or an explicit user-rejection code
  /// that establishes that this request did not submit a transaction.
  /// Wording such as "rejected" is a UI hint, not evidence of non-submission.
  /// Timeouts and lost responses always leave this false.
  final bool definitelyNotSubmitted;

  /// Builds the exception with the default wording for [kind].
  factory SuiWalletException.of(
    SuiWalletErrorKind kind, {
    String? walletName,
    String? detail,
    bool definitelyNotSubmitted = false,
  }) => SuiWalletException(
    kind,
    defaultMessage(kind, walletName),
    detail: detail,
    walletName: walletName,
    definitelyNotSubmitted: definitelyNotSubmitted,
  );

  static String defaultMessage(SuiWalletErrorKind kind, String? walletName) {
    final wallet = walletName ?? 'your wallet';
    final capitalised = walletName ?? 'Your wallet';
    return switch (kind) {
      SuiWalletErrorKind.notInstalled =>
        'No Sui wallet found in this browser. Install Slush, then reload '
            'this page.',
      SuiWalletErrorKind.walletNotFound =>
        '$capitalised is no longer available. Reload the page and try again.',
      SuiWalletErrorKind.unsupported =>
        '$capitalised cannot sign in to this site. Try another wallet.',
      SuiWalletErrorKind.rejected => 'You cancelled the request in $wallet.',
      SuiWalletErrorKind.locked =>
        '$capitalised is locked. Unlock it and try again.',
      SuiWalletErrorKind.noAccounts =>
        '$capitalised did not share a Sui account. Unlock it, choose an account '
            'and try again.',
      SuiWalletErrorKind.accountNotFound =>
        'That account is no longer connected in $wallet. Connect again.',
      SuiWalletErrorKind.timeout =>
        '$capitalised did not respond. Check the wallet window and try again.',
      SuiWalletErrorKind.busy =>
        'Finish the request that is already open in $wallet.',
      SuiWalletErrorKind.notConnected => 'Connect a wallet first.',
      SuiWalletErrorKind.unavailable =>
        'Wallets are only available in a web browser.',
      SuiWalletErrorKind.transactionFailed =>
        'The transaction failed on Sui. Its network fee may still be charged.',
      SuiWalletErrorKind.unknown =>
        'Something went wrong in $wallet. Try again.',
    };
  }

  @override
  String toString() =>
      'SuiWalletException(${kind.name}): $message'
      '${detail == null ? '' : ' [$detail]'}';
}

final _rejected = RegExp(
  r'reject|denied|deny|declin|cancel|dismiss|user closed|closed by (the )?user'
  r'|aborted by user|not approved',
  caseSensitive: false,
);
final _locked = RegExp(r'locked|unlock', caseSensitive: false);
final _account = RegExp(
  r'not (authori[sz]ed|connected)|unknown account|account not found'
  r'|no account',
  caseSensitive: false,
);

/// Turns a wallet's error (name, message, code) into a [SuiWalletException].
///
/// Wallets do not share error types, so this matches EIP-1193 style codes
/// (4001 rejected, 4100 unauthorised) and common wording.
SuiWalletException classifyWalletError({
  String? name,
  String? message,
  String? code,
  String? walletName,
}) {
  final text = '${name ?? ''} ${message ?? ''}';
  final detail = [
    if (name != null && name.isNotEmpty) name,
    if (message != null && message.isNotEmpty) message,
    if (code != null && code.isNotEmpty) 'code $code',
  ].join(': ');
  SuiWalletErrorKind kind;
  if (code == 'WALLET_NOT_FOUND') {
    kind = SuiWalletErrorKind.walletNotFound;
  } else if (code == 'UNSUPPORTED') {
    kind = SuiWalletErrorKind.unsupported;
  } else if (code == '4001' || _rejected.hasMatch(text)) {
    kind = SuiWalletErrorKind.rejected;
  } else if (code == 'WALLET_LOCKED' || _locked.hasMatch(text)) {
    kind = SuiWalletErrorKind.locked;
  } else if (code == 'ACCOUNT_NOT_FOUND' ||
      code == '4100' ||
      _account.hasMatch(text)) {
    kind = SuiWalletErrorKind.accountNotFound;
  } else {
    kind = SuiWalletErrorKind.unknown;
  }
  return SuiWalletException.of(
    kind,
    walletName: walletName,
    detail: detail.isEmpty ? null : detail,
    definitelyNotSubmitted: code == '4001',
  );
}
