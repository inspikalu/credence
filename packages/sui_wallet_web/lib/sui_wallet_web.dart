/// Sui wallet connect and sign for Flutter web, through the Wallet Standard.
///
/// * [SuiWalletController]: headless discovery, connect, sign, disconnect,
///   silent reconnect and a stream of changes.
/// * [SuiWalletPicker]: a minimal, themeable wallet list.
/// * [SuiSignInClient]: the browser half of Sign in with Sui against a
///   `sui_auth` server.
///
/// Test helpers (mock wallet, fake backend) are in `testing.dart`.
library;

export 'src/backend.dart';
export 'src/controller.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/picker.dart';
export 'src/sign_in_client.dart';
export 'src/transaction_executor.dart';
