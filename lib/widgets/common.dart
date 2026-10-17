import 'package:flutter/material.dart';

import 'package:mynet/core/theme.dart';

Widget kv(String k, String v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k),
        const SizedBox(width: 16),
        Expanded(
          child: Text(v, textAlign: TextAlign.right, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ),
      ]),
    );

Widget statusChip(String status) {
  final active = status == 'ACTIVE';
  final c = active ? kGood : kWarn;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: c.withAlpha(28), borderRadius: BorderRadius.circular(20)),
    child: Text(active ? 'Active' : 'Suspended', style: TextStyle(color: c, fontWeight: FontWeight.w600)),
  );
}

/// A clear notice for a suspended account (nothing when the account is active). [reason] is what staff typed.
/// Paying, bills and issue reports keep working while suspended; plan and add-on changes are switched off.
Widget suspendedBanner(BuildContext context, Map<String, dynamic> acct) {
  if (acct['status'] != 'SUSPENDED') return const SizedBox.shrink();
  final scheme = Theme.of(context).colorScheme;
  final reason = (acct['status_reason'] as String?)?.trim();
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: scheme.error.withAlpha(30),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: scheme.error.withAlpha(120)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.pause_circle_outline, color: scheme.error),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your service is suspended', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.error)),
          const SizedBox(height: 4),
          if (reason != null && reason.isNotEmpty) Text('Reason: $reason'),
          Text(acct['auto_restore'] == true
              ? 'Your service will be restored automatically once your balance is paid in full. '
                  'You can still pay, view your bills and report an issue.'
              : 'Please settle your balance or contact support to have it restored. '
                  'You can still pay, view your bills and report an issue.'),
        ]),
      ),
    ]),
  );
}

/// Two small dots marking "step 2 of 2" on a form that only grows a second step once the server
/// actually asks for a code (dev mode, with no SMS/email provider configured, never shows it at all).
Widget stepTwoDots(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  Widget dot(bool current) => Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(shape: BoxShape.circle, color: current ? scheme.primary : scheme.outlineVariant),
      );
  return Padding(
    padding: const EdgeInsets.only(bottom: 16),
    // Step 1 (details just entered) shown muted/behind us; step 2 (code entry, right now) highlighted.
    child: Row(mainAxisSize: MainAxisSize.min, children: [dot(false), dot(true)]),
  );
}

class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

/// Loads data, shows a spinner, and shows a clear message with a retry button if it fails.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  const Loader({super.key, required this.load, required this.builder});
  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Panel(
              child: Column(children: [
                Text('${snap.error}', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: () => setState(() => _future = widget.load()), child: const Text('Try again')),
              ]),
            );
          }
          return widget.builder(context, snap.data as T);
        },
      );
}