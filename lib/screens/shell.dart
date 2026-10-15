import 'package:flutter/material.dart';

import 'package:mynet/core/config.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/notifications.dart';
import 'package:mynet/screens/account_page.dart';
import 'package:mynet/screens/bills_page.dart';
import 'package:mynet/screens/home_page.dart';
import 'package:mynet/screens/link_account_screen.dart';
import 'package:mynet/screens/plans_page.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  List<Map<String, dynamic>> _accounts = [];
  int _sel = 0, _tab = 0, _version = 0;
  bool _loading = true;
  bool _hasPending = false; // no account yet, but a link request is waiting for approval
  bool _linkAnother = false; // the user chose to file another request from the waiting screen
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await api.accounts();
      _accounts = [for (final e in list) Map<String, dynamic>.from(e as Map)];
      if (_sel >= _accounts.length) _sel = 0;
      _hasPending = _accounts.isEmpty && (await api.linkRequests()).any((r) => r['status'] == 'PENDING');
      _error = null;
      for (final a in _accounts) {
        await scheduleDueReminder(
          accountId: a['id'] as int,
          amountDue: a['amount_due'] as int,
          dueDate: DateTime.parse(a['due_date'] as String),
          planName: (a['plan'] as Map)['name'] as String,
        );
      }
    } catch (e) {
      if (_accounts.isEmpty) {
        _error = '$e';
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _version++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
                child: const Text('Try again'),
              ),
            ]),
          ),
        ),
      );
    }
    if (_accounts.isEmpty && _hasPending && !_linkAnother) {
      return RequestReceivedScreen(
        buttonLabel: 'Check status',
        onBack: () {
          setState(() => _loading = true);
          _load();
        },
        extra: TextButton(onPressed: () => setState(() => _linkAnother = true), child: const Text('Link a different account')),
      );
    }
    if (_accounts.isEmpty) {
      return LinkAccountScreen(onLinked: () async {
        _linkAnother = false;
        await _load();
      });
    }

    final acct = _accounts[_sel];
    final key = ValueKey('$_tab-${acct['id']}-$_version');
    final pages = <Widget>[
      HomePage(acct, _load, key: key),
      BillsPage(acct, _load, key: key),
      PlansPage(acct, _load, key: key),
      AccountPage(acct, _load, key: key),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName, style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (_accounts.length > 1)
            PopupMenuButton<int>(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Switch account',
              onSelected: (i) => setState(() {
                _sel = i;
                _version++;
              }),
              itemBuilder: (_) => [
                for (var i = 0; i < _accounts.length; i++)
                  PopupMenuItem<int>(value: i, child: Text('${_accounts[i]['account_no']}')),
              ],
            ),
          IconButton(
            tooltip: 'Link another account',
            icon: const Icon(Icons.add),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => LinkAccountScreen(onLinked: _load))),
          ),
          IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => signOut(context)),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Bills'),
          NavigationDestination(icon: Icon(Icons.speed_outlined), label: 'Plans'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Account'),
        ],
      ),
    );
  }
}
