import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/core/validators.dart';
import 'package:mynet/widgets/password_field.dart';

/// Changes the password from inside the app: current password, then the new one. The server signs out
/// the user's other devices and gives this one a fresh login, so nobody has to sign in again here.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false, _hideCurrent = true, _hideNew = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.changePassword(_current.text, _new.text);
      if (!mounted) return;
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Password changed. Your other devices were signed out.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              passwordField(
                controller: _current,
                autofillHints: [AutofillHints.password],
                label: 'Current password',
                hide: _hideCurrent,
                onToggle: () => setState(() => _hideCurrent = !_hideCurrent),
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null,
              ),
              const SizedBox(height: 12),
              passwordField(
                controller: _new,
                autofillHints: [AutofillHints.newPassword],
                label: 'New password',
                helper: 'Password must be 8 characters or more with an uppercase character and a number',
                hide: _hideNew,
                onToggle: () => setState(() => _hideNew = !_hideNew),
                validator: (v) {
                  final value = v ?? '';
                  if (value.isEmpty) return 'Enter a new password';
                  final problem = newPasswordProblem(value);
                    if (problem != null) return problem;
                  if (value == _current.text) return "Choose a password that's different from your current one";
                  return null;
                },
              ),
              const SizedBox(height: 12),
              passwordField(
                controller: _confirm,
                autofillHints: [AutofillHints.newPassword],
                label: 'Confirm new password',
                hide: _hideNew,
                onToggle: () => setState(() => _hideNew = !_hideNew),
                validator: (v) => v != _new.text ? "Passwords don't match" : null,
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
                child: Text(_busy ? 'Please wait...' : 'Change password'),
              ),
            ]),
          )),
        ),
      );
}
