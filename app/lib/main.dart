import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:sui_wallet_web/sui_wallet_web.dart';

import 'app.dart';
import 'platform/browser.dart';
import 'platform/http_client.dart';
import 'platform/input_modality.dart';
import 'services/account.dart';
import 'services/api_client.dart';
import 'services/storage.dart';
import 'services/walrus_service.dart';

/// The API lives on the same origin as the app. For local development with
/// `flutter run`, pass `--dart-define=CREDENCE_SERVER=http://localhost:8094`.
const _serverOverride = String.fromEnvironment('CREDENCE_SERVER');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  // Build the semantics tree from the start so screen readers and keyboard
  // users do not need to find Flutter's hidden "enable accessibility" button.
  SemanticsBinding.instance.ensureSemantics();
  installInputModality();

  final browser = Browser();
  final server = Uri.parse(
    _serverOverride.isNotEmpty ? _serverOverride : browser.baseUri.origin,
  );

  // The loading screen briefly owns the URL, so remember where the person
  // was going before anything is drawn.
  final start = browser.baseUri;
  final initialLocation = start.path.isEmpty
      ? '/'
      : '${start.path}${start.hasQuery ? '?${start.query}' : ''}';

  runApp(
    CredenceApp(
      initialLocation: initialLocation,
      api: ApiClient(baseUrl: server, client: createCredentialedClient()),
      browser: browser,
      accountFactory: (config) {
        final wallet = SuiWalletController(chain: config.suiChain);
        return Account(
          wallet: wallet,
          client: SuiSignInClient(
            wallet: wallet,
            authBase: server.resolve('/api/auth/'),
            httpClient: createCredentialedClient(),
          ),
        );
      },
      // Reads go straight to the aggregator; nobody needs a wallet.
      walrusFactory: (config) => WalrusService(
        aggregatorBaseUrl: config.aggregatorUrl,
        httpClient: http.Client(),
      ),
      // The owner's wallet pays for storage: Dartus computes the blob ID in a
      // Web Worker, the wallet registers and pays, the bytes go to the upload
      // relay (with progress), and the wallet certifies. This server only
      // ever sees the Blob object ID.
      storageFactory: (config) => WalrusDocumentStorage(
        network: WalrusDocumentStorage.networkFor(config.suiChain),
        wasmBaseUrl: WalrusDocumentStorage.wasmBaseFor(browser.baseUri),
      ),
    ),
  );
}
