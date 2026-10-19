import 'dart:async';
import 'dart:typed_data';

import '../backend.dart';
import '../errors.dart';
import '../models.dart';

// Outside the browser (VM widget tests, desktop builds) there are no
// wallets. Everything compiles; the controller simply finds no wallets.

SuiWalletBackend createDefaultBackend() => UnsupportedSuiWalletBackend();

SuiWalletStorage createDefaultStorage() => MemorySuiWalletStorage();

SuiWalletTransactionLock createDefaultTransactionLock() =>
    MemorySuiWalletTransactionLock();

void openExternalUrl(String url) {}

void ensureBridgeLoaded({void Function()? onLateLoad}) {}

class UnsupportedSuiWalletBackend implements SuiWalletBackend {
  @override
  bool get isSupported => false;

  @override
  void start() {}

  @override
  List<SuiWalletInfo> listWallets() => const [];

  @override
  Stream<SuiWalletBackendEvent> get events => const Stream.empty();

  @override
  Future<List<SuiWalletAccount>> connect(
    String walletId, {
    required bool silent,
  }) => Future.error(SuiWalletException.of(SuiWalletErrorKind.unavailable));

  @override
  Future<void> disconnect(String walletId) async {}

  @override
  Future<SignedPersonalMessage> signPersonalMessage(
    String walletId, {
    required String address,
    required Uint8List message,
    String? chain,
  }) => Future.error(SuiWalletException.of(SuiWalletErrorKind.unavailable));

  @override
  Future<ExecutedSuiTransaction> signAndExecuteTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) => Future.error(SuiWalletException.of(SuiWalletErrorKind.unavailable));

  @override
  Future<SignedSuiTransaction> signTransaction(
    String walletId, {
    required String address,
    required String transaction,
    required String chain,
  }) => Future.error(SuiWalletException.of(SuiWalletErrorKind.unavailable));

  @override
  void dispose() {}
}
