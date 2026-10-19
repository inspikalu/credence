import 'store.dart';

Future<UploadRecoveryStore> openUploadRecoveryStore({
  String databaseName = 'dartus_upload_recovery_v1',
  int maxJobBytes = 128 * 1024 * 1024,
  int maxStoredBytes = 512 * 1024 * 1024,
  int maxJobs = 64,
}) => throw UnsupportedError(
  'Durable upload recovery requires a browser. Tests can explicitly use MemoryUploadRecoveryStore.',
);
