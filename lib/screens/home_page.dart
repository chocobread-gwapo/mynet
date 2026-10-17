import 'package:flutter/material.dart';

import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/screens/speed_test_screen.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/payment_dialogs.dart';

class HomePage extends StatelessWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const HomePage(this.acct, this.onChanged, {super.key});

  @override
  Widget build(BuildContext context) {
    final due = acct['amount_due'] as int;
    final credit = acct['credit'] as int;
    final plan = acct['plan'] as Map;
    final text = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        suspendedBanner(context, acct),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${acct['holder_name']}', style: text.titleMedium)),
              statusChip('${acct['status']}'),
            ]),
            const SizedBox(height: 4),
            Text('${plan['name']} plan, ${plan['speed_mbps']} Mbps'),
          ]),
        ),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(due > 0 ? 'Amount due' : (credit > 0 ? 'Credit on your account' : 'Nothing to pay right now')),
            const SizedBox(height: 4),
            Text(
              peso(due > 0 ? due : credit),
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: due > 0 ? kWarn : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            if (due > 0) Text('Due ${fmtDate('${acct['due_date']}')}'),
            const SizedBox(height: 16),
            FilledButton(
              style: bigButton,
              onPressed: due > 0 ? () => payNow(context, acct, onChanged) : null,
              child: Text(due > 0 ? 'Pay ${peso(due)}' : 'No payment due'),
            ),
          ]),
        ),
        Panel(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.speed),
            title: const Text('Internet speed test', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Check your ping, download and upload speed'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SpeedTestScreen(planMbps: plan['speed_mbps'] as int, accountId: acct['id'] as int),
            )),
          ),
        ),
        const SizedBox(height: 4),
        Text('Notifications', style: text.titleMedium),
        const SizedBox(height: 8),
        Loader<List<dynamic>>(
          load: () => api.notifications(acct['id'] as int),
          builder: (c, list) => list.isEmpty
              ? const Panel(child: Text('No notifications yet. Payment confirmations will show up here.'))
              : Panel(
                  child: Column(children: [
                    for (final n in list)
                      ListTile(contentPadding: EdgeInsets.zero, title: Text('${n['title']}'), subtitle: Text('${n['body']}')),
                  ]),
                ),
        ),
      ]),
    );
  }
}