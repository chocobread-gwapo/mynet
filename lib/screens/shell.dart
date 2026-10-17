import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mynet/core/config.dart';
import 'package:mynet/core/push.dart';
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

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _accounts = [];
  int _sel = 0, _tab = 0, _version = 0;
  bool _loading = true;
  bool _hasPending = false; // no account yet, but a link request is waiting for approval
  bool _linkAnother = false; // the user chose to file another request from the waiting screen
  String? _error;

  // Live updates: while the app is open, a quiet check runs every few seconds (and when you come back to the app).
  // It only reloads the screens when something really changed, so scrolling and typing aren't disturbed.
  static const _pollEvery = Duration(seconds: 15);
  Timer? _poll;
  String _sig = ''; // what the last load looked like; a different answer later means staff changed something
  bool _checking = false;

  // Instant updates: a request is held open on the server and answers the moment anything changes. The timer
  // above stays as a safety net in case that connection is blocked or drops.
  int _listenGen = 0; // bumping this ends any older listening loop

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
    _startListening();
    Push.start(); // ask for notification permission and register this phone for pushes
    _load();
  }

  Future<void> _startListening() async {
    final gen = ++_listenGen;
    int since = -1;
    while (mounted && gen == _listenGen) {
      try {
        final v = await api.waitForChange(since);
        if (!mounted || gen != _listenGen) break;
        final changed = since >= 0 && v != since;
        since = v;
        if (changed) await _quietRefresh();
      } catch (_) {
        since = -1; // offline or the server restarted: start over after a short rest
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _listenGen++;
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollEvery, (_) => _quietRefresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _startListening();
      _quietRefresh(); // check right away when the customer comes back to the app
    } else {
      _poll?.cancel(); // no point checking while the app is in the background
      _listenGen++; // the held-open request ends on its own within ~20 seconds
    }
  }

  /// A short fingerprint of the account(s) and the latest notifications, to spot changes cheaply.
  Future<String> _signature(List<dynamic> accounts) async {
    final notes = accounts.isEmpty ? <dynamic>[] : await api.notifications((accounts[_sel < accounts.length ? _sel : 0] as Map)['id'] as int);
    return jsonEncode([accounts, [for (final n in notes) (n as Map)['id']]]);
  }

  Future<void> _quietRefresh() async {
    if (!mounted || _loading || _checking) return;
    _checking = true;
    try {
      final list = await api.accounts();
      if (!mounted) return;
      if (_accounts.isEmpty) {
        // Waiting for approval (or on the link screen): the moment an account appears, show it.
        if (list.isNotEmpty) await _load();
        return;
      }
      // A dialog or another screen is open on top: don't reload underneath it (the app resumes checking afterwards).
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      final sig = await _signature(list);
      if (mounted && sig != _sig) await _load();
    } catch (_) {
      // Offline, or the session ended: stay quiet. The next check tries again.
    } finally {
      _checking = false;
    }
  }

  Future<void> _load() async {
    try {
      final list = await api.accounts();
      _accounts = [for (final e in list) Map<String, dynamic>.from(e as Map)];
      if (_sel >= _accounts.length) _sel = 0;
      _hasPending = _accounts.isEmpty && (await api.linkRequests()).any((r) => r['status'] == 'PENDING');
      _error = null;
      try {
        _sig = await _signature(list);
      } catch (_) {
        _sig = '';
      }
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