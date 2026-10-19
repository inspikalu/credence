import 'store.dart';
import 'web_store.dart';

Future<UploadRecoveryStore> openUploadRecoveryStore({
  String databaseName = 'dartus_upload_recovery_v1',
  int maxJobBytes = 128 * 1024 * 1024,
  int maxStoredBytes = 512 * 1024 * 1024,
  int maxJobs = 64,
}) => IndexedDbUploadRecoveryStore.open(
  databaseName: databaseName,
  maxJobBytes: maxJobBytes,
  maxStoredBytes: maxStoredBytes,
  maxJobs: maxJobs,
);
