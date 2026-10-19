import 'package:flutter/widgets.dart';
import 'package:upload_recovery/walrus_recovery.dart';
import 'upload_recovery.dart';

import '../models/models.dart';
import '../platform/browser.dart';
import 'account.dart';
import 'api_client.dart';
import 'storage.dart';
import 'walrus_service.dart';

/// Builds shareable links. Uses PUBLIC_BASE_URL from server config when set,
/// otherwise the address the app was opened from.
class Links {
  Links(String base)
    : base = base.endsWith('/') ? base.substring(0, base.length - 1) : base;

  final String base;

  String vault(String id) => '$base/v/$id';

  String document(String id) => '$base/d/$id';

  /// Short form for display (no scheme).
  static String display(String url) =>
      url.replaceFirst(RegExp(r'^https?://'), '');
}

/// Everything screens need, created once the server config is known.
class AppServices {
  AppServices({
    required this.api,
    required this.walrus,
    required this.storage,
    required this.browser,
    required this.account,
    required this.config,
  }) : links = Links(config.publicBaseUrl ?? browser.baseUri.origin);

  final ApiClient api;

  /// Reads from the aggregator.
  final WalrusService walrus;

  /// Writes paid for by the owner's wallet.
  final DocumentStorage storage;
  final Browser browser;

  /// The signed-in vault owner, if any.
  final Account account;
  final AppConfig config;
  final Links links;
  late final WalrusUploadRecovery? recovery = storage is WalrusDocumentStorage
      ? WalrusUploadRecovery(
          app: 'credence',
          chain: config.suiChain,
          wallet: account.wallet,
          finish: (job, stored) async {
            try {
              return await finishCredenceUpload(
                api,
                job,
                stored,
                signedInAddress: () => account.address,
              );
            } on ApiException catch (error) {
              if (error.isSignedOut) account.sessionEnded();
              rethrow;
            }
          },
        )
      : null;
}

class Services extends InheritedWidget {
  const Services({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<Services>();
    assert(widget != null, 'No Services above this context');
    return widget!.services;
  }

  @override
  bool updateShouldNotify(Services oldWidget) => services != oldWidget.services;
}

/// Rebuilds dependants when the signed-in account changes.
class AccountScope extends InheritedNotifier<Account> {
  const AccountScope({
    super.key,
    required Account account,
    required super.child,
  }) : super(notifier: account);

  /// The account, subscribing [context] to its changes.
  static Account of(BuildContext context) => maybeOf(context)!;

  static Account? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccountScope>()?.notifier;
}
