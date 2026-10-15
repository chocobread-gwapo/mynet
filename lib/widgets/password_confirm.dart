import 'package:flutter/material.dart';

import 'package:mynet/core/session.dart';
import 'package:mynet/screens/forgot_password_screen.dart';
import 'package:mynet/widgets/password_field.dart';

/// True when this login has a password to confirm with. A Google-only login doesn't yet, so it's offered
/// the set-a-password flow instead and this returns false.
Future<bool> ensurePassword(BuildContext context, Map<String, dynamic> me) async {
  if (me['has_password'] == true) return true;
  final setNow = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Set a password first'),
      content: const Text("This needs your password, and you signed in with Google so you don't have one yet. "
          "Set one now: we'll email you a code, and you'll sign in again afterwards."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Set password')),
      ],
    ),
  );
  if (setNow == true && context.mounted) openSetPasswordScreen(context, me);
  return false;
}

void openSetPasswordScreen(BuildContext context, Map<String, dynamic> me) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ForgotPasswordScreen(initialEmail: '${me['email']}')));
}

/// The usual "type your password to confirm" step for any change: checks the login has a password,
/// shows the dialog, and runs [action] with it. True once the action has gone through.
Future<bool> confirmWithPassword(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String busyLabel,
  required Future<void> Function(String password) action,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  Map<String, dynamic> me;
  try {
    me = await api.me();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
  if (!context.mounted || !await ensurePassword(context, me) || !context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => PasswordConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      busyLabel: busyLabel,
      action: action,
    ),
  );
  return done == true;
}

/// Asks for the password one more time before something is changed or removed. [action] runs with the
/// typed password (and throws if the server refuses it); the dialog pops true once it succeeds.
class PasswordConfirmDialog extends StatefulWidget {
  final String title, message, confirmLabel, busyLabel;
  final bool destructive;
  final Future<void> Function(String password) action;
  const PasswordConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.busyLabel,
    required this.action,
    this.destructive = false,
  });
  @override
  State<PasswordConfirmDialog> createState() => _PasswordConfirmDialogState();
}

class _PasswordConfirmDialogState extends State<PasswordConfirmDialog> {
  final _password = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password to confirm');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.action(_password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${widget.message}\n\nEnter your password to confirm.'),
            const SizedBox(height: 16),
            passwordField(
              controller: _password,
              autofillHints: [AutofillHints.password],
              label: 'Password',
              hide: _hide,
              onToggle: () => setState(() => _hide = !_hide),
              validator: (_) => null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: widget.destructive
                ? FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318), foregroundColor: Colors.white)
                : null,
            onPressed: _busy ? null : _confirm,
            child: Text(_busy ? widget.busyLabel : widget.confirmLabel),
          ),
        ],
      );
}