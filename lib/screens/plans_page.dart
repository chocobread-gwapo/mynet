import 'package:flutter/material.dart';

import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/screens/add_ons_screen.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/password_confirm.dart';

class PlansPage extends StatelessWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const PlansPage(this.acct, this.onChanged, {super.key});

  Future<void> _choose(BuildContext context, Map p) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmWithPassword(
      context,
      title: 'Switch to the ${p['name']} plan?',
      message: 'Your plan and monthly bill will change.',
      confirmLabel: 'Switch',
      busyLabel: 'Switching...',
      action: (pw) => api.upgrade(acct['id'] as int, p['id'] as int, pw),
    );
    if (!ok) return;
    await onChanged();
    messenger.showSnackBar(SnackBar(content: Text('Switched to the ${p['name']} plan.')));
  }

  @override
  Widget build(BuildContext context) {
    final due = acct['amount_due'] as int;
    final currentId = (acct['plan'] as Map)['id'];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Panel(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Add-Ons', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          subtitle: const Text('Extra services for your connection'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => AddOnsScreen(acct, onChanged))),
        ),
      ),
      if (due > 0) Panel(child: Text('Pay your ${peso(due)} amount due before changing plans.')),
      Loader<List<dynamic>>(
        load: api.plans,
        builder: (c, plans) => Column(children: [
          for (final p in plans)
            Panel(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text('${p['speed_mbps']} Mbps for ${peso(p['monthly_fee'] as int)} a month'),
                  ]),
                ),
                if (p['id'] == currentId)
                  const Text('Current plan')
                else
                  OutlinedButton(onPressed: () => _choose(context, p as Map), child: const Text('Switch')),
              ]),
            ),
        ]),
      ),
    ]);
  }
}
