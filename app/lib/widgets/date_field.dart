import 'package:flutter/material.dart';

import '../util/format.dart';

/// Validates an issue date typed as YYYY-MM-DD. Returns an error or null.
String? validateIssueDate(String? value, {DateTime? now}) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Enter the issue date.';
  final date = parseIsoDate(text);
  if (date == null) return 'Use the form YYYY-MM-DD, for example 2026-05-31.';
  final today = (now ?? DateTime.now()).toUtc();
  if (date.isAfter(DateTime.utc(today.year, today.month, today.day + 1))) {
    return 'The issue date cannot be in the future.';
  }
  if (date.year < 1900) return 'Enter a date after 1900.';
  return null;
}

/// A date typed as YYYY-MM-DD, with a calendar button for pointer users.
class IssueDateField extends StatelessWidget {
  const IssueDateField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.errorText,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = parseIsoDate(controller.text) ?? now;
    final first = DateTime(1900);
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(first)
          ? first
          : current.isAfter(now)
          ? now
          : current,
      firstDate: first,
      lastDate: now,
      helpText: 'Issue date',
    );
    if (picked != null && context.mounted) controller.text = isoDate(picked);
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.datetime,
    decoration: InputDecoration(
      labelText: 'Issue date',
      hintText: 'YYYY-MM-DD',
      helperText: 'The date on the document.',
      errorText: errorText,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      suffixIcon: IconButton(
        tooltip: 'Pick a date',
        onPressed: enabled ? () => _pick(context) : null,
        icon: const Icon(Icons.calendar_today_outlined, size: 20),
      ),
    ),
    validator: validateIssueDate,
  );
}
