import 'dart:convert';
import 'dart:typed_data';

import 'package:sui/grpc/proto/sui/rpc/v2/executed_transaction.pb.dart' as pb;
import 'package:sui/sui.dart' as sui;

import 'models.dart';

/// A final execution receipt. A missing lookup is different from a failure.
class SuiTransactionReceipt {
  const SuiTransactionReceipt({
    required this.digest,
    required this.success,
    this.error,
  });

  final String digest;
  final bool success;
  final String? error;
}

/// The network transport never signs and never holds an account's key.
abstract interface class SuiTransactionExecutor {
  Future<SuiTransactionReceipt?> lookup(String digest, {required String chain});
  Future<SuiTransactionReceipt> execute(
    SignedSuiTransaction transaction, {
    required String chain,
  });
}

class GrpcSuiTransactionExecutor implements SuiTransactionExecutor {
  final _clients = <String, sui.SuiGrpcClient>{};

  sui.SuiGrpcClient _client(String chain) => _clients.putIfAbsent(chain, () {
    final network = switch (chain) {
      'sui:mainnet' => sui.SuiNetwork.mainnet,
      'sui:testnet' => sui.SuiNetwork.testnet,
      'sui:devnet' => sui.SuiNetwork.devnet,
      'sui:localnet' => sui.SuiNetwork.localnet,
      _ => throw ArgumentError.value(chain, 'chain', 'Unsupported Sui chain'),
    };
    return sui.SuiGrpcClient(network: network);
  });

  SuiTransactionReceipt _receipt(pb.ExecutedTransaction tx) {
    if (!tx.hasDigest() ||
        !tx.hasEffects() ||
        !tx.effects.hasStatus() ||
        !tx.effects.status.hasSuccess()) {
      throw const FormatException('Sui returned no final execution status');
    }
    return SuiTransactionReceipt(
      digest: tx.digest,
      success: tx.effects.status.success,
      error: tx.effects.status.hasError()
          ? tx.effects.status.error.description
          : null,
    );
  }

  @override
  Future<SuiTransactionReceipt?> lookup(
    String digest, {
    required String chain,
  }) async {
    try {
      return _receipt(
        await _client(
          chain,
        ).getTransaction(digest, readMask: const ['digest', 'effects.status']),
      );
    } on sui.GrpcWebException catch (error) {
      if (error.status == sui.GrpcStatus.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<SuiTransactionReceipt> execute(
    SignedSuiTransaction transaction, {
    required String chain,
  }) async => _receipt(
    await _client(chain).executeTransaction(
      base64Decode(transaction.bytes),
      [base64Decode(transaction.signature)],
      readMask: const ['digest', 'effects.status'],
    ),
  );
}

/// Validates the signed transaction's owner and derives its canonical digest
/// from its BCS bytes, using the same TransactionData hash as the Sui SDK.
String signedTransactionDigest(
  SignedSuiTransaction transaction,
  String address,
) {
  final bytes = base64Decode(transaction.bytes);
  final signature = base64Decode(transaction.signature);
  if (bytes.isEmpty ||
      bytes.length > 128 * 1024 ||
      signature.isEmpty ||
      signature.length > 64 * 1024) {
    throw const FormatException('Invalid signed transaction size');
  }
  final data = sui.TransactionBlockDataBuilder.fromBytes(bytes);
  if (data.sender?.toLowerCase() != address.toLowerCase()) {
    throw const FormatException(
      'Signed transaction belongs to another account',
    );
  }
  // Reject trailing data rather than hash bytes the BCS parser did not read.
  final rebuilt = data.build();
  if (!_sameBytes(bytes, rebuilt)) {
    throw const FormatException('Non-canonical signed transaction bytes');
  }
  return sui.TransactionBlockDataBuilder.getDigestFromBytes(bytes);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
