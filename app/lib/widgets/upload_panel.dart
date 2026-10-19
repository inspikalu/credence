import 'dart:async';
import 'dart:math';

import 'package:dartus/dartus.dart'
    show InsufficientWalBalanceError, WalrusTransactionOutcomeUnknown;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sui_wallet_web/sui_wallet_web.dart';
import 'package:upload_recovery/walrus_recovery.dart';

import '../models/models.dart';
import '../services/account.dart';
import '../services/api_client.dart';
import '../services/file_rules.dart';
import '../services/hashing.dart';
import '../services/services.dart';
import '../services/storage.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'common.dart';
import 'date_field.dart';
import 'drop_zone.dart';
import 'page_frame.dart';
import 'sign_in.dart';

enum UploadPhase { idle, hashing, ready, storing, checking, saving, done }

/// Why the last attempt stopped, so the notice can say what to do next.
enum _Problem {
  /// The person declined an approval in their wallet.
  declined,

  /// The wallet failed or refused for another reason.
  wallet,

  /// The wallet holds too little WAL to pay for storage.
  noWal,

  /// The wallet's account is not the signed-in account.
  wrongAccount,

  /// Storing stopped (network, relay, chain); trying again continues.
  storing,

  /// A wallet response was lost; do not start a second payment.
  unknownOutcome,

  /// The file is stored, but the server has not listed it or saved the
  /// record yet.
  listing,
}

/// Add a document: choose a file, fingerprint it locally, fill in details,
/// store it on Walrus with the owner's wallet (Dartus `WalrusWriter`), let
/// the server check it on Sui, then save the record.
class UploadPanel extends StatefulWidget {
  const UploadPanel({
    super.key,
    required this.vault,
    required this.onCreated,
    this.enabled = true,
  });

  final Vault vault;
  final ValueChanged<DocumentRecord> onCreated;
  final bool enabled;

  @override
  State<UploadPanel> createState() => _UploadPanelState();
}

