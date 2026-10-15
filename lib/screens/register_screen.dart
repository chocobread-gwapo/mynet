import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:mynet/core/config.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/core/validators.dart';
import 'package:mynet/legal.dart';
import 'package:mynet/screens/shell.dart';
import 'package:mynet/widgets/code_entry.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/password_field.dart';

/// The sign-up form: email, password (typed twice), mobile number, name, and the two agreements.
/// Like login it has a second step when the server emails a code to confirm the address.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _mobile = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _code = TextEditingController();
  bool _hide = true, _busy = false, _verifying = false;
  bool _privacy = false, _terms = false, _agreeError = false;
  bool _remember = false; // follows the login screen's "Remember me" box
  String? _error;

  @override
  void initState() {
    super.initState();
    api.loadRememberMe().then((v) => _remember = v);
  }

  @override
  void dispose() {
    for (final c in [_email, _password, _confirm, _mobile, _first, _last, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState!.validate();
    if (!_verifying) {
      setState(() => _agreeError = !(_privacy && _terms));
      if (!valid || !(_privacy && _terms)) return;
    } else if (!valid) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_verifying) {
        final verificationRequired = await api.register(
          email: _email.text.trim(),
          password: _password.text,
          firstName: _first.text.trim(),
          lastName: _last.text.trim(),
          mobile: _mobile.text.trim(),
          remember: _remember,
        );
        if (verificationRequired) {
          setState(() => _verifying = true);
          return;
        }
      } else {
        await api.confirmEmailVerification(_email.text.trim(), _code.text.trim(), remember: _remember);
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Shell()), (r) => false);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showDocument(bool privacy) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => privacy ? const LegalScreen.privacy() : const LegalScreen.terms(),
      ));

  Widget _agreement({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String before,
    required String link,
    required bool privacy,
  }) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: value, onChanged: _busy ? null : (v) => onChanged(v ?? false)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: before),
              TextSpan(
                text: link,
                style: TextStyle(
                  // A link blue that stays readable on both themes, bold and underlined so it clearly reads as tappable.
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF8AB4F8)
                      : const Color(0xFF1A5FD0),
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                ),
                recognizer: TapGestureRecognizer()..onTap = () => _showDocument(privacy),
              ),
              const TextSpan(text: '.'),
            ])),
          ),
        ),
      ]);

  String? _required(String? v, String what) => (v == null || v.trim().isEmpty) ? 'Enter your $what' : null;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
              const Text('Registration', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              if (!_verifying) ...[
                TextFormField(
                  controller: _email,
                  autofillHints: [AutofillHints.username, AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email', hintText: 'juandelacruz@gmail.com'),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                passwordField(
                  controller: _password,
                  autofillHints: [AutofillHints.newPassword],
                  label: 'Password',
                  helper: 'Password must be 8 characters or more with an uppercase character and a number',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) {
                    final value = v ?? '';
                    if (value.isEmpty) return 'Enter a password';
                    if (value.length < 8 || !value.contains(RegExp('[A-Z]')) || !value.contains(RegExp('[0-9]'))) {
                      return '8+ characters, an uppercase letter and a number';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                passwordField(
                  controller: _confirm,
                  autofillHints: [AutofillHints.newPassword],
                  label: 'Confirm password',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) => v != _password.text ? "Passwords don't match" : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _mobile,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Mobile number', hintText: '09XX-XXX-XXXX'),
                  validator: mobileValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _first,
                  autofillHints: const [AutofillHints.givenName],
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'First name'),
                  validator: (v) => _required(v, 'first name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _last,
                  autofillHints: const [AutofillHints.familyName],
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Last name'),
                  validator: (v) => _required(v, 'last name'),
                ),
                const SizedBox(height: 16),
                _agreement(
                  value: _privacy,
                  onChanged: (v) => setState(() => _privacy = v),
                  before: 'I understand that $appName will use the information I submit in accordance with its ',
                  link: 'PRIVACY POLICY',
                  privacy: true,
                ),
                _agreement(
                  value: _terms,
                  onChanged: (v) => setState(() => _terms = v),
                  before: 'I have read and understood the ',
                  link: 'TERMS & CONDITIONS',
                  privacy: false,
                ),
                if (_agreeError && !(_privacy && _terms))
                  const Padding(
                    padding: EdgeInsets.only(top: 4, left: 12),
                    child: Text('Please tick both boxes to continue.', style: TextStyle(color: Color(0xFFB42318))),
                  ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: 'We sent a code to ${_email.text.trim()}.',
                  busy: _busy,
                  onResend: () => api.login(_email.text.trim(), _password.text, remember: _remember),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _verifying = false),
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
                child: Text(_busy ? 'Please wait...' : (_verifying ? 'Confirm code' : 'Create account')),
              ),
            ]),
          )),
        ),
      );
}
