import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/core/validators.dart';
import 'package:mynet/screens/login_screen.dart';
import 'package:mynet/widgets/code_entry.dart';
import 'package:mynet/widgets/common.dart';

/// Two steps on one screen, like login's email-code step: enter the email, then the emailed code plus
/// a new password. A successful reset does NOT sign the user in: it sends them back to the login screen
/// to sign in with the new password (the server has ended all their old logins by then anyway).
class ForgotPasswordScreen extends StatefulWidget {
  final String initialEmail; // carried over from whatever was already typed on the login screen
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeSent = false, _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
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
      if (!_codeSent) {
        await api.requestPasswordReset(_email.text.trim());
        if (mounted) setState(() => _codeSent = true); // show the code + new password fields
        return;
      }
      await api.resetPassword(_email.text.trim(), _code.text.trim(), _password.text);
      if (!mounted) return;
      // A fresh, empty login screen, replacing this screen and the old login one.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (r) => false,
      );
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Password reset. Please sign in with your new password.')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_codeSent ? 'Enter the code' : 'Reset password')),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              if (!_codeSent) ...[
                const Text("Enter the email you signed up with and we'll send you a code to reset your password."),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _email,
                  autofillHints: [AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                    return null;
                  },
                ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: 'We sent a code to ${_email.text.trim()}.',
                  busy: _busy,
                  onResend: () => api.requestPasswordReset(_email.text.trim()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  autofillHints: [AutofillHints.newPassword],
                  obscureText: _hide,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    helperText: 'Password must be 8 characters or more with an uppercase character and a number',
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Show password' : 'Hide password',
                      icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) {
                    final value = v ?? '';
                    if (value.isEmpty) return 'Enter a new password';
                    final problem = newPasswordProblem(value);
                    if (problem != null) return problem;
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  autofillHints: [AutofillHints.newPassword],
                  obscureText: _hide,
                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                  validator: (v) => v != _password.text ? "Passwords don't match" : null,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _codeSent = false),
                  child: const Text('Use a different email'),
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
                child: Text(_busy ? 'Please wait...' : (_codeSent ? 'Reset password' : 'Send code')),
              ),
            ]),
          )),
        ),
      );
}
