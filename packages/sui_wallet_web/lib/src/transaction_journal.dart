import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'backend.dart';
import 'errors.dart';
import 'models.dart';
import 'transaction_executor.dart';

const _resumeMessage =
    'The transaction result is not confirmed yet. Keep this upload and retry '
    'to check the same transaction. You will not be asked to pay again.';

/// Durable, account-bound signed transaction records. All calls run inside
/// the controller's cross-tab lock; writes are checked before any broadcast.
class SuiTransactionJournal {
  SuiTransactionJournal(this.storage, this.executor, this.namespace);

  final SuiWalletStorage storage;
  final SuiTransactionExecutor executor;
  final String namespace;

  bool hasRequest(String requestId) =>
      storage.read(
        '$namespace.transactionRequest.${sha256.convert(utf8.encode(requestId))}',
      ) !=
      null;

  String _scope(String chain, String address) =>
      '$namespace.transactions.$chain.${address.toLowerCase()}';

  String? pendingRequestId(String chain, String address) =>
      storage.read('${_scope(chain, address)}.active');

  String _key(String chain, String address, String requestId) =>
      '${_scope(chain, address)}.${sha256.convert(utf8.encode(requestId))}';

  void _write(String key, String? value) {
    storage.write(key, value);
    if (storage.read(key) != value) {
      throw StateError('Could not save the transaction in this browser');
    }
  }

  void _clearActive(String activeKey, String requestId) {
    if (storage.read(activeKey) == requestId) _write(activeKey, null);
  }

