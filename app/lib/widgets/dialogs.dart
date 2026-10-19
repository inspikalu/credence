import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/services.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'common.dart';
import 'date_field.dart';

/// Edits the non-file details of a document. A note is required and kept in
/// the public edit history.
Future<DocumentRecord?> showEditDocumentDialog(
  BuildContext context, {
  required DocumentRecord document,
}) => showDialog<DocumentRecord>(
  context: context,
  animationStyle: Motion.dialogStyle(context),
  builder: (_) => _EditDocumentDialog(document: document),
);

class _EditDocumentDialog extends StatefulWidget {
  const _EditDocumentDialog({required this.document});

  final DocumentRecord document;

  @override
  State<_EditDocumentDialog> createState() => _EditDocumentDialogState();
}

class _EditDocumentDialogState extends State<_EditDocumentDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.document.title);
  late final _issuer = TextEditingController(text: widget.document.issuerName);
  late final _recipient = TextEditingController(
    text: widget.document.recipientName,
  );
  late final _date = TextEditingController(text: widget.document.issueDate);
  late final _notes = TextEditingController(text: widget.document.notes);
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _issuer, _recipient, _date, _notes, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _changes() {
    final d = widget.document;
    final out = <String, String>{};
    void diff(String field, String now, String before) {
      if (now.trim() != before) out[field] = now.trim();
    }

    diff('title', _title.text, d.title);
    diff('issuerName', _issuer.text, d.issuerName);
    diff('recipientName', _recipient.text, d.recipientName);
    diff('issueDate', _date.text, d.issueDate);
    diff('notes', _notes.text, d.notes);
    return out;
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!(_form.currentState?.validate() ?? false)) return;
    final changes = _changes();
    if (changes.isEmpty) {
      setState(() => _error = 'Nothing changed. Edit a detail before saving.');
      return;
    }
    setState(() => _busy = true);
    try {
      final updated = await Services.of(context).api.editDocument(
        widget.document.id,
        changes: changes,
        note: _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, updated);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) =>
        (v ?? '').trim().isEmpty ? 'This cannot be empty.' : null;
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      counterText: '',
    );
    return AlertDialog(
      title: const Text('Edit details'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The file and its fingerprint cannot change. To replace the '
                'file, revoke this document and add a new one.',
                style: T.small,
              ),
              const SizedBox(height: S.x4),
              TextFormField(
                controller: _title,
                maxLength: 120,
                decoration: deco('Title'),
                validator: required,
              ),
              const SizedBox(height: S.x3),
              TextFormField(
                controller: _issuer,
                maxLength: 120,
                decoration: deco('Issued by'),
                validator: required,
              ),
              const SizedBox(height: S.x3),
              TextFormField(
                controller: _recipient,
                maxLength: 120,
                decoration: deco('Issued to'),
                validator: required,
              ),
              const SizedBox(height: S.x3),
              IssueDateField(controller: _date),
              const SizedBox(height: S.x3),
              TextFormField(
                controller: _notes,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration: deco('Notes'),
              ),
              const SizedBox(height: S.x4),
              TextFormField(
                controller: _note,
                maxLength: 280,
                decoration: const InputDecoration(
                  labelText: 'Why are you changing this?',
                  hintText: 'Corrected the spelling of the recipient’s name',
                  helperText: 'Shown in the edit history on the check page.',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  counterText: '',
                ),
                validator: (v) => (v ?? '').trim().length < 3
                    ? 'Add a short note about the change.'
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: S.x3),
                Notice(tone: Tone.danger, title: 'Not saved', body: _error),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save changes'),
        ),
      ],
    );
  }
}

/// Revokes a document after confirmation. Returns the updated record.
Future<DocumentRecord?> showRevokeDialog(
  BuildContext context, {
  required DocumentRecord document,
}) => showDialog<DocumentRecord>(
  context: context,
  animationStyle: Motion.dialogStyle(context),
  builder: (_) => _RevokeDialog(document: document),
);

class _RevokeDialog extends StatefulWidget {
  const _RevokeDialog({required this.document});

  final DocumentRecord document;

  @override
  State<_RevokeDialog> createState() => _RevokeDialogState();
}

class _RevokeDialogState extends State<_RevokeDialog> {
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _revoke() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await Services.of(
        context,
      ).api.revokeDocument(widget.document.id, reason: _reason.text.trim());
      if (mounted) Navigator.pop(context, updated);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = Services.of(context).config;
    final end = widget.document.endEpoch;
    return AlertDialog(
      title: const Text('Revoke this document?'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.document.title, style: T.h3),
            const SizedBox(height: S.x3),
            Text(
              'Its check page will say “Revoked by the vault owner on '
              '${formatDate(DateTime.now())}” and it will leave the public '
              'list. The record stays visible, so anyone holding a copy can see '
              'it was revoked. This cannot be undone.',
              style: T.body,
            ),
            const SizedBox(height: S.x3),
            Text(
              'Revoking does not delete the file. It stays on '
              '${config.networkLabel} until its storage period ends'
              '${end == null ? '' : ' (epoch $end)'}, or until the wallet '
              'that owns it deletes it.',
              style: T.small,
            ),
            const SizedBox(height: S.x4),
            TextField(
              controller: _reason,
              maxLength: 280,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Reason (optional, shown publicly)',
                hintText: 'Issued in error',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                counterText: '',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: S.x3),
              Notice(tone: Tone.danger, title: 'Not revoked', body: _error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: dangerButtonStyle,
          onPressed: _busy ? null : _revoke,
          child: Text(_busy ? 'Revoking…' : 'Revoke document'),
        ),
      ],
    );
  }
}

/// Edits the vault's name, about text and website.
Future<Vault?> showEditVaultDialog(
  BuildContext context, {
  required Vault vault,
}) => showDialog<Vault>(
  context: context,
  animationStyle: Motion.dialogStyle(context),
  builder: (_) => _EditVaultDialog(vault: vault),
);

class _EditVaultDialog extends StatefulWidget {
  const _EditVaultDialog({required this.vault});

  final Vault vault;

  @override
  State<_EditVaultDialog> createState() => _EditVaultDialogState();
}

class _EditVaultDialogState extends State<_EditVaultDialog> {
  late final _name = TextEditingController(text: widget.vault.name);
  late final _about = TextEditingController(text: widget.vault.about);
  late final _website = TextEditingController(text: widget.vault.website);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _website.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await Services.of(context).api.updateVault(
        widget.vault.id,
        name: _name.text.trim(),
        about: _about.text.trim(),
        website: _website.text.trim(),
      );
      if (mounted) Navigator.pop(context, updated);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Vault details'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 80,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Name',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                counterText: '',
              ),
            ),
            const SizedBox(height: S.x3),
            TextField(
              controller: _about,
              maxLength: 280,
              minLines: 2,
              maxLines: 4,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'About (optional)',
                hintText: 'Weekend coding classes and project nights',
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
            const SizedBox(height: S.x3),
            TextField(
              controller: _website,
              maxLength: 120,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Website (optional)',
                helperText:
                    'Link to this vault from your own site so checkers can '
                    'confirm it is yours.',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                counterText: '',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: S.x3),
              Notice(tone: Tone.danger, title: 'Not saved', body: _error),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
