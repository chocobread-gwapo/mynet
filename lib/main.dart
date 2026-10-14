import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'notifications.dart';

const appName = 'NetPulse';
const devSimulatePayments = true; // set to false once a real payment gateway is connected

/// The Web OAuth client ID from Google Cloud Console (APIs & Services > Credentials) — the same value
/// GOOGLE_CLIENT_ID is set to on the server (they must match: the server checks the token was issued
/// for this exact client). Leave the placeholder in and the Google button shows a clear error when
/// tapped instead of breaking anything else in the app.
const googleServerClientId = '525298506900-qppp3bqo9i0f94jqol667fo3v4qf6c7l.apps.googleusercontent.com';

final api = Api();

// These let code without a BuildContext (like the API client) switch screens and show a message.
final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

// Status green and warning amber read fine on both light and dark surfaces, so these two stay
// as fixed accent colors. Anything that needed to flip between light/dark now reads from Theme.of(context) instead.
const _good = Color(0xFF15803D);
const _warn = Color(0xFFB45309);

final _bigButton = FilledButton.styleFrom(
  minimumSize: const Size.fromHeight(52),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  api.onUnauthorized = sessionExpired;
  runApp(const App());
}

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
  api.clearToken(); // clears the in-memory token immediately; the storage delete finishes in the background
  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (r) => false);
}

/// Called by the API client when the server rejects our saved login. Works without a BuildContext.
void sessionExpired() {
  api.clearToken(); // forget the rejected token right away
  navigatorKey.currentState?.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (r) => false,
  );
  messengerKey.currentState?.showSnackBar(
    const SnackBar(content: Text('Your session expired. Please sign in again.')),
  );
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

/// Shared "enter the code we sent" block used by login/register (email), account linking (SMS), and
/// payment confirmation (either). Shows a live 10-minute countdown matching the server's OTP_TTL_SECONDS,
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
  static const _codeLifetime = Duration(minutes: 10);
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
        style: TextStyle(fontSize: 12, color: expired ? _warn : Theme.of(context).hintColor),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: widget.controller,
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

// ---------- app & login ----------
const _seedColor = Color(0xFF0F766E);

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seedColor, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
  );
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        title: appName,
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: const AuthGate(),
      );
}

