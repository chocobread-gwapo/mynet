import 'package:flutter/material.dart';

import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/password_confirm.dart';

class AddOnsScreen extends StatefulWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const AddOnsScreen(this.acct, this.onChanged, {super.key});
  @override
  State<AddOnsScreen> createState() => _AddOnsScreenState();
}

class _AddOnsData {
  final List<dynamic> all;
  final Set<int> activeIds;
  _AddOnsData(this.all, this.activeIds);
}

class _AddOnsScreenState extends State<AddOnsScreen> {
  int _version = 0;

  Future<_AddOnsData> _load() async {
    final id = widget.acct['id'] as int;
    final all = await api.addons();
    final active = await api.accountAddons(id);
    return _AddOnsData(all, {for (final a in active) a['id'] as int});
  }

  Future<void> _toggle(Map addon, bool isActive) async {
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.acct['id'] as int;
    final ok = await confirmWithPassword(
      context,
      title: isActive ? 'Remove ${addon['name']}?' : 'Add ${addon['name']}?',
      message: isActive
          ? 'It will come off your bill.'
          : '${peso(addon['monthly_fee'] as int)}/month will be added to your current bill.',
      confirmLabel: isActive ? 'Remove' : 'Add',
      busyLabel: isActive ? 'Removing...' : 'Adding...',
      action: (pw) => isActive
          ? api.unsubscribeAddon(id, addon['id'] as int, pw)
          : api.subscribeAddon(id, addon['id'] as int, pw),
    );
    if (!ok) return;
    await widget.onChanged(); // refreshes the account balance shown on Home/Bills
    if (mounted) setState(() => _version++); // refetches this screen's own list
    messenger.showSnackBar(
        SnackBar(content: Text(isActive ? 'Removed ${addon['name']}.' : 'Added ${addon['name']}.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add-Ons')),
        body: Loader<_AddOnsData>(
          key: ValueKey(_version),
          load: _load,
          builder: (c, data) => ListView(padding: const EdgeInsets.all(16), children: [
            suspendedBanner(context, widget.acct),
            const Text('Add-ons appear on your current bill right away, and stay on until you remove them.'),
            const SizedBox(height: 12),
            for (final addon in data.all)
              Panel(
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${addon['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text('${addon['description']}'),
                      Text('${peso(addon['monthly_fee'] as int)}/month'),
                    ]),
                  ),
                  OutlinedButton(
                    onPressed: widget.acct['status'] == 'SUSPENDED'
                        ? null
                        : () => _toggle(addon as Map, data.activeIds.contains(addon['id'])),
                    child: Text(data.activeIds.contains(addon['id']) ? 'Remove' : 'Add'),
                  ),
                ]),
              ),
          ]),
        ),
      );
}