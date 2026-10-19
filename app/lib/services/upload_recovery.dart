import 'package:sui_wallet_web/sui_wallet_web.dart';
import 'package:upload_recovery/walrus_recovery.dart';

import 'api_client.dart';

Future<RecoveryCompletion> finishCredenceUpload(
  ApiClient api,
  RecoverySummary job,
  RecoveredUpload stored, {
  required String? Function() signedInAddress,
}) async {
  if (signedInAddress()?.toLowerCase() != job.scope.owner) {
    throw const SuiWalletException(
      SuiWalletErrorKind.accountNotFound,
      'Sign in with the account that started this upload.',
    );
  }
  final data = job.metadata;
  final listed = await api.claimUpload(stored.objectId);
  if (signedInAddress()?.toLowerCase() != job.scope.owner) {
    throw const SuiWalletException(
      SuiWalletErrorKind.accountNotFound,
      'Sign in with the account that started this upload.',
    );
  }
  await api.createDocument(
    data['vaultId'] as String,
    NewDocument(
      requestId: data['requestId'] as String,
      title: data['title'] as String,
      issuerName: data['issuerName'] as String,
      recipientName: data['recipientName'] as String,
      issueDate: data['issueDate'] as String,
      notes: data['notes'] as String,
      fileName: data['fileName'] as String,
      sha256: data['sha256'] as String,
      blobId: listed?.blobId ?? stored.blobId,
    ),
  );
  return const RecoveryCompletion.complete();
}
