import 'package:flutter/material.dart';

import 'package:mynet/core/format.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/widgets/common.dart';
import 'package:mynet/widgets/payment_dialogs.dart';

class BillsPage extends StatefulWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const BillsPage(this.acct, this.onChanged, {super.key});
  @override
  State<BillsPage> createState() => _BillsPageState();
}

class _BillsPageState extends State<BillsPage> {
  int _view = 0;

  @override
  Widget build(BuildContext context) {
    final id = widget.acct['id'] as int;
    return RefreshIndicator(
      onRefresh: widget.onChanged,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Loader<Map<String, dynamic>>(
          load: () => api.bill(id),
          builder: (c, d) {
            final b = d['bill'] as Map?;
            final due = d['amount_due'] as int;
            final credit = d['credit'] as int;
            return Panel(
              child: Column(children: [
                if (b != null) ...[
                  kv('Billing period', '${fmtDate('${b['period_start']}')} to ${fmtDate('${b['period_end']}')}'),
                  kv('Previous balance', peso(b['previous_balance'] as int)),
                  kv('Current charges', peso(b['charges'] as int)),
                ],
                kv('Due date', fmtDate('${d['due_date']}')),
                const Divider(),
                kv(credit > 0 ? 'Credit' : 'Amount due', peso(credit > 0 ? credit : due), bold: true),
                const SizedBox(height: 8),
                FilledButton(
                  style: bigButton,
                  onPressed: due > 0 ? () => payNow(context, widget.acct, widget.onChanged) : null,
                  child: Text(due > 0 ? 'Pay ${peso(due)}' : 'No payment due'),
                ),
              ]),
            );
          },
        ),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Billing history')),
            ButtonSegment(value: 1, label: Text('Payment history')),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
        const SizedBox(height: 12),
        if (_view == 0)
          Loader<List<dynamic>>(
            key: const ValueKey('bills'),
            load: () => api.bills(id),
            builder: (c, list) => Panel(
              child: Column(children: [
                for (final b in list)
                  kv(fmtDate('${b['statement_date']}'), peso((b['total'] as int))),
                if (list.isEmpty) const Text('No bills yet.'),
              ]),
            ),
          )
        else
          Loader<List<dynamic>>(
            key: const ValueKey('payments'),
            load: () => api.payments(id),
            builder: (c, list) => Panel(
              child: Column(children: [
                for (final p in list) kv(fmtDate('${p['paid_at']}'), peso(p['amount'] as int)),
                if (list.isEmpty) const Text('No payments yet. Your payments will be listed here.'),
              ]),
            ),
          ),
      ]),
    );
  }
}