/// Shown briefly at startup: tries a saved token before falling back to the login screen.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final saved = await api.loadSavedToken();
    if (saved == null) return _goTo(const LoginScreen());
    api.token = saved;
    try {
      await api.accounts(); // any successful call confirms the saved token still works
      _goTo(const Shell());
    } catch (_) {
      if (api.token == null) return; // a rejected token was already cleared and you were sent to sign in
      await api.clearToken(); // expired or revoked: don't keep retrying with it
      _goTo(const LoginScreen());
    }
  }

  void _goTo(Widget page) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _register = false, _busy = false, _hide = true;
  bool _verifying = false; // true once the server asked for an email code; same form, second step
  String? _error;

  @override
  void initState() {
    super.initState();
    // Only this screen needs Google Sign-In, so it's initialized here rather than in main() — nothing
    // else in the app touches it. A problem here (e.g. a misconfigured client ID) surfaces when the
    // button is actually tapped, via the try/catch in _signInWithGoogle, rather than crashing startup.
    unawaited(GoogleSignIn.instance.initialize(serverClientId: googleServerClientId));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_verifying) {
        final verificationRequired = await api.login(_email.text.trim(), _password.text, register: _register);
        if (verificationRequired) {
          setState(() => _verifying = true); // show the code field; submitting again now confirms it
          return;
        }
      } else {
        await api.confirmEmailVerification(_email.text.trim(), _code.text.trim());
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (!GoogleSignIn.instance.supportsAuthenticate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) throw ApiException("Google didn't return a usable sign-in token.");
      await api.loginWithGoogle(idToken);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } on GoogleSignInException catch (e) {
      // The user backing out of the Google account picker isn't an error worth showing.
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      if (mounted) setState(() => _error = e.description ?? 'Google sign-in failed (${e.code}).');
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
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text(appName, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    const Text('See what you owe and pay your internet bill in one tap.'),
                    const SizedBox(height: 32),
                    if (!_verifying) ...[
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'Enter your email';
                          if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
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
                        validator: (v) {
                          final value = v ?? '';
                          if (value.isEmpty) return 'Enter your password';
                          if (value.length < 8) return 'At least 8 characters';
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      Row(children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or', style: TextStyle(color: Theme.of(context).hintColor)),
                        ),
                        const Expanded(child: Divider()),
                      ]),
                      const SizedBox(height: 20),
                      OutlinedButton(
                        onPressed: _busy ? null : _signInWithGoogle,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Continue with Google'),
                      ),
                    ] else ...[
                      stepTwoDots(context),
                      CodeEntry(
                        controller: _code,
                        description: 'We sent a code to ${_email.text.trim()}.',
                        busy: _busy,
                        onResend: () => api.login(_email.text.trim(), _password.text, register: _register),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _busy ? null : () => setState(() => _verifying = false),
                        child: const Text('Use a different email'),
                      ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
                      ),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: _bigButton,
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy
                          ? 'Please wait...'
                          : (_verifying ? 'Confirm code' : (_register ? 'Create account' : 'Sign in'))),
                    ),
                    if (!_verifying)
                      TextButton(
                        onPressed: () => setState(() => _register = !_register),
                        child: Text(_register ? 'I already have an account' : 'Create an account'),
                      ),
                  ]),
                ),
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
  final _formKey = GlobalKey<FormState>();
  final _no = TextEditingController();
  final _mobile = TextEditingController();
  final _code = TextEditingController();
  bool _otpSent = false; // true once the server asked for a code; same form, second step
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_otpSent) {
        final otpRequired = await api.startLinkAccount(_no.text.trim(), _mobile.text.trim());
        if (otpRequired) {
          setState(() => _otpSent = true); // show the code field; submitting again now confirms it
          return;
        }
      } else {
        await api.confirmLinkAccount(_no.text.trim(), _mobile.text.trim(), _code.text.trim());
      }
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
          title: Text(_otpSent ? 'Enter the code' : 'Link your account'),
          actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => signOut(context))],
        ),
        body: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(padding: const EdgeInsets.all(24), children: [
            if (!_otpSent) ...[
              const Text('Enter the account number on your bill and the mobile number registered to it.'),
              const SizedBox(height: 20),
              TextFormField(
                controller: _no,
                decoration: const InputDecoration(labelText: 'Account number'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your account number' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _mobile,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Registered mobile number'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the registered mobile number' : null,
              ),
            ] else ...[
              stepTwoDots(context),
              CodeEntry(
                controller: _code,
                description: 'We sent a code by SMS to ${_mobile.text.trim()}.',
                busy: _busy,
                onResend: () => api.startLinkAccount(_no.text.trim(), _mobile.text.trim()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _otpSent = false),
                child: const Text('Use a different number'),
              ),
            ],
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318)))),
            const SizedBox(height: 20),
            FilledButton(
              style: _bigButton,
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Please wait...' : (_otpSent ? 'Confirm code' : 'Link account')),
            ),
            const SizedBox(height: 16),
            if (!_otpSent) const Text('Demo data: DEMO-000001 with 09913187942, or DEMO-000002 with 5550100002.'),
          ]),
        ),
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
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: due > 0 ? _warn : Theme.of(context).colorScheme.onSurface,
              ),
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
    try {
      if (isActive) {
        await api.unsubscribeAddon(id, addon['id'] as int);
      } else {
        await api.subscribeAddon(id, addon['id'] as int);
      }
      await widget.onChanged(); // refreshes the account balance shown on Home/Bills
      if (mounted) setState(() => _version++); // refetches this screen's own list
      messenger.showSnackBar(
          SnackBar(content: Text(isActive ? 'Removed ${addon['name']}.' : 'Added ${addon['name']}.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add-Ons')),
        body: Loader<_AddOnsData>(
          key: ValueKey(_version),
          load: _load,
          builder: (c, data) => ListView(padding: const EdgeInsets.all(16), children: [
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
                    onPressed: () => _toggle(addon as Map, data.activeIds.contains(addon['id'])),
                    child: Text(data.activeIds.contains(addon['id']) ? 'Remove' : 'Add'),
                  ),
                ]),
              ),
          ]),
        ),
      );
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
      OutlinedButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ReportIssueScreen(accountId: acct['id'] as int))),
        child: const Text('Report an issue'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => _unlink(context), child: const Text('Unlink this account')),
    ]);
  }
}

class ReportIssueScreen extends StatefulWidget {
  final int accountId;
  const ReportIssueScreen({super.key, required this.accountId});
  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  static const _categories = ['Connection', 'Billing', 'Account', 'Other'];
  String _category = _categories.first;
  final _message = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_message.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Please describe the issue first.')));
      return;
    }
    setState(() => _busy = true);
    try {
      await api.reportIssue(widget.accountId, _category, _message.text.trim());
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('Thanks — your report was submitted.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Report an Issue')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final c in _categories) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'What happened?', alignLabelWithHint: true),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: _bigButton,
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Sending...' : 'Submit'),
          ),
        ]),
      );
}
