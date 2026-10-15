import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mynet/api.dart';
import 'package:mynet/core/config.dart';
import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/widgets/code_entry.dart';

Future<void> payNow(BuildContext context, Map<String, dynamic> acct, Future<void> Function() done) async {
  final messenger = ScaffoldMessenger.of(context);
  final amount = acct['amount_due'] as int;
  final channel = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Confirm payment'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text("Pay ${peso(amount)} for your ${acct['plan']['name']} plan? "
            "We'll send a code first to confirm it's you."),
        const SizedBox(height: 16),
        // Equal weight on purpose: neither channel is a "default", so neither gets the filled/primary look.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.pop(c, 'sms'),
          icon: const Icon(Icons.sms_outlined),
          label: const Text('Verify by SMS'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.pop(c, 'email'),
          icon: const Icon(Icons.email_outlined),
          label: const Text('Verify by email'),
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
    ),
  );
  if (channel == null) return;
  // The dialog above awaited user input; confirm we're still on-screen before touching context again.
  if (!context.mounted) return;

  // Shared by both paths below: once a payment has actually been started (whether that took a
  // verification code first or not), opening the checkout / dev-mode handling is identical.
  Future<void> openOrSimulate(Map<String, dynamic> info) async {
    final paymentId = info['payment_id'] as int;
    if (info['real'] == true) {
      final opened = await launchUrl(Uri.parse(info['checkout_url'] as String), mode: LaunchMode.externalApplication);
      if (!opened) throw ApiException("Couldn't open the payment page.");
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _WaitForPaymentDialog(accountId: acct['id'] as int, paymentId: paymentId, onChanged: done),
        );
      }
      return;
    }
    // Dev-mode fallback: no real payment gateway configured on the server yet.
    if (devSimulatePayments) await api.devConfirm(paymentId);
    await done();
    messenger.showSnackBar(const SnackBar(content: Text('Payment received. Thank you!')));
  }

  try {
    final started = await _withLabeledSpinner(
      context,
      label: channel == 'sms' ? 'Sending code by SMS...' : 'Sending code by email...',
      request: () => api.startPayment(acct['id'] as int, amount, channel),
    );
    if (started == null) {
      // A verification code was sent instead of starting the payment directly. The dialog confirms the
      // code itself — retrying inline on a wrong one, same as login/link-account do — and pops with the
      // finished payment info once the server accepts it, or null if the user cancels out of it.
      if (!context.mounted) return;
      final confirmed = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _PaymentCodeDialog(
          accountId: acct['id'] as int,
          channel: channel,
          onResend: () => api.startPayment(acct['id'] as int, amount, channel),
        ),
      );
      if (confirmed == null) return;
      await openOrSimulate(confirmed);
      return;
    }
    await openOrSimulate(started);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// A brief, non-dismissible, labeled spinner. Used for the one gap in the payment flow that's still
/// silent otherwise — picking a channel and waiting for the first code to actually send — since that
/// happens between two dialogs, with no screen underneath to show a "Please wait..." button label on.
Future<T> _withLabeledSpinner<T>(BuildContext context, {required String label, required Future<T> Function() request}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(width: 16),
        Text(label),
      ]),
    ),
  );
  try {
    return await request();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

class _PaymentCodeDialog extends StatefulWidget {
  final int accountId;
  final String channel;
  final Future<void> Function() onResend;
  const _PaymentCodeDialog({required this.accountId, required this.channel, required this.onResend});

  @override
  State<_PaymentCodeDialog> createState() => _PaymentCodeDialogState();
}

class _PaymentCodeDialogState extends State<_PaymentCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Enter the code you were sent');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await api.confirmPayment(widget.accountId, _code.text.trim());
      if (mounted) Navigator.pop(context, info);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Enter the code'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CodeEntry(
            controller: _code,
            description: 'We sent a code by ${widget.channel == 'sms' ? 'SMS' : 'email'}.',
            busy: _busy,
            onResend: widget.onResend,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
            ),
        ]),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _confirm, child: Text(_busy ? 'Checking...' : 'Confirm')),
        ],
      );
}

/// Shown after the browser opens for a real payment. Checks automatically — right away whenever
/// the app comes back to the foreground, and every few seconds as a backup — while still leaving
/// the manual button in place for an instant, on-demand check.
class _WaitForPaymentDialog extends StatefulWidget {
  final int accountId;
  final int paymentId;
  final Future<void> Function() onChanged;
  const _WaitForPaymentDialog({required this.accountId, required this.paymentId, required this.onChanged});

  @override
  State<_WaitForPaymentDialog> createState() => _WaitForPaymentDialogState();
}

class _WaitForPaymentDialogState extends State<_WaitForPaymentDialog> with WidgetsBindingObserver {
  bool _checking = false; // only toggled for a manual tap, so background polls don't flicker the button
  bool _inFlight = false; // guards against overlapping requests when the timer and a resume fire close together
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check(); // most likely moment: they just switched back from paying
  }

  Future<void> _check({bool manual = false}) async {
    if (_inFlight) return;
    _inFlight = true;
    if (manual) setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status = await api.checkPayment(widget.accountId, widget.paymentId);
      if (status == 'paid') {
        await widget.onChanged();
        if (mounted) Navigator.pop(context);
        messenger.showSnackBar(const SnackBar(content: Text('Payment received. Thank you!')));
        return;
      }
      if (status == 'failed') {
        if (mounted) Navigator.pop(context);
        messenger.showSnackBar(
            const SnackBar(content: Text("That payment didn't go through. Tap Pay again to try another method.")));
        return;
      }
      if (manual) {
        messenger.showSnackBar(const SnackBar(content: Text("We haven't received it yet — try again in a moment.")));
      }
    } catch (e) {
      if (manual) messenger.showSnackBar(SnackBar(content: Text('$e'))); // background polls fail silently
    } finally {
      _inFlight = false;
      if (manual && mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Waiting for payment'),
        content: const Text(
            "Finish paying in the browser that just opened — we'll pick it up automatically, or tap below to check right now."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(
            onPressed: _checking ? null : () => _check(manual: true),
            child: Text(_checking ? 'Checking...' : "I've Completed Payment"),
          ),
        ],
      );
}
