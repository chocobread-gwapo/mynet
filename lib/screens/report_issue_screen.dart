import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/widgets/common.dart';

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

  // The customer's earlier reports with any reply from staff. Checked again every few seconds while this screen is
  // open, so a reply shows up without leaving and coming back.
  List<Map<String, dynamic>>? _reports;
  String? _reportsError;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _loadReports();
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) => _loadReports());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _message.dispose();
    super.dispose();
  }

  Future<void> _loadReports() async {
    try {
      final list = await api.issues(widget.accountId);
      if (!mounted) return;
      setState(() {
        _reports = [for (final e in list) Map<String, dynamic>.from(e as Map)];
        _reportsError = null;
      });
    } catch (e) {
      if (mounted && _reports == null) setState(() => _reportsError = '$e');
    }
  }

  Widget _reportCard(Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = r['status'] == 'RESOLVED';
    final reply = (r['reply'] as String?)?.trim();
    final chipColor = resolved ? kGood : kWarn;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${r['category']}  ·  ${fmtDate('${r['created_at']}')}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: chipColor.withAlpha(28), borderRadius: BorderRadius.circular(20)),
            child: Text(resolved ? 'Resolved' : 'Open',
                style: TextStyle(color: chipColor, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('${r['message']}'),
        if (reply != null && reply.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.primary.withAlpha(24), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Reply from NetPulse', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
              const SizedBox(height: 4),
              Text(reply),
            ]),
          ),
        ] else if (resolved) ...[
          const SizedBox(height: 8),
          const Text('Marked as resolved.'),
        ],
      ]),
    );
  }

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_message.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Please describe the issue first.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await api.reportIssue(widget.accountId, _category, _message.text.trim());
      _message.clear(); // stay on this screen so the new report appears in the list below
      await _loadReports();
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
          const SizedBox(height: 24),
          Text('Your reports', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_reports == null && _reportsError == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else if (_reports == null)
            Panel(child: Text(_reportsError!))
          else if (_reports!.isEmpty)
            const Panel(child: Text('You have not reported anything yet. Replies from our team will show up here.'))
          else
            for (final r in _reports!) _reportCard(r),
        ]),
      );
}