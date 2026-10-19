import 'dart:typed_data';

import 'package:dartus/dartus.dart';
import 'package:http/http.dart' as http;
import 'package:sui_wallet_web/sui_wallet_web.dart';
import 'package:upload_recovery/walrus_recovery.dart';

import '../platform/progress_client.dart';

/// What storing a file costs, worked out before the first approval.
class StorageQuote {
  const StorageQuote({
    required this.walFrost,
    required this.relayTipMist,
    required this.epochs,
    required this.endEpoch,
  });

  /// WAL for storage and registration, in FROST (10^-9 WAL).
  final BigInt walFrost;

  /// SUI tip for the upload relay, in MIST; gas comes on top.
  final BigInt relayTipMist;
  final int epochs;

  /// Storage would end at the start of this Walrus epoch.
  final int endEpoch;
}

/// The step a wallet-paid write is entering.
enum StorageStage {
  /// Computing the blob ID in the browser.
  preparing,

  /// Waiting for the wallet to approve the payment (WAL plus gas).
  approvePayment,

  /// Sending the bytes to the upload relay.
  uploading,

  /// Waiting for the wallet to approve certification (gas only).
  approveFinish,
}

/// A certified file on Walrus, owned by the account that paid.
class StoredFile {
  const StoredFile({
    required this.blobId,
    required this.objectId,
    required this.endEpoch,
  });

  final String blobId;

  /// The `Blob` object on Sui; the server checks it before listing.
  final String objectId;
  final int endEpoch;
}

/// Asks the person's wallet to sign and execute a serialized transaction
/// (the JSON a wallet's `signAndExecuteTransaction` takes). Returns the
/// digest.
typedef ExecuteTransaction = Future<String> Function(String transactionJson);

/// Stores files on Walrus, paid for by the person's own wallet.
///
/// The screens only use this small interface, so widget tests can swap in a
/// fake that never touches the network.
abstract interface class DocumentStorage {
  Future<StorageQuote> estimate({required int size, required int epochs});

  /// A write that keeps its progress: run it again after a failure and it
  /// continues where it stopped, without paying twice.
  StorageJob prepare(Uint8List bytes, {required int epochs});

  void close();
}

abstract interface class StorageJob {
  int get epochs;

  /// True once the wallet has paid (the blob is registered). Retrying then
  /// only uploads and certifies.
  bool get paid;

  /// Performs the remaining steps, signing as [address].
  ///
  /// Throws `InsufficientWalBalanceError` (Dartus) when the wallet lacks
  /// WAL, and the wallet's own errors (`SuiWalletException`) when an
  /// approval is declined or fails.
  Future<StoredFile> run({
    required String address,
    required ExecuteTransaction execute,
    void Function(StorageStage stage)? onStage,
    void Function(double sent)? onUpload,
  });
}

/// [DocumentStorage] over Dartus's [WalrusWriter]: the blob ID is computed
/// with walrus-wasm in a Web Worker, the wallet registers and pays, the
/// bytes go to Mysten's upload relay, and the wallet certifies.
class WalrusDocumentStorage implements DocumentStorage {
  /// [wasmBaseUrl] is where the walrus-wasm files are served. Dartus
  /// resolves its default against the page's URL, which breaks on deep links
  /// such as `/v/<id>/manage`, so pass an absolute one.
  WalrusDocumentStorage({
    required WalrusNetwork network,
    Uri? wasmBaseUrl,
    http.Client? client,
  }) : _progress = ProgressClient(client) {
    _writer = WalrusWriter(
      network: network,
      httpClient: _progress,
      encoder: createDefaultBlobEncoder(wasmBaseUrl: wasmBaseUrl),
    );
  }

  /// Where Flutter serves the walrus-wasm files Dartus bundles, for an app
  /// served from the root of [origin].
  static Uri wasmBaseFor(Uri origin) =>
      origin.resolve('/assets/packages/dartus/assets/walrus_wasm/');

  /// The network named by a Wallet Standard chain such as `sui:testnet`.
  static WalrusNetwork networkFor(String suiChain) =>
      suiChain == 'sui:mainnet' ? WalrusNetwork.mainnet : WalrusNetwork.testnet;

  final ProgressClient _progress;
  late final WalrusWriter _writer;

  @override
  Future<StorageQuote> estimate({
    required int size,
    required int epochs,
  }) async {
    final estimate = await _writer.estimate(size: size, epochs: epochs);
    return StorageQuote(
      walFrost: estimate.cost.total,
      relayTipMist: estimate.relayTip,
      epochs: epochs,
      endEpoch: estimate.endEpoch,
    );
  }

  @override
  StorageJob prepare(Uint8List bytes, {required int epochs}) =>
      _WalrusJob(this, bytes, epochs);

  @override
  void close() {
    _writer.close();
    _progress.close();
  }
}

abstract interface class RecoverableStorageJob
    implements StorageJob, RecoveryCheckpointSource {
  set recoverySigner(WalrusTransactionSigner signer);
}

class _WalrusJob implements RecoverableStorageJob {
  _WalrusJob(this._storage, Uint8List bytes, this.epochs) {
    _flow = _storage._writer.writeFlow(
      bytes,
      epochs: epochs,
      onCheckpoint: (checkpoint) async => await onCheckpoint?.call(checkpoint),
    );
  }

  @override
  CheckpointHandler? onCheckpoint;
  @override
  WalrusTransactionSigner? recoverySigner;
  @override
  WalrusWriteCheckpoint get checkpoint => _flow.checkpoint;

  final WalrusDocumentStorage _storage;
  late final WalrusWriteFlow _flow;

  @override
  final int epochs;

  @override
  bool get paid => _flow.registerDigest != null;

  @override
  Future<StoredFile> run({
    required String address,
    required ExecuteTransaction execute,
    void Function(StorageStage stage)? onStage,
    void Function(double sent)? onUpload,
  }) async {
    final signer =
        recoverySigner ??
        WalletTransactionSigner(
          address: address,
          isDefinitelyNotCommitted: (error) =>
              error is SuiWalletException && error.definitelyNotSubmitted,
          execute: (tx) => execute(tx.json),
        );
    _storage._progress.onUpload = onUpload == null
        ? null
        : (sent, total) => onUpload(total == 0 ? 1 : sent / total);
    try {
      final result = await _flow.run(
        signer,
        onStage: (stage) => onStage?.call(switch (stage) {
          WalrusWriteStage.encoding => StorageStage.preparing,
          WalrusWriteStage.registering => StorageStage.approvePayment,
          WalrusWriteStage.uploading => StorageStage.uploading,
          WalrusWriteStage.certifying => StorageStage.approveFinish,
        }),
      );
      return StoredFile(
        blobId: result.blobId,
        objectId: result.blobObjectId,
        endEpoch: result.endEpoch,
      );
    } finally {
      _storage._progress.onUpload = null;
    }
  }
}
