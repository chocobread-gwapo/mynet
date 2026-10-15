import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';

class ReportIssueScreen extends StatefulWidget {
  final int accountId;
  const ReportIssueScreen({super.key, required this.accountId});
  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  static const _categories = ['Connection', 'Billing', 'Account', 'Other'];
  String _category = _categories.first;
  final _message = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_message.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Please describe the issue first.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await api.reportIssue(widget.accountId, _category, _message.text.trim());
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('Thanks — your report was submitted.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Report an Issue')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final c in _categories) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'What happened?', alignLabelWithHint: true),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: bigButton,
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Sending...' : 'Submit'),
          ),
        ]),
      );
}