class _UploadPanelState extends State<UploadPanel> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _issuer = TextEditingController();
  final _recipient = TextEditingController();
  final _date = TextEditingController();
  final _notes = TextEditingController();

  UploadPhase _phase = UploadPhase.idle;
  LocalFile? _file;
  String? _contentType;
  String? _fileError;
  double _hashProgress = 0;
  String? _sha;
  String? _error;
  _Problem? _problem;
  bool _walletCheckRequired = false;

  /// The storage period the owner chose, in epochs.
  late int _epochs = Services.of(context).config.epochs;
  StorageQuote? _quote;
  bool _quoting = false;
  bool _quoteFailed = false;
  int _quoteRequest = 0;

  /// The wallet-paid write for the chosen file. Kept after a failure: trying
  /// again continues it without registering or paying twice. Dropped only
  /// when the file changes (or the wallet cannot pay at all).
  StorageJob? _job;
  UploadRecoverySession? _recoverySession;
  StorageStage? _stage;
  double _uploaded = 0;

  /// The certified file, once the wallet has finished.
  StoredFile? _stored;

  /// The server has checked and listed [_stored].
  bool _listed = false;

  /// The blob ID as the server read it from the Blob object on Sui.
  String? _listedBlobId;
  String? _requestId;

  /// The server answered 401: the sign-in session ended mid-way.
  bool _signedOut = false;
  DocumentRecord? _created;
  Map<String, String> _fieldErrors = {};

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  void _prefill() {
    if (widget.vault.kind == VaultKind.organization) {
      _issuer.text = widget.vault.name;
    } else {
      _recipient.text = widget.vault.name;
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _issuer, _recipient, _date, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _busy =>
      _phase == UploadPhase.hashing ||
      _phase == UploadPhase.storing ||
      _phase == UploadPhase.checking ||
      _phase == UploadPhase.saving;

  /// The wallet has paid for the current file (or finished storing it).
  bool get _paid => _stored != null || (_job?.paid ?? false);

  /// Forgets the stored file and any write in progress (a new file).
  void _forgetStorage() {
    if (_walletCheckRequired || _recoverySession != null) return;
    _job = null;
    _stored = null;
    _listed = false;
    _listedBlobId = null;
    _requestId = null;
    _stage = null;
    _problem = null;
    _error = null;
  }

  Future<void> _estimate() async {
    final file = _file;
    if (file == null) return;
    final request = ++_quoteRequest;
    setState(() {
      _quoting = true;
      _quoteFailed = false;
    });
    try {
      final quote = await Services.of(
        context,
      ).storage.estimate(size: file.size, epochs: _epochs);
      if (!mounted || request != _quoteRequest) return;
      setState(() {
        _quote = quote;
        _quoting = false;
      });
    } on Object catch (e) {
      // The estimate is a courtesy: the wallet shows the exact amount
      // before anything is paid.
      debugPrint('Walrus cost estimate failed: $e');
      if (!mounted || request != _quoteRequest) return;
      setState(() {
        _quote = null;
        _quoting = false;
        _quoteFailed = true;
      });
    }
  }

  void _setEpochs(int epochs) {
    if (_busy || _paid || _walletCheckRequired || _recoverySession != null) {
      return;
    }
    if (epochs == _epochs) return;
    setState(() {
      _epochs = epochs;
      // Nothing is paid yet, so the next try starts with the new period.
      if (!_paid) _job = null;
    });
    unawaited(_estimate());
  }

  Future<void> _onFile(LocalFile file) async {
    if (_busy || _paid || _walletCheckRequired || _recoverySession != null) {
      return;
    }
    final config = Services.of(context).config;
    final check = checkForUpload(file, maxBytes: config.maxUploadBytes);
    if (check is FileRejected) {
      setState(() {
        _file = null;
        _sha = null;
        _fileError = check.message;
        _phase = UploadPhase.idle;
      });
      return;
    }
    setState(() {
      _file = file;
      _contentType = (check as FileAccepted).contentType;
      _fileError = null;
      _sha = null;
      _forgetStorage();
      _quote = null;
      _created = null;
      _hashProgress = 0;
      _phase = UploadPhase.hashing;
    });
    final sha = await sha256Hex(
      file.bytes,
      onProgress: (p) {
        if (mounted) setState(() => _hashProgress = p);
      },
    );
    if (!mounted || !identical(_file, file)) return;
    setState(() {
      _sha = sha;
      _phase = UploadPhase.ready;
    });
    unawaited(_estimate());
  }

  Future<void> _submit() async {
    if (!widget.enabled || _busy || _walletCheckRequired) return;
    setState(() {
      _error = null;
      _problem = null;
      _signedOut = false;
      _fieldErrors = {};
    });
    final formOk = _form.currentState?.validate() ?? false;
    if (_file == null || _sha == null) {
      setState(() => _fileError = 'Choose the file to store first.');
      return;
    }
    if (!formOk) return;
    final services = Services.of(context);
    final account = services.account;
    final address = account.address;
    if (address == null) {
      setState(() => _signedOut = true);
      return;
    }
    final file = _file!;
    _requestId ??= List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    setState(() => _phase = UploadPhase.storing);
    try {
      if (_recoverySession != null) {
        await _recoverySession!.activate();
        await _recoverySession!.updateMetadata(_recoveryMetadata(file));
      }
      var stored = _stored;
      if (stored == null) {
        final wallet = account.wallet;
        if (!wallet.isConnected) {
          if (!mounted) return;
          final connected = await showSuiWalletPicker(
            context,
            controller: wallet,
            strings: const SuiWalletPickerStrings(
              title: 'Connect your wallet to pay for storage',
            ),
          );
          if (connected == null || !mounted) return;
        }
        final using = wallet.account?.address;
        if (using != address) {
          setState(() {
            _problem = _Problem.wrongAccount;
            _error = using;
          });
          return;
        }
        final job = _job ??= services.storage.prepare(
          file.bytes,
          epochs: _epochs,
        );
        if (job is RecoverableStorageJob && services.recovery != null) {
          job.recoverySigner = services.recovery!.signer(
            address,
            canContinue: () =>
                mounted && widget.enabled && account.address == address,
          );
          _recoverySession ??= await services.recovery!.bind(
            job,
            owner: address,
            metadata: _recoveryMetadata(file),
          );
        }
        if (!mounted) return;
        setState(() {
          _phase = UploadPhase.storing;
          _stage = StorageStage.preparing;
          _uploaded = 0;
        });
        stored = await job.run(
          address: address,
          execute: (json) async {
            if (!mounted ||
                !widget.enabled ||
                account.address != address ||
                wallet.account?.address != address) {
              throw const SuiWalletException(
                SuiWalletErrorKind.accountNotFound,
                'Reconnect the wallet account you signed in with, then try again.',
                definitelyNotSubmitted: true,
              );
            }
            return (await wallet.signAndExecuteTransaction(json)).digest;
          },
          onStage: (stage) {
            if (mounted) setState(() => _stage = stage);
          },
          onUpload: (sent) {
            if (mounted) setState(() => _uploaded = sent);
          },
        );
        _stored = stored;
      }
      if (!mounted) return;
      if (account.address != address || !widget.enabled) {
        throw const SuiWalletException(
          SuiWalletErrorKind.accountNotFound,
          'Sign in with the account that started this upload.',
        );
      }
      if (!_listed) {
        setState(() => _phase = UploadPhase.checking);
        final listed = await services.api.claimUpload(stored.objectId);
        // The server's blob ID comes from Sui; null means an earlier try
        // already listed this object.
        _listedBlobId = listed?.blobId ?? stored.blobId;
        _listed = true;
      }
      if (!mounted) return;
      if (account.address != address || !widget.enabled) {
        throw const SuiWalletException(
          SuiWalletErrorKind.accountNotFound,
          'Sign in with the account that started this upload.',
        );
      }
      setState(() => _phase = UploadPhase.saving);
      final record = await services.api.createDocument(
        widget.vault.id,
        NewDocument(
          requestId: _requestId,
          title: _title.text.trim(),
          issuerName: _issuer.text.trim(),
          recipientName: _recipient.text.trim(),
          issueDate: _date.text.trim(),
          notes: _notes.text.trim(),
          fileName: file.name,
          sha256: _sha!,
          blobId: _listedBlobId ?? stored.blobId,
        ),
      );
      await _recoverySession?.complete();
      _recoverySession = null;
      if (!mounted) return;
      setState(() {
        _created = record;
        _phase = UploadPhase.done;
      });
      widget.onCreated(record);
    } on InsufficientWalBalanceError {
      if (!mounted) return;
      setState(() {
        // Nothing was paid; the next try starts afresh with the new balance.
        if (_recoverySession == null) _job = null;
        _problem = _Problem.noWal;
        _phase = UploadPhase.ready;
      });
    } on WalrusTransactionOutcomeUnknown {
      if (!mounted) return;
      setState(() {
        _walletCheckRequired = _recoverySession == null;
        _problem = _Problem.unknownOutcome;
        _phase = UploadPhase.ready;
      });
    } on SuiWalletException catch (e) {
      if (!mounted) return;
      setState(() {
        _walletCheckRequired =
            _recoverySession == null &&
            e.kind == SuiWalletErrorKind.unknown &&
            !e.definitelyNotSubmitted;
        _problem = _walletCheckRequired
            ? _Problem.unknownOutcome
            : e.kind == SuiWalletErrorKind.rejected
            ? _Problem.declined
            : _Problem.wallet;
        _error = e.message;
        _phase = UploadPhase.ready;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _signedOut = e.isSignedOut;
        if (e.isSignedOut) {
          // Shown by the sign-in notice; the paid file is kept.
        } else if (e.field != null &&
            {
              'title',
              'issuerName',
              'recipientName',
              'issueDate',
              'notes',
            }.contains(e.field)) {
          _fieldErrors = {e.field!: e.message};
        } else {
          _problem = _Problem.listing;
          _error = e.message;
        }
        _phase = UploadPhase.ready;
      });
    } on Object catch (e) {
      debugPrint('Storing on Walrus failed: $e');
      if (!mounted) return;
      setState(() {
        _problem = _Problem.storing;
        _phase = UploadPhase.ready;
      });
    } finally {
      await _recoverySession?.release();
      if (mounted && _busy) setState(() => _phase = UploadPhase.ready);
    }
  }

  Map<String, Object?> _recoveryMetadata(LocalFile file) => {
    'vaultId': widget.vault.id,
    'label': file.name,
    'requestId': _requestId!,
    'title': _title.text.trim(),
    'issuerName': _issuer.text.trim(),
    'recipientName': _recipient.text.trim(),
    'issueDate': _date.text.trim(),
    'notes': _notes.text.trim(),
    'fileName': file.name,
    'sha256': _sha!,
  };

  void _reset() {
    if (_walletCheckRequired || _recoverySession != null) return;
    _title.clear();
    _notes.clear();
    _date.clear();
    _issuer.clear();
    _recipient.clear();
    _prefill();
    setState(() {
      _phase = UploadPhase.idle;
      _file = null;
      _sha = null;
      _forgetStorage();
      _quote = null;
      _created = null;
      _fileError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    if (_phase == UploadPhase.done && created != null) {
      return _success(context, created);
    }
    final desktop = Breakpoints.isDesktop(context);
    final fileSide = _fileSection(context);
    final formSide = _fields(context);
    return Panel(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('Add a document', style: T.h2(context)),
            ),
            const SizedBox(height: S.x1),
            const Text(
              'PDF, PNG, JPEG or WebP. Your browser computes the SHA-256 '
              'fingerprint before anything is uploaded.',
              style: T.small,
            ),
            const SizedBox(height: S.x6),
            if (desktop)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: fileSide),
                  const SizedBox(width: S.x8),
                  Expanded(flex: 6, child: formSide),
                ],
              )
            else ...[
              fileSide,
              const SizedBox(height: S.x6),
              formSide,
            ],
            if (_file != null && _sha != null) ...[
              const SizedBox(height: S.x6),
              _storage(context),
            ],
            if (_phase == UploadPhase.storing ||
                _phase == UploadPhase.checking ||
                _phase == UploadPhase.saving) ...[
              const SizedBox(height: S.x6),
              _progress(),
            ],
            if (_signedOut || _problem != null) ...[
              const SizedBox(height: S.x6),
              _problemNotice(context),
            ],
            const SizedBox(height: S.x6),
            Wrap(
              spacing: S.x3,
              runSpacing: S.x3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // A problem notice carries its own "Try again".
                if (_problem == null || _busy || _signedOut)
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: const Icon(Icons.lock_outline, size: 18),
                    label: Text(_buttonLabel()),
                  ),
                if (!_busy && _problem == null)
                  const Text(
                    'Your wallet asks twice: once to pay, once to finish.',
                    style: T.small,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _buttonLabel() => switch (_phase) {
    UploadPhase.storing => switch (_stage) {
      StorageStage.uploading => 'Uploading…',
      StorageStage.preparing || null => 'Preparing…',
      _ => 'Waiting for your wallet…',
    },
    UploadPhase.checking => 'Checking…',
    UploadPhase.saving => 'Saving…',
    _ =>
      _problem != null && _problem != _Problem.wrongAccount
          ? 'Try again'
          : 'Store document',
  };

  /// The storage period and what it costs, before the first approval.
  Widget _storage(BuildContext context) {
    final config = Services.of(context).config;
    final hours = config.epochDurationHours;
    final options = <int>{
      1,
      ((30 * 24) / hours).round().clamp(1, config.maxEpochs),
      config.epochs.clamp(1, config.maxEpochs),
      config.maxEpochs,
    }.toList()..sort();
    final quote = _quote;
    final String cost;
    if (_quoting) {
      cost = 'Working out the cost…';
    } else if (quote != null && quote.epochs == _epochs) {
      cost = 'About ${formatWal(quote.walFrost)}';
    } else if (_quoteFailed) {
      cost = 'Your wallet shows the cost';
    } else {
      cost = '';
    }
    final period = DropdownButtonFormField<int>(
      initialValue: _epochs,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Keep it stored for',
        floatingLabelBehavior: FloatingLabelBehavior.always,
      ),
      // The menu marks the suggested period; the closed field shows only
      // the period, so it fits a phone.
      selectedItemBuilder: (context) => [
        for (final n in options)
          Text(formatEpochs(n, hours), overflow: TextOverflow.ellipsis),
      ],
      items: [
        for (final n in options)
          DropdownMenuItem(
            value: n,
            child: Text(
              formatEpochs(n, hours) +
                  (n == config.epochs ? ' · suggested' : ''),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      // The period is fixed once the wallet has paid.
      onChanged:
          _busy || _paid || _walletCheckRequired || _recoverySession != null
          ? null
          : (n) => _setEpochs(n!),
    );
    final costBlock = Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Cost'),
          const SizedBox(height: S.x1),
          Text(
            cost.isEmpty ? '…' : cost,
            style: T.mono.copyWith(color: C.ink, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: S.x1),
          Text(
            _quoteFailed
                ? 'The cost could not be worked out just now. Your wallet '
                      'shows the exact amount before you approve.'
                : '${quote == null || _quoting ? 'Plus SUI for the relay fee' : 'Plus ${formatSui(quote.relayTipMist)} for the relay'} and gas. Your wallet pays and keeps the '
                      'file; Credence never holds your funds.',
            style: T.small,
          ),
        ],
      ),
    );
    final desktop = Breakpoints.isDesktop(context);
    return Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: C.paper,
        border: Border.all(color: C.rule),
        borderRadius: BorderRadius.circular(R.panel),
      ),
      child: desktop
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: period),
                const SizedBox(width: S.x8),
                Expanded(flex: 6, child: costBlock),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                period,
                const SizedBox(height: S.x4),
                costBlock,
              ],
            ),
    );
  }

  Widget _problemNotice(BuildContext context) {
    final account = Services.of(context).account;
    final retry = FilledButton.icon(
      onPressed: _busy ? null : _submit,
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text('Try again'),
    );
    if (_signedOut) {
      return Notice(
        tone: Tone.danger,
        title: _paid
            ? 'The file is on Walrus, but the record was not saved'
            : 'Sign in again to store this file',
        body:
            'Your sign-in has ended. Sign in again with the same wallet; '
            'the details you entered stay here'
            '${_paid ? ', and you will not pay again' : ''}.',
        action: FilledButton.icon(
          onPressed: () async {
            if (await showSignInDialog(context) && mounted) {
              setState(() {
                _signedOut = false;
                _problem = null;
                _error = null;
              });
            }
          },
          icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
          label: const Text('Sign in again'),
        ),
      );
    }
    final paidNote = _paid
        ? ' The payment already went through: trying again only asks your '
              'wallet to finish, and you will not pay twice.'
        : '';
    return Semantics(
      liveRegion: true,
      child: switch (_problem!) {
        _Problem.declined => Notice(
          tone: Tone.info,
          title: 'You declined in your wallet',
          body:
              '${_error ?? 'The request was declined.'} '
              '${_paid ? 'The payment already went through and the file is '
                        'uploaded, but it is not finished yet. Trying again '
                        'only asks your wallet to finish, and you will not '
                        'pay twice.' : 'Nothing was stored or paid.'}',
          action: retry,
        ),
        _Problem.wallet => Notice(
          tone: Tone.danger,
          title: 'Your wallet did not finish',
          body: '${_error ?? ''}$paidNote'.trim(),
          action: retry,
        ),
        _Problem.noWal => Notice(
          tone: Tone.warning,
          title: 'Your wallet needs a little WAL',
          body:
              'Your wallet needs a little WAL to pay for storage'
              '${_quote == null ? '' : ' (about ${formatWal(_quote!.walFrost)})'}'
              '. In Slush, open Swap and change a little SUI into WAL, then '
              'try again. Nothing was paid.',
          action: retry,
        ),
        _Problem.wrongAccount => Notice(
          tone: Tone.warning,
          title: 'Use the wallet account you signed in with',
          body:
              'Your wallet is on '
              '${_error == null ? 'no account' : shortAddress(_error!)}, but '
              'you signed in as ${shortAddress(account.address ?? '')}. '
              'Switch accounts in your wallet, then try again.',
          action: retry,
        ),
        _Problem.unknownOutcome => Notice(
          tone: Tone.danger,
          title: _recoverySession == null
              ? 'Check your wallet before trying again'
              : 'The transaction is not confirmed yet',
          body: _recoverySession == null
              ? walletSubmissionUnknownMessage
              : 'Retry to check the saved transaction and continue this upload.',
          action: _recoverySession == null ? null : retry,
        ),
        _Problem.storing => Notice(
          tone: Tone.danger,
          title: 'Storing did not finish',
          body:
              'Walrus or the network did not answer in time. Check your '
              'connection and try again.$paidNote',
          action: retry,
        ),
        _Problem.listing => Notice(
          tone: Tone.danger,
          title: _listed
              ? 'The file is on Walrus, but the record was not saved'
              : _stored != null
              ? 'The file is on Walrus, but Credence has not listed it yet'
              : 'The file could not be stored',
          body:
              '${_error ?? ''}'
              '${_stored != null ? ' Trying again does not pay again.' : ''}',
          action: retry,
        ),
      },
    );
  }

  Widget _fileSection(BuildContext context) {
    final file = _file;
    if (file == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FileDropZone(
            title: 'Drop the document here',
            help:
                'PDF, PNG, JPEG or WebP, up to '
                '${formatBytes(Services.of(context).config.maxUploadBytes)}.',
            accept: storableAccept,
            onFile: _onFile,
            enabled:
                !_busy && !_walletCheckRequired && _recoverySession == null,
          ),
          if (_fileError != null) ...[
            const SizedBox(height: S.x3),
            Semantics(
              liveRegion: true,
              child: Notice(
                tone: Tone.danger,
                title: 'This file cannot be stored',
                body: _fileError,
              ),
            ),
          ],
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(
        color: C.paper,
        border: Border.all(color: C.rule),
        borderRadius: BorderRadius.circular(R.panel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _contentType == 'application/pdf'
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
                color: C.ledger,
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: T.smallStrong,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${storableTypes[_contentType] ?? 'File'} · '
                      '${formatBytes(file.size)}',
                      style: T.small,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed:
                    _busy ||
                        _paid ||
                        _walletCheckRequired ||
                        _recoverySession != null
                    ? null
                    : () => setState(() {
                        _file = null;
                        _sha = null;
                        _forgetStorage();
                        _quote = null;
                        _phase = UploadPhase.idle;
                      }),
                child: const Text('Change'),
              ),
            ],
          ),
          const SizedBox(height: S.x3),
          const Eyebrow('SHA-256 fingerprint'),
          const SizedBox(height: S.x1),
          if (_sha == null) ...[
            Semantics(
              label: 'Computing fingerprint',
              value: '${(_hashProgress * 100).round()} percent',
              child: LinearProgressIndicator(value: _hashProgress),
            ),
            const SizedBox(height: S.x1),
            const Text('Computing on this device…', style: T.small),
          ] else
            FingerprintText(_sha!, style: T.monoSmall),
        ],
      ),
    );
  }

  Widget _fields(BuildContext context) {
    final enabled = !_busy;
    InputDecoration deco(String label, String field, {String? hint}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: _fieldErrors[field],
          floatingLabelBehavior: FloatingLabelBehavior.always,
          counterText: '',
        );
    String? required(String? v, String what) =>
        (v ?? '').trim().isEmpty ? 'Enter the $what.' : null;
    return Column(
      children: [
        TextFormField(
          controller: _title,
          enabled: enabled,
          maxLength: 120,
          decoration: deco(
            'Title',
            'title',
            hint: 'e.g. Certificate of completion',
          ),
          validator: (v) => required(v, 'title'),
        ),
        const SizedBox(height: S.x4),
        TextFormField(
          controller: _issuer,
          enabled: enabled,
          maxLength: 120,
          decoration: deco(
            'Issued by',
            'issuerName',
            hint: 'e.g. Northgate Coding Club',
          ),
          validator: (v) => required(v, 'issuer name'),
        ),
        const SizedBox(height: S.x4),
        TextFormField(
          controller: _recipient,
          enabled: enabled,
          maxLength: 120,
          decoration: deco(
            'Issued to',
            'recipientName',
            hint: 'e.g. Ada Okafor',
          ),
          validator: (v) => required(v, 'recipient name'),
        ),
        const SizedBox(height: S.x4),
        IssueDateField(
          controller: _date,
          enabled: enabled,
          errorText: _fieldErrors['issueDate'],
        ),
        const SizedBox(height: S.x4),
        TextFormField(
          controller: _notes,
          enabled: enabled,
          maxLength: 1000,
          minLines: 2,
          maxLines: 4,
          decoration: deco(
            'Notes (optional)',
            'notes',
            hint:
                'Certificate number, grade, or anything a checker should know',
          ),
        ),
      ],
    );
  }

  Widget _progress() {
    // Steps in order; the current one is active, earlier ones are done.
    final steps = <(String, String?)>[
      ('Fingerprint computed on this device', null),
      ('Preparing the file', null),
      (
        'Approve the payment in your wallet',
        _quote == null
            ? 'Your wallet shows the amount: WAL for storage, SUI for the relay and gas.'
            : 'About ${formatWal(_quote!.walFrost)} for storage, '
                  '${formatSui(_quote!.relayTipMist)} for the relay, plus gas.',
      ),
      ('Uploading to Walrus', null),
      ('Approve once more to finish', 'This certifies the file. Gas only.'),
      ('Checking it on Sui and saving the record', null),
    ];
    final current = switch (_phase) {
      UploadPhase.storing => switch (_stage) {
        StorageStage.preparing || null => 1,
        StorageStage.approvePayment => 2,
        StorageStage.uploading => 3,
        StorageStage.approveFinish => 4,
      },
      _ => 5,
    };
    final waitingForWallet = current == 2 || current == 4;
    final uploading = current == 3;
    final status = switch (current) {
      1 => 'Preparing…',
      2 => 'Approve the payment in your wallet',
      3 => 'Uploading to Walrus, ${(_uploaded * 100).round()} percent',
      4 => 'Approve once more to finish',
      _ =>
        _phase == UploadPhase.checking
            ? 'Checking the file on Sui'
            : 'Saving the record',
    };

    Widget step(int i) {
      final (text, detail) = steps[i];
      final done = i < current;
      final active = i == current;
      final wallet = active && (i == 2 || i == 4);
      return Padding(
        padding: const EdgeInsets.only(bottom: S.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              done
                  ? Icons.check_circle
                  : wallet
                  ? Icons.account_balance_wallet_outlined
                  : active
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: done || active ? C.ledger : C.inkFaint,
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: active ? T.smallStrong : T.small),
                  if (active && detail != null) Text(detail, style: T.small),
                  if (active && i == 3) ...[
                    const SizedBox(height: S.x2),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _uploaded,
                            minHeight: 4,
                          ),
                        ),
                        const SizedBox(width: S.x3),
                        Text(
                          '${(_uploaded * 100).round()}%',
                          style: T.monoSmall.copyWith(color: C.ink),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Semantics(
      liveRegion: true,
      label: status,
      child: Container(
        padding: const EdgeInsets.all(S.x4),
        decoration: BoxDecoration(
          color: waitingForWallet ? C.mint : C.surface,
          border: Border.all(color: waitingForWallet ? C.ledger : C.rule),
          borderRadius: BorderRadius.circular(R.panel),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (waitingForWallet) ...[
              Text(status, style: T.h3.copyWith(color: C.ledger)),
              const SizedBox(height: S.x1),
              Text(
                current == 2
                    ? 'Nothing is stored or paid until you approve.'
                    : 'The file is uploaded. One more approval and it is '
                          'stored.',
                style: T.small,
              ),
              const SizedBox(height: S.x3),
            ] else if (!uploading) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: S.x3),
            ],
            for (var i = 0; i < steps.length; i++) step(i),
          ],
        ),
      ),
    );
  }

  Widget _success(BuildContext context, DocumentRecord record) {
    final links = Services.of(context).links;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Notice(
              tone: Tone.success,
              title: 'Stored: ${record.title}',
              body:
                  'Your wallet paid for the file and owns it on Walrus; the '
                  'record is saved. Share the check link with '
                  '${record.recipientName}.',
            ),
          ),
          const SizedBox(height: S.x4),
          LinkField(label: 'Check link', url: links.document(record.id)),
          const SizedBox(height: S.x4),
          Wrap(
            spacing: S.x3,
            runSpacing: S.x3,
            children: [
              FilledButton(
                onPressed: () => context.go('/d/${record.id}'),
                child: const Text('Open check page'),
              ),
              OutlinedButton(
                onPressed: _reset,
                child: const Text('Add another document'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
