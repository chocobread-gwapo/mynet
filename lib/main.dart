import 'package:flutter/material.dart';

import 'api.dart';

const appName = 'MyNet'; // placeholder: choose your own name and logo
const devSimulatePayments = true; // set to false once a real payment gateway is connected

final api = Api();

const _ink = Color(0xFF101828);
const _line = Color(0xFFE3E6E0);
const _paper = Color(0xFFF6F7F5);
const _good = Color(0xFF15803D);
const _warn = Color(0xFFB45309);

final _bigButton = FilledButton.styleFrom(
  minimumSize: const Size.fromHeight(52),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);

void main() => runApp(const App());

// ---------- helpers ----------
String peso(int centavos) {
  final whole = (centavos.abs() ~/ 100)
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${centavos < 0 ? '-' : ''}₱$whole.${(centavos.abs() % 100).toString().padLeft(2, '0')}';
}

String fmtDate(String iso) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.parse(iso);
  return '${m[d.month - 1]} ${d.day}, ${d.year}';
}

void signOut(BuildContext context) {
  api.token = null;
  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (r) => false);
}

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
  final c = active ? _good : _warn;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: c.withAlpha(28), borderRadius: BorderRadius.circular(20)),
    child: Text(active ? 'Active' : 'Suspended', style: TextStyle(color: c, fontWeight: FontWeight.w600)),
  );
}

class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _line),
        ),
        child: child,
      );
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

Future<void> payNow(BuildContext context, Map<String, dynamic> acct, Future<void> Function() done) async {
  final messenger = ScaffoldMessenger.of(context);
  final amount = acct['amount_due'] as int;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Confirm payment'),
      content: Text('Pay ${peso(amount)} for your ${acct['plan']['name']} plan?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('Pay ${peso(amount)}')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final paymentId = await api.startPayment(acct['id'] as int, amount);
    if (devSimulatePayments) await api.devConfirm(paymentId);
    await done();
    messenger.showSnackBar(const SnackBar(content: Text('Payment received. Thank you!')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

// ---------- app & login ----------
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)).copyWith(surface: _paper, onSurface: _ink);
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: _paper,
        appBarTheme: const AppBarTheme(backgroundColor: _paper, foregroundColor: _ink, elevation: 0, scrolledUnderElevation: 0),
        inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
      ),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false, _busy = false, _hide = true;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.login(_email.text.trim(), _password.text, register: _register);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text(appName, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text('See what you owe and pay your internet bill in one tap.'),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _hide,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: _register ? 'At least 8 characters' : null,
                      suffixIcon: IconButton(
                        tooltip: _hide ? 'Show password' : 'Hide password',
                        icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    style: _bigButton,
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? 'Please wait...' : (_register ? 'Create account' : 'Sign in')),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _register = !_register),
                    child: Text(_register ? 'I already have an account' : 'Create an account'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ---------- link an account ----------
class LinkAccountScreen extends StatefulWidget {
  final Future<void> Function() onLinked;
  const LinkAccountScreen({super.key, required this.onLinked});
  @override
  State<LinkAccountScreen> createState() => _LinkAccountScreenState();
}

class _LinkAccountScreenState extends State<LinkAccountScreen> {
  final _no = TextEditingController();
  final _mobile = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.linkAccount(_no.text.trim(), _mobile.text.trim());
      await widget.onLinked();
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Link your account'),
          actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => signOut(context))],
        ),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('Enter the account number on your bill and the mobile number registered to it.'),
          const SizedBox(height: 20),
          TextField(controller: _no, decoration: const InputDecoration(labelText: 'Account number')),
          const SizedBox(height: 12),
          TextField(
            controller: _mobile,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Registered mobile number'),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318)))),
          const SizedBox(height: 20),
          FilledButton(style: _bigButton, onPressed: _busy ? null : _submit, child: Text(_busy ? 'Linking...' : 'Link account')),
          const SizedBox(height: 16),
          const Text('Demo data: DEMO-000001 with 5550100001, or DEMO-000002 with 5550100002.'),
        ]),
      );
}

// ---------- shell with tabs ----------
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  List<Map<String, dynamic>> _accounts = [];
  int _sel = 0, _tab = 0, _version = 0;
  bool _loading = true;
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
      _error = null;
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
    if (_accounts.isEmpty) return LinkAccountScreen(onLinked: _load);

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

// ---------- tabs ----------
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
              style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: due > 0 ? _warn : _ink),
            ),
            if (due > 0) Text('Due ${fmtDate('${acct['due_date']}')}'),
            const SizedBox(height: 16),
            FilledButton(
              style: _bigButton,
              onPressed: due > 0 ? () => payNow(context, acct, onChanged) : null,
              child: Text(due > 0 ? 'Pay ${peso(due)}' : 'No payment due'),
            ),
          ]),
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
                  style: _bigButton,
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

class PlansPage extends StatelessWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const PlansPage(this.acct, this.onChanged, {super.key});

  Future<void> _choose(BuildContext context, Map p) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.upgrade(acct['id'] as int, p['id'] as int);
      await onChanged();
      messenger.showSnackBar(SnackBar(content: Text('Switched to the ${p['name']} plan.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final due = acct['amount_due'] as int;
    final currentId = (acct['plan'] as Map)['id'];
    return ListView(padding: const EdgeInsets.all(16), children: [
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

class AccountPage extends StatelessWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const AccountPage(this.acct, this.onChanged, {super.key});

  Future<void> _unlink(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unlink this account?'),
        content: const Text('You can link it again later with the account number and registered mobile number.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.unlink(acct['id'] as int);
      await onChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = acct['plan'] as Map;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Panel(
        child: Column(children: [
          kv('Name', '${acct['holder_name']}'),
          kv('Account number', '${acct['account_no']}'),
          kv('Service address', '${acct['service_address']}'),
          kv('Plan', '${plan['name']}, ${plan['speed_mbps']} Mbps'),
          kv('Status', acct['status'] == 'ACTIVE' ? 'Active' : 'Suspended'),
        ]),
      ),
      OutlinedButton(onPressed: () => _unlink(context), child: const Text('Unlink this account')),
    ]);
  }
}
