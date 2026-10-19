import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'errors.dart';

/// Wallet Standard feature names this package uses.
abstract final class SuiWalletFeatures {
  static const connect = 'standard:connect';
  static const disconnect = 'standard:disconnect';
  static const events = 'standard:events';
  static const signPersonalMessage = 'sui:signPersonalMessage';
  static const signAndExecuteTransaction = 'sui:signAndExecuteTransaction';
  static const signTransaction = 'sui:signTransaction';
}

/// Where to send people who have no wallet.
const slushInstallUrl = 'https://slush.app/download';

/// An account a wallet has shared with the site.
@immutable
class SuiWalletAccount {
  const SuiWalletAccount({
    required this.address,
    required this.publicKey,
    this.chains = const [],
    this.features = const [],
    this.label,
    this.icon,
  });

  /// Full Sui address, `0x` + 64 hex digits.
  final String address;

  /// Raw public key bytes as the wallet reports them (may be empty).
  final Uint8List publicKey;
  final List<String> chains;
  final List<String> features;
  final String? label;
  final String? icon;

  /// True when the account lists a `sui:` chain, or lists no chains at all
  /// (some wallets leave account chains empty).
  bool get supportsSui =>
      chains.isEmpty || chains.any((c) => c.startsWith('sui:'));

  /// `0x1c5d…e9a1`
  String get shortAddress => shortenSuiAddress(address);

  factory SuiWalletAccount.fromJson(Map<Object?, Object?> json) =>
      SuiWalletAccount(
        address: '${json['address'] ?? ''}',
        publicKey: _decodeKey(json['publicKey']),
        chains: _strings(json['chains']),
        features: _strings(json['features']),
        label: json['label'] as String?,
        icon: json['icon'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is SuiWalletAccount && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'SuiWalletAccount($shortAddress)';
}

/// An installed wallet, as discovered through the Wallet Standard.
@immutable
class SuiWalletInfo {
  const SuiWalletInfo({
    required this.id,
    required this.name,
    required this.icon,
    this.version = '',
    this.chains = const [],
    this.features = const [],
    this.accounts = const [],
  });

  /// Identifies the wallet for this page load only.
  final String id;
  final String name;

  /// A `data:image/...` URI supplied by the wallet.
  final String icon;
  final String version;
  final List<String> chains;
  final List<String> features;

  /// Accounts the wallet has already shared with this site.
  final List<SuiWalletAccount> accounts;

  /// Lists a `sui:` chain and can connect and sign personal messages.
  bool get supportsSui =>
      chains.any((c) => c.startsWith('sui:')) &&
      features.contains(SuiWalletFeatures.connect) &&
      features.contains(SuiWalletFeatures.signPersonalMessage);

  bool supportsChain(String chain) => chains.contains(chain);

  factory SuiWalletInfo.fromJson(Map<Object?, Object?> json) => SuiWalletInfo(
    id: '${json['id']}',
    name: '${json['name'] ?? 'Wallet'}',
    icon: '${json['icon'] ?? ''}',
    version: '${json['version'] ?? ''}',
    chains: _strings(json['chains']),
    features: _strings(json['features']),
    accounts: [
      for (final a in (json['accounts'] as List<Object?>? ?? const []))
        if (a is Map) SuiWalletAccount.fromJson(a),
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is SuiWalletInfo &&
      other.id == id &&
      other.name == name &&
      other.icon == icon &&
      listEquals(other.chains, chains) &&
      listEquals(other.features, features) &&
      listEquals(
        other.accounts.map((a) => a.address).toList(),
        accounts.map((a) => a.address).toList(),
      );

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'SuiWalletInfo($name)';
}

enum SuiWalletStatus {
  /// [SuiWalletController.init] has not finished discovery yet.
  initializing,

  /// Trying a silent reconnect to the wallet used last time.
  reconnecting,
  disconnected,
  connecting,
  connected,
}

/// A snapshot of the controller.
@immutable
class SuiWalletState {
  const SuiWalletState({
    required this.status,
    required this.wallets,
    required this.discoveryComplete,
    this.wallet,
    this.account,
    this.busy = false,
  });

  final SuiWalletStatus status;

  /// Installed wallets that support Sui.
  final List<SuiWalletInfo> wallets;

  /// False for a short moment after start-up, while extensions register.
  final bool discoveryComplete;

  /// The connected (or connecting) wallet.
  final SuiWalletInfo? wallet;
  final SuiWalletAccount? account;

  /// A connect or sign request is waiting on the wallet.
  final bool busy;

  bool get isConnected => status == SuiWalletStatus.connected;

  /// No Sui wallet is installed (show the "Install Slush" link).
  bool get noWalletInstalled => discoveryComplete && wallets.isEmpty;

  @override
  String toString() =>
      'SuiWalletState(${status.name}, wallets: ${wallets.length}, '
      'wallet: ${wallet?.name}, account: ${account?.shortAddress})';
}

enum SuiWalletChangeType {
  /// Wallets were installed, removed or updated.
  walletsChanged,
  connecting,
  connected,

  /// Restored silently on page load.
  reconnected,

  /// The person switched accounts in the wallet.
  accountChanged,
  chainsChanged,
  disconnected,

  /// A connect or sign request failed; see [SuiWalletChange.error].
  failed,
}

@immutable
class SuiWalletChange {
  const SuiWalletChange(
    this.type,
    this.state, {
    this.previousAccount,
    this.error,
  });

  final SuiWalletChangeType type;
  final SuiWalletState state;

  /// For [SuiWalletChangeType.accountChanged] and `disconnected`.
  final SuiWalletAccount? previousAccount;
  final SuiWalletException? error;

  @override
  String toString() => 'SuiWalletChange(${type.name}, $state)';
}

/// The wallet's answer to `sui:signPersonalMessage`.
@immutable
class SignedPersonalMessage {
  const SignedPersonalMessage({required this.bytes, required this.signature});

  /// Base64 of the message bytes that were signed.
  final String bytes;

  /// Base64 serialized Sui signature (flag, signature, public key...).
  final String signature;

  Uint8List get messageBytes => base64.decode(bytes);
}

/// The wallet's answer to `sui:signAndExecuteTransaction`.
@immutable
class SignedSuiTransaction {
  const SignedSuiTransaction({required this.bytes, required this.signature});

  final String bytes;
  final String signature;
}

/// A transaction submitted to Sui.
@immutable
class ExecutedSuiTransaction {
  const ExecutedSuiTransaction({
    required this.digest,
    this.effects = '',
    this.bytes = '',
    this.signature = '',
  });

  /// The transaction digest.
  final String digest;

  /// Base64 BCS of the transaction effects, when the wallet returned them.
  final String effects;

  /// Base64 BCS of the signed transaction data.
  final String bytes;

  /// Base64 serialized Sui signature.
  final String signature;
}

/// `0x1c5d…e9a1`
String shortenSuiAddress(String address) => address.length <= 12
    ? address
    : '${address.substring(0, 6)}…${address.substring(address.length - 4)}';

List<String> _strings(Object? value) =>
    value is List ? [for (final v in value) '$v'] : const [];

Uint8List _decodeKey(Object? value) {
  if (value is! String || value.isEmpty) return Uint8List(0);
  try {
    return base64.decode(value);
  } on FormatException {
    return Uint8List(0);
  }
}