  Future<ExecutedSuiTransaction> run({
    required String transaction,
    required String requestId,
    required String chain,
    required String address,
    required String walletName,
    required Future<SignedSuiTransaction> Function() sign,
    required bool Function() isCurrentAccount,
    required Duration signTimeout,
    required Duration networkTimeout,
    required bool resume,
  }) async {
    if (requestId.isEmpty ||
        requestId.length > 256 ||
        transaction.length > 512 * 1024) {
      throw const SuiWalletException(
        SuiWalletErrorKind.unknown,
        'This upload has an invalid transaction request.',
        definitelyNotSubmitted: true,
      );
    }
    final key = _key(chain, address, requestId);
    final activeKey = '${_scope(chain, address)}.active';
    final intentHash = sha256.convert(utf8.encode(transaction)).toString();
    final bindingKey =
        '$namespace.transactionRequest.${sha256.convert(utf8.encode(requestId))}';
    final binding = jsonEncode({
      'chain': chain,
      'address': address.toLowerCase(),
      'intentHash': intentHash,
    });
    final previousBinding = storage.read(bindingKey);
    if (previousBinding != null && previousBinding != binding) {
      throw const SuiWalletException(
        SuiWalletErrorKind.accountNotFound,
        'This upload request belongs to a different account, network or file.',
      );
    }
    final active = storage.read(activeKey);
    if (active != null && active != requestId) {
      throw const SuiWalletException(
        SuiWalletErrorKind.busy,
        'Resume the unfinished upload for this account before starting another.',
      );
    }
    Map<String, dynamic> record;
    var signedSaved = false;
    String? digest;
    try {
      _write(bindingKey, binding);
      final raw = storage.read(key);
      if (raw == null) {
        // A crash during sign-only approval cannot broadcast a transaction.
        // An SDK checkpoint can therefore resume even before this record exists.
        record = {
          'version': 1,
          'requestId': requestId,
          'intentHash': intentHash,
          'chain': chain,
          'address': address.toLowerCase(),
          'wallet': walletName,
          'state': 'unsigned',
        };
        _write(key, jsonEncode(record));
      } else {
        signedSaved = true;
        _write(activeKey, requestId);
        record = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        // A malformed saved signed record must never fall back to a new signature.
        if (record['version'] != 1 ||
            record['requestId'] != requestId ||
            record['intentHash'] != intentHash ||
            record['chain'] != chain ||
            record['address'] != address.toLowerCase()) {
          throw StateError('Saved transaction does not match this upload');
        }
        if (record['state'] == 'unsigned' &&
            !record.containsKey('bytes') &&
            !record.containsKey('signature') &&
            !record.containsKey('digest')) {
          signedSaved = false;
        } else if (!const [
          'signed',
          'confirmed',
          'failed',
        ].contains(record['state'])) {
          throw StateError('Saved transaction has an invalid state');
        }
      }
      void checkAccount() {
        if (!isCurrentAccount()) {
          throw SuiWalletException(
            SuiWalletErrorKind.accountNotFound,
            'Reconnect the account that started this upload, then retry.',
            definitelyNotSubmitted: !signedSaved,
          );
        }
      }

      SignedSuiTransaction signed;
      if (signedSaved) {
        signed = SignedSuiTransaction(
          bytes: record['bytes'] as String,
          signature: record['signature'] as String,
        );
        digest = signedTransactionDigest(signed, address);
        if (digest != record['digest']) {
          throw StateError('Saved transaction digest does not match its bytes');
        }
      } else {
        checkAccount();
        _write(activeKey, requestId);
        // Timeout abandons the continuation. A late wallet signature is never
        // submitted, even if another request has since started.
        signed = await sign().timeout(signTimeout);
        checkAccount();
        digest = signedTransactionDigest(signed, address);
        record.addAll({
          'state': 'signed',
          'bytes': signed.bytes,
          'signature': signed.signature,
          'digest': digest,
        });
        signedSaved = true;
        _write(key, jsonEncode(record));
      }

      if (record['state'] == 'confirmed' || record['state'] == 'failed') {
        _clearActive(activeKey, requestId);
        return _result(record, signed);
      }
      _write(activeKey, requestId);
      checkAccount();
      var receipt = await executor
          .lookup(digest, chain: chain)
          .timeout(networkTimeout);
      if (receipt == null) {
        checkAccount();
        // Re-read the saved authorization before broadcasting. A quota failure,
        // blocked storage, or another tab changing it cannot silently proceed.
        if (storage.read(key) != jsonEncode(record) ||
            storage.read(bindingKey) != binding ||
            storage.read(activeKey) != requestId) {
          throw StateError('Saved transaction changed before submission');
        }
        receipt = await executor
            .execute(signed, chain: chain)
            .timeout(networkTimeout);
      }
      if (receipt.digest != digest) {
        throw const FormatException(
          'Sui returned a different transaction digest',
        );
      }
      record.addAll({
        'state': receipt.success ? 'confirmed' : 'failed',
        'error': receipt.error,
      });
      _write(key, jsonEncode(record));
      _clearActive(activeKey, requestId);
      return _result(record, signed);
    } catch (error) {
      if (signedSaved) {
        if (error is SuiWalletException &&
            error.kind == SuiWalletErrorKind.transactionFailed) {
          rethrow;
        }
        throw SuiWalletException(
          SuiWalletErrorKind.unknown,
          _resumeMessage,
          transactionDigest: digest,
          detail: error.toString(),
        );
      }
      // No path above broadcasts before saving signed bytes. Every failure in
      // this branch, including Slush's ambiguous window-close error, is unpaid.
      try {
        _clearActive(activeKey, requestId);
      } catch (_) {
        // Retaining an unsigned marker is safe; the same request can resume it.
      }
      throw SuiWalletException(
        error is SuiWalletException
            ? error.kind
            : error is TimeoutException
            ? SuiWalletErrorKind.timeout
            : SuiWalletErrorKind.unknown,
        error is SuiWalletException
            ? error.message
            : error is TimeoutException
            ? 'The wallet did not finish signing. You can retry this upload.'
            : 'Could not prepare this transaction. No payment was submitted.',
        detail: error.toString(),
        definitelyNotSubmitted: true,
      );
    }
  }

  ExecutedSuiTransaction _result(
    Map<String, dynamic> record,
    SignedSuiTransaction signed,
  ) {
    if (record['state'] == 'failed') {
      throw SuiWalletException(
        SuiWalletErrorKind.transactionFailed,
        SuiWalletException.defaultMessage(
          SuiWalletErrorKind.transactionFailed,
          null,
        ),
        transactionDigest: record['digest'] as String,
        detail: record['error'] as String?,
      );
    }
    return ExecutedSuiTransaction(
      digest: record['digest'] as String,
      bytes: signed.bytes,
      signature: signed.signature,
    );
  }
}
