import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mynet/core/theme.dart';

/// Shared "enter the code we sent" block used by login/register (email), account linking (SMS), and
/// payment confirmation (either). Shows a live 3-minute countdown matching the server's OTP_TTL_SECONDS,
/// and a resend link — calling [onResend] re-sends a fresh code through the same endpoint that sent the
/// first one, which is all a "resend" is server-side (see confirm_payment/confirm_link/login's comments).
class CodeEntry extends StatefulWidget {
  final TextEditingController controller;
  final String description; // full sentence, e.g. "We sent a code to jozua@gmail.com."
  final Future<void> Function() onResend;
  final bool busy; // disables Resend while the parent form's main action is already in flight
  final String? Function(String?)? validator; // left null outside a Form (e.g. the payment dialog)
  const CodeEntry({
    super.key,
    required this.controller,
    required this.description,
    required this.onResend,
    required this.busy,
    this.validator,
  });

  @override
  State<CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends State<CodeEntry> {
  static const _codeLifetime = Duration(minutes: 3);
  var _expiresAt = DateTime.now().add(_codeLifetime);
  Timer? _ticker;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {}); // just to re-render the countdown text
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      await widget.onResend();
      if (!mounted) return;
      setState(() => _expiresAt = DateTime.now().add(_codeLifetime));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code resent.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _expiresAt.difference(DateTime.now());
    final expired = remaining.isNegative;
    final mm = remaining.inMinutes.clamp(0, 99);
    final ss = (remaining.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.description),
      const SizedBox(height: 4),
      Text(
        expired ? 'Code expired — tap Resend below.' : 'Expires in $mm:$ss',
        style: TextStyle(fontSize: 12, color: expired ? kWarn : Theme.of(context).hintColor),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: widget.controller,
        autofillHints: const [AutofillHints.oneTimeCode],
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Verification code'),
        validator: widget.validator,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: (widget.busy || _resending) ? null : _resend,
          child: Text(_resending ? 'Sending...' : 'Resend code'),
        ),
      ),
    ]);
  }
}
