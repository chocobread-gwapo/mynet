import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/widgets/code_entry.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/password_field.dart';

/// Changes an email address or a mobile number, which share the same two steps: type the new value with
/// the current password, then enter the code sent to the NEW address / number. Pops with true when done.
class ChangeContactScreen extends StatefulWidget {
  final String title, intro, fieldLabel, successMessage;
  final TextInputType keyboard;
  final String? Function(String?) validator;
  final String Function(String value) codeDescription;
  final Future<void> Function(String value, String password) start;
  final Future<void> Function(String code) confirm;
  const ChangeContactScreen({
    super.key,
    required this.title,
    required this.intro,
    required this.fieldLabel,
    required this.successMessage,
    required this.keyboard,
    required this.validator,
    required this.codeDescription,
    required this.start,
    required this.confirm,
  });
  @override
  State<ChangeContactScreen> createState() => _ChangeContactScreenState();
}

class _ChangeContactScreenState extends State<ChangeContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _value = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false, _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_codeSent) {
        await widget.start(_value.text.trim(), _password.text);
        if (mounted) setState(() => _codeSent = true); // now ask for the code that was just sent
        return;
      }
      await widget.confirm(_code.text.trim());
      if (!mounted) return;
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(widget.successMessage)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_codeSent ? 'Enter the code' : widget.title)),
        body: SafeArea(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              if (!_codeSent) ...[
                Text(widget.intro),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _value,
                  keyboardType: widget.keyboard,
                  decoration: InputDecoration(labelText: widget.fieldLabel),
                  validator: widget.validator,
                ),
                const SizedBox(height: 12),
                passwordField(
                  controller: _password,
                  autofillHints: [AutofillHints.password],
                  label: 'Current password',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null,
                ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: widget.codeDescription(_value.text.trim()),
                  busy: _busy,
                  onResend: () => widget.start(_value.text.trim(), _password.text),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _codeSent = false),
                  child: const Text('Go back'),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
                ),
              const SizedBox(height: 20),
              FilledButton(
                style: bigButton,
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'Please wait...' : (_codeSent ? 'Confirm' : 'Send code')),
              ),
            ]),
          ),
        ),
      );
}
