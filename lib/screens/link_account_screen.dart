import 'package:flutter/material.dart';

import 'package:mynet/core/config.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/widgets/common.dart';

class LinkAccountScreen extends StatefulWidget {
  /// Called after a request has been filed, so the caller can reload (it may now have a pending request to show).
  final Future<void> Function() onLinked;
  const LinkAccountScreen({super.key, required this.onLinked});
  @override
  State<LinkAccountScreen> createState() => _LinkAccountScreenState();
}

class _LinkAccountScreenState extends State<LinkAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _no = TextEditingController();
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _declined = []; // earlier requests that were turned down, shown as a note

  @override
  void initState() {
    super.initState();
    _loadDeclined();
  }

  Future<void> _loadDeclined() async {
    try {
      final all = await api.linkRequests();
      final declined = [for (final r in all) if (r['status'] == 'REJECTED') Map<String, dynamic>.from(r as Map)];
      if (mounted) setState(() => _declined = declined);
    } catch (_) {
      // Only a courtesy note: never block linking over it.
    }
  }

  Future<void> _dismiss(Map<String, dynamic> r) async {
    setState(() => _declined.remove(r));
    try {
      await api.dismissLinkRequest(r['id'] as int);
    } catch (_) {}
  }

  @override
  void dispose() {
    _no.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.requestLink(_no.text.trim());
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RequestReceivedScreen(onBack: () => Navigator.of(context).pop()),
      ));
      await widget.onLinked();
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => signOut(context))],
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
              const Text('Link your Account', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text("Enter the account number on your bill and we'll link it to your login once we've "
                  'checked it.'),
              const SizedBox(height: 24),
              for (final r in _declined)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Panel(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.info_outline, color: Color(0xFFB42318)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Your request to link account ${r['account_no']} was declined."
                          "${(r['reason'] as String?)?.trim().isNotEmpty == true ? ' Reason: ${r['reason']}.' : ''} "
                          'If you think that was a mistake, please contact us. You can check the number and send a new request below.',
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        icon: const Icon(Icons.close),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _dismiss(r),
                      ),
                    ]),
                  ),
                ),
              TextFormField(
                controller: _no,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Account number', hintText: 'DEMO-000001'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your account number' : null,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
                ),
              const SizedBox(height: 20),
              FilledButton(
                style: bigButton,
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'Please wait...' : 'Submit'),
              ),
            ]),
          ),
        ),
      );
}

/// "Request Received!": shown right after a link request is filed, and again whenever the login has no
/// account yet but a request is still waiting.
class RequestReceivedScreen extends StatelessWidget {
  final VoidCallback onBack;
  final String buttonLabel;
  final Widget? extra; // optional second action under the message (e.g. "Check status")
  const RequestReceivedScreen({super.key, required this.onBack, this.buttonLabel = 'Back to Menu', this.extra});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Spacer(flex: 2),
              const Text(appName, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
              const SizedBox(height: 32),
              const Text('Request Received!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text(
                'We have received your Link Account request, and we will process it within 24 hours.',
                textAlign: TextAlign.center,
              ),
              if (extra != null) ...[const SizedBox(height: 12), extra!],
              const Spacer(flex: 3),
              FilledButton(style: bigButton, onPressed: onBack, child: Text(buttonLabel)),
            ]),
          ),
        ),
      );
}
