/// Test helpers for apps that use sui_wallet_web.
///
/// * [MockSuiWallet]: a real Wallet Standard wallet with throwaway Ed25519
///   keys, for `flutter test --platform chrome` (and, as
///   `js/mock_wallet.js`, for Playwright).
/// * [FakeSuiWalletBackend]: a pure-Dart backend for VM widget tests.
library;

import 'src/testing/mock_wallet.dart';
import 'src/testing/mock_wallet_api.dart';

export 'src/generated/js_sources.g.dart' show mockWalletJs, suiWalletStandardJs;
export 'src/testing/fake_backend.dart';
export 'src/testing/mock_wallet_api.dart';

/// Registers a mock wallet in the current page (browser tests only).
///
/// Call it before `SuiWalletController.init()` to test wallets that load
/// before the app, or after it to test wallets that load later.
Future<MockSuiWallet> registerMockSuiWallet([
  MockWalletOptions options = const MockWalletOptions(),
]) => registerMockWallet(options);

/// Loads `js/mock_wallet.js` into the page without registering a wallet.
void installMockSuiWalletScript() => installMockWalletScript();
