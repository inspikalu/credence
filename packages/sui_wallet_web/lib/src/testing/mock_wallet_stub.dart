import 'mock_wallet_api.dart';

void installMockWalletScript() {
  throw UnsupportedError(
    'MockSuiWallet needs a browser: run with flutter test --platform chrome. '
    'Use FakeSuiWalletBackend for VM widget tests.',
  );
}

Future<MockSuiWallet> registerMockWallet(MockWalletOptions options) async {
  installMockWalletScript();
  throw StateError('unreachable');
}
