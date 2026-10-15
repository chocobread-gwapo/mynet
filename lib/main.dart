import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'notifications.dart';

const appName = 'NetPulse';
const devSimulatePayments = true; // set to false once a real payment gateway is connected

/// How long the app can sit in the background before a login made WITHOUT "Remember me" is ended.
/// Change the number to taste; it has no effect on logins that did tick "Remember me".
const backgroundLogoutAfter = Duration(minutes: 5);

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
  WidgetsBinding.instance.addObserver(_BackgroundLogout());
  runApp(const App());
}

/// Ends a "Remember me"-unticked login once the app has been out of sight for [backgroundLogoutAfter].
/// Timers don't run reliably while an app is in the background, so this just notes when the app was
/// hidden and compares the clock the moment it comes back. (If Android kills the app in the meantime,
/// the in-memory login is already gone, so there's nothing left to end.)
class _BackgroundLogout with WidgetsBindingObserver {
  DateTime? _leftAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _leftAt ??= DateTime.now(); // keep the first moment it left, not the later paused one
    } else if (state == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left != null &&
          api.sessionOnly &&
          api.token != null &&
          DateTime.now().difference(left) >= backgroundLogoutAfter) {
        sessionTimedOut();
      }
    }
  }
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

/// Like [sessionExpired], but for a login that was ended because the app sat in the background too long.
/// Replacing every route also closes any dialog that was open.
void sessionTimedOut() {
  api.clearToken();
  navigatorKey.currentState?.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (r) => false,
  );
  messengerKey.currentState?.showSnackBar(
    const SnackBar(content: Text('You were signed out after being away for a while. Please sign in again.')),
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
/// payment confirmation (either). Shows a live 3-minute countdown matching the server's OTP_TTL_SECONDS,
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
  static const _codeLifetime = Duration(minutes: 3);
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
        autofillHints: const [AutofillHints.oneTimeCode],
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
/// The splash's green, and the phone's launch-screen colors (the same as the app's dark and light
/// backgrounds). Keep the launch colors equal to `color` / `color_dark` in pubspec.yaml's flutter_native_splash.
const _splashColor = Color(0xFF0F8F82);
const _launchLight = Color(0xFFF5FBFA);
const _launchDark = Color(0xFF001515);

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // The splash stays up at least this long, so the pulse is actually seen even when the check is instant.
  final Future<void> _minShow = Future<void>.delayed(const Duration(milliseconds: 2200));

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
      if (api.token == null) return; // the server rejected the token: it's already cleared and you were sent to sign in
      // Anything else (server off or unreachable, a bad Wi-Fi moment) says nothing about the login itself,
      // so keep it: the home screen shows the problem with a Try again button instead of signing you out.
      _goTo(const Shell());
    }
  }

  Future<void> _goTo(Widget page) async {
    await _minShow;
    if (!mounted) return;
    // Fades out of the green splash instead of sliding, so the change of screen is gentle.
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        // Starts as exactly the phone's own launch screen (see flutter_native_splash in pubspec.yaml), so
        // opening the app goes from the launch screen to this one without a visible change; the green then
        // spreads out from the logo.
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? _launchDark : _launchLight,
        body: const SizedBox.expand(child: PulseSplash()),
      );
}

/// The startup splash. It begins exactly like the launch screen (the logo on the app's background), then
/// green spreads out from the logo's center until it fills the screen; the logo turns into white rings that
/// beat like a heartbeat with ripples spreading out of them.
class PulseSplash extends StatefulWidget {
  const PulseSplash({super.key});
  @override
  State<PulseSplash> createState() => _PulseSplashState();
}

class _PulseSplashState extends State<PulseSplash> with TickerProviderStateMixin {
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..forward();
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat();

  @override
  void dispose() {
    _reveal.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_reveal, _c]),
      builder: (context, _) {
        // 0..1: a short hold on the launch-screen look, then the green spreads.
        final spread = Curves.easeInOutCubic.transform(((_reveal.value - 0.2) / 0.8).clamp(0.0, 1.0));
        final squareOpacity = 1 - (spread * 2).clamp(0.0, 1.0);
        final ringsOpacity = ((spread - 0.3) / 0.5).clamp(0.0, 1.0);
        final intro = ((spread - 0.65) / 0.35).clamp(0.0, 1.0); // ripples and the name come in last
        // A quick double-beat once per cycle, then rest. Only once the green is mostly there.
        final beat = intro * math.pow(math.sin(math.pi * _c.value * 2).abs(), 10).toDouble();
        return Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: _RevealPainter(spread)),
          // A Stack, so the logo sits at the exact center of the screen (where the launch screen draws it)
          // and the name hangs below it without pushing it up.
          Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                Positioned.fill(child: CustomPaint(painter: _RipplePainter(_c.value, intro))),
                Opacity(
                  opacity: squareOpacity,
                  child: Image.asset('assets/splash_mark.png', width: 84, height: 84, filterQuality: FilterQuality.high),
                ),
                Opacity(
                  opacity: ringsOpacity,
                  child: Transform.scale(
                    scale: (0.7 + 0.3 * spread) * (1 + 0.12 * beat),
                    child: Image.asset('assets/splash_rings.png', width: 120, height: 120, filterQuality: FilterQuality.high),
                  ),
                ),
                Positioned(
                  top: 236,
                  left: -80,
                  right: -80,
                  child: Opacity(
                    opacity: intro * (0.85 + 0.15 * beat),
                    child: const Center(
                      child: Text(appName, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

/// The green that spreads from the center of the screen until it covers all of it.
class _RevealPainter extends CustomPainter {
  final double spread; // 0..1
  _RevealPainter(this.spread);

  @override
  void paint(Canvas canvas, Size size) {
    if (spread <= 0) return;
    final reach = math.sqrt(size.width * size.width + size.height * size.height) / 2; // center to a corner
    canvas.drawCircle(size.center(Offset.zero), reach * spread, Paint()..color = _splashColor);
  }

  @override
  bool shouldRepaint(_RevealPainter old) => old.spread != spread;
}

class _RipplePainter extends CustomPainter {
  final double t; // 0..1 around the cycle
  final double intro; // 0..1, fades the rings in
  _RipplePainter(this.t, this.intro);

  @override
  void paint(Canvas canvas, Size size) {
    if (intro <= 0) return;
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1; // each ring is a third of a cycle behind the last
      final radius = 62 + p * (size.width / 2 - 62);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - p) + 0.5
        ..color = Colors.white.withValues(alpha: 0.45 * (1 - p) * intro);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.intro != intro;
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
  bool _busy = false, _hide = true;
  bool _verifying = false; // true once the server asked for an email code; same form, second step
  bool _remember = false; // the "Remember me" box (starts unticked): stay signed in after the app closes
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRememberMe();
    // Only this screen needs Google Sign-In, so it's initialized here rather than in main() — nothing
    // else in the app touches it. A problem here (e.g. a misconfigured client ID) surfaces when the
    // button is actually tapped, via the try/catch in _signInWithGoogle, rather than crashing startup.
    unawaited(GoogleSignIn.instance.initialize(serverClientId: googleServerClientId));
  }

  /// Puts the "Remember me" box back the way it was left. (The email field is never pre-filled: it
  /// always starts empty.)
  Future<void> _loadRememberMe() async {
    final remember = await api.loadRememberMe();
    if (mounted) setState(() => _remember = remember);
  }

  /// Ticks or unticks the box and saves that straight away, so it's still as left even if the app is
  /// closed without signing in.
  void _setRemember(bool value) {
    setState(() => _remember = value);
    unawaited(api.saveRememberMe(value));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_verifying) {
        final verificationRequired =
            await api.login(_email.text.trim(), _password.text, remember: _remember);
        if (verificationRequired) {
          setState(() => _verifying = true); // show the code field; submitting again now confirms it
          return;
        }
      } else {
        await api.confirmEmailVerification(_email.text.trim(), _code.text.trim(), remember: _remember);
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
      await api.loginWithGoogle(idToken, remember: _remember);
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
        // Pinned to the bottom of the screen; hidden while the keyboard is open so it never crowds the form.
        bottomNavigationBar: (_verifying || MediaQuery.of(context).viewInsets.bottom > 0)
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  // heightFactor: 1 is essential: a plain Center would grow to fill the whole screen here.
                  child: Align(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Center(
                          child: Text("Don't have an account yet?", style: TextStyle(color: Theme.of(context).hintColor)),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          style: _bigButton,
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterScreen())),
                          child: const Text('Create an account', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(child: Form(
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
                        autofillHints: [AutofillHints.username, AutofillHints.email],
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
                        autofillHints: [AutofillHints.password],
                        obscureText: _hide,
                        decoration: InputDecoration(
                          labelText: 'Password',
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
                      Row(children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _busy ? null : () => _setRemember(!_remember),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Checkbox(
                                  value: _remember,
                                  onChanged: _busy ? null : (v) => _setRemember(v ?? false),
                                ),
                                const Text('Remember me'),
                                const SizedBox(width: 8),
                              ]),
                            ),
                          ),
                        ),
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ForgotPasswordScreen(initialEmail: _email.text.trim()))),
                            child: const Text('Forgot password?'),
                          ),
                      ]),
                    ] else ...[
                      stepTwoDots(context),
                      CodeEntry(
                        controller: _code,
                        description: 'We sent a code to ${_email.text.trim()}.',
                        busy: _busy,
                        onResend: () =>
                            api.login(_email.text.trim(), _password.text, remember: _remember),
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
                          : (_verifying ? 'Confirm code' : 'Sign in')),
                    ),
                    if (!_verifying) ...[
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
                      // Google's official circular icon button (from their branding asset pack): the dark
                      // version on dark theme, the light one on light theme. It carries its own circle and border.
                      Center(
                        child: Semantics(
                          button: true,
                          label: 'Continue with Google',
                          child: InkResponse(
                            onTap: _busy ? null : _signInWithGoogle,
                            radius: 32,
                            child: Opacity(
                              opacity: _busy ? 0.5 : 1,
                              child: Image.asset(
                                Theme.of(context).brightness == Brightness.dark
                                    ? 'assets/google_g_dark.png'
                                    : 'assets/google_g_light.png',
                                width: 48,
                                height: 48,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, _, _) => const Icon(Icons.login),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ]),
                )),
              ),
            ),
          ),
        ),
      );
}

// ---------- registration ----------
/// The sign-up form: email, password (typed twice), mobile number, name, and the two agreements.
/// Like login it has a second step when the server emails a code to confirm the address.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _mobile = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _code = TextEditingController();
  bool _hide = true, _busy = false, _verifying = false;
  bool _privacy = false, _terms = false, _agreeError = false;
  bool _remember = false; // follows the login screen's "Remember me" box
  String? _error;

  @override
  void initState() {
    super.initState();
    api.loadRememberMe().then((v) => _remember = v);
  }

  @override
  void dispose() {
    for (final c in [_email, _password, _confirm, _mobile, _first, _last, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState!.validate();
    if (!_verifying) {
      setState(() => _agreeError = !(_privacy && _terms));
      if (!valid || !(_privacy && _terms)) return;
    } else if (!valid) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_verifying) {
        final verificationRequired = await api.register(
          email: _email.text.trim(),
          password: _password.text,
          firstName: _first.text.trim(),
          lastName: _last.text.trim(),
          mobile: _mobile.text.trim(),
          remember: _remember,
        );
        if (verificationRequired) {
          setState(() => _verifying = true);
          return;
        }
      } else {
        await api.confirmEmailVerification(_email.text.trim(), _code.text.trim(), remember: _remember);
      }
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Shell()), (r) => false);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showDocument(String title) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text('The full $title will be shown here.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        ),
      );

  Widget _agreement({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String before,
    required String link,
    required String title,
  }) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: value, onChanged: _busy ? null : (v) => onChanged(v ?? false)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: before),
              TextSpan(
                text: link,
                style: TextStyle(
                  // A link blue that stays readable on both themes, bold and underlined so it clearly reads as tappable.
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF8AB4F8)
                      : const Color(0xFF1A5FD0),
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                ),
                recognizer: TapGestureRecognizer()..onTap = () => _showDocument(title),
              ),
              const TextSpan(text: '.'),
            ])),
          ),
        ),
      ]);

  String? _required(String? v, String what) => (v == null || v.trim().isEmpty) ? 'Enter your $what' : null;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
              const Text('Registration', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              if (!_verifying) ...[
                TextFormField(
                  controller: _email,
                  autofillHints: [AutofillHints.username, AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email', hintText: 'juandelacruz@gmail.com'),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _passwordField(
                  controller: _password,
                  autofillHints: [AutofillHints.newPassword],
                  label: 'Password',
                  helper: 'Password must be 8 characters or more with an uppercase character and a number',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) {
                    final value = v ?? '';
                    if (value.isEmpty) return 'Enter a password';
                    if (value.length < 8 || !value.contains(RegExp('[A-Z]')) || !value.contains(RegExp('[0-9]'))) {
                      return '8+ characters, an uppercase letter and a number';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _passwordField(
                  controller: _confirm,
                  autofillHints: [AutofillHints.newPassword],
                  label: 'Confirm password',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) => v != _password.text ? "Passwords don't match" : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _mobile,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Mobile number', hintText: '09XX-XXX-XXXX'),
                  validator: _mobileValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _first,
                  autofillHints: const [AutofillHints.givenName],
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'First name'),
                  validator: (v) => _required(v, 'first name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _last,
                  autofillHints: const [AutofillHints.familyName],
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Last name'),
                  validator: (v) => _required(v, 'last name'),
                ),
                const SizedBox(height: 16),
                _agreement(
                  value: _privacy,
                  onChanged: (v) => setState(() => _privacy = v),
                  before: 'I understand that $appName will use the information I submit in accordance with its ',
                  link: 'PRIVACY POLICY',
                  title: 'Privacy Policy',
                ),
                _agreement(
                  value: _terms,
                  onChanged: (v) => setState(() => _terms = v),
                  before: 'I have read and understood the ',
                  link: 'TERMS & CONDITIONS',
                  title: 'Terms & Conditions',
                ),
                if (_agreeError && !(_privacy && _terms))
                  const Padding(
                    padding: EdgeInsets.only(top: 4, left: 12),
                    child: Text('Please tick both boxes to continue.', style: TextStyle(color: Color(0xFFB42318))),
                  ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: 'We sent a code to ${_email.text.trim()}.',
                  busy: _busy,
                  onResend: () => api.login(_email.text.trim(), _password.text, remember: _remember),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
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
                child: Text(_busy ? 'Please wait...' : (_verifying ? 'Confirm code' : 'Create account')),
              ),
            ]),
          )),
        ),
      );
}

// ---------- forgot password ----------
/// Two steps on one screen, like login's email-code step: enter the email, then the emailed code plus
/// a new password. A successful reset does NOT sign the user in: it sends them back to the login screen
/// to sign in with the new password (the server has ended all their old logins by then anyway).
class ForgotPasswordScreen extends StatefulWidget {
  final String initialEmail; // carried over from whatever was already typed on the login screen
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeSent = false, _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_codeSent) {
        await api.requestPasswordReset(_email.text.trim());
        if (mounted) setState(() => _codeSent = true); // show the code + new password fields
        return;
      }
      await api.resetPassword(_email.text.trim(), _code.text.trim(), _password.text);
      if (!mounted) return;
      // A fresh, empty login screen, replacing this screen and the old login one.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (r) => false,
      );
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Password reset. Please sign in with your new password.')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_codeSent ? 'Enter the code' : 'Reset password')),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              if (!_codeSent) ...[
                const Text("Enter the email you signed up with and we'll send you a code to reset your password."),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _email,
                  autofillHints: [AutofillHints.email],
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                    return null;
                  },
                ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: 'We sent a code to ${_email.text.trim()}.',
                  busy: _busy,
                  onResend: () => api.requestPasswordReset(_email.text.trim()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  autofillHints: [AutofillHints.newPassword],
                  obscureText: _hide,
                  decoration: InputDecoration(
                    labelText: 'New password',
                    helperText: 'Password must be 8 characters or more with an uppercase character and a number',
                    suffixIcon: IconButton(
                      tooltip: _hide ? 'Show password' : 'Hide password',
                      icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hide = !_hide),
                    ),
                  ),
                  validator: (v) {
                    final value = v ?? '';
                    if (value.isEmpty) return 'Enter a new password';
                    final problem = _newPasswordProblem(value);
                    if (problem != null) return problem;
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  autofillHints: [AutofillHints.newPassword],
                  obscureText: _hide,
                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                  validator: (v) => v != _password.text ? "Passwords don't match" : null,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _codeSent = false),
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
                child: Text(_busy ? 'Please wait...' : (_codeSent ? 'Reset password' : 'Send code')),
              ),
            ]),
          )),
        ),
      );
}

// ---------- link an account ----------
class LinkAccountScreen extends StatefulWidget {
  /// Called after a request has been filed, so the caller can reload (it may now have a pending request to show).
  final Future<void> Function() onLinked;
  const LinkAccountScreen({super.key, required this.onLinked});
  @override
  State<LinkAccountScreen> createState() => _LinkAccountScreenState();
}

class _LinkAccountScreenState extends State<LinkAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _no = TextEditingController();
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _declined = []; // earlier requests that were turned down, shown as a note

  @override
  void initState() {
    super.initState();
    _loadDeclined();
  }

  Future<void> _loadDeclined() async {
    try {
      final all = await api.linkRequests();
      final declined = [for (final r in all) if (r['status'] == 'REJECTED') Map<String, dynamic>.from(r as Map)];
      if (mounted) setState(() => _declined = declined);
    } catch (_) {
      // Only a courtesy note: never block linking over it.
    }
  }

  Future<void> _dismiss(Map<String, dynamic> r) async {
    setState(() => _declined.remove(r));
    try {
      await api.dismissLinkRequest(r['id'] as int);
    } catch (_) {}
  }

  @override
  void dispose() {
    _no.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.requestLink(_no.text.trim());
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RequestReceivedScreen(onBack: () => Navigator.of(context).pop()),
      ));
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
          actions: [IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => signOut(context))],
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
              const Text('Link your Account', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text("Enter the account number on your bill and we'll link it to your login once we've "
                  'checked it.'),
              const SizedBox(height: 24),
              for (final r in _declined)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Panel(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.info_outline, color: Color(0xFFB42318)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text("Your request to link account ${r['account_no']} was declined. If you think "
                            'that was a mistake, please contact us. You can check the number and send a new request below.'),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        icon: const Icon(Icons.close),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _dismiss(r),
                      ),
                    ]),
                  ),
                ),
              TextFormField(
                controller: _no,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Account number', hintText: 'DEMO-000001'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your account number' : null,
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
                child: Text(_busy ? 'Please wait...' : 'Submit'),
              ),
            ]),
          ),
        ),
      );
}

/// "Request Received!": shown right after a link request is filed, and again whenever the login has no
/// account yet but a request is still waiting.
class RequestReceivedScreen extends StatelessWidget {
  final VoidCallback onBack;
  final String buttonLabel;
  final Widget? extra; // optional second action under the message (e.g. "Check status")
  const RequestReceivedScreen({super.key, required this.onBack, this.buttonLabel = 'Back to Menu', this.extra});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Spacer(flex: 2),
              const Text(appName, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
              const SizedBox(height: 32),
              const Text('Request Received!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text(
                'We have received your Link Account request, and we will process it within 24 hours.',
                textAlign: TextAlign.center,
              ),
              if (extra != null) ...[const SizedBox(height: 12), extra!],
              const Spacer(flex: 3),
              FilledButton(style: _bigButton, onPressed: onBack, child: Text(buttonLabel)),
            ]),
          ),
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

class AccountPage extends StatefulWidget {
  final Map<String, dynamic> acct;
  final Future<void> Function() onChanged;
  const AccountPage(this.acct, this.onChanged, {super.key});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  Map<String, dynamic> get acct => widget.acct;
  Future<void> Function() get onChanged => widget.onChanged;
  int _meVersion = 0; // bumped to re-fetch the email / password status after a change

  /// Changing the email or mobile number, and deleting the account, all ask for the current password, and
  /// a login made only through Google has none yet. Offers to set one (through the same emailed-code flow as
  /// "Forgot password") and returns whether the caller can go ahead.
  Future<bool> _hasPasswordOrOffer(Map<String, dynamic> me) => _ensurePassword(context, me);

  void _openSetPassword(Map<String, dynamic> me) => _openSetPasswordScreen(context, me);

  Future<void> _changeEmail(Map<String, dynamic> me) async {
    if (!await _hasPasswordOrOffer(me) || !mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangeContactScreen(
        title: 'Change email address',
        intro: "Enter your new email address and your current password. We'll send a code to the new "
            "address to confirm it's yours.",
        fieldLabel: 'New email address',
        keyboard: TextInputType.emailAddress,
        validator: _emailValidator,
        codeDescription: (value) => 'We sent a code to $value.',
        start: (value, password) => api.startEmailChange(value, password),
        confirm: (code) => api.confirmEmailChange(code),
        successMessage: 'Email address updated.',
      ),
    ));
    if (done == true && mounted) setState(() => _meVersion++);
  }

  Future<void> _changePassword(Map<String, dynamic> me) async {
    if (me['has_password'] != true) return _openSetPassword(me); // a Google-only login: nothing to "change" yet
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ChangePasswordScreen()));
  }

  Future<void> _changeMobile(Map<String, dynamic> me) async {
    if (!await _hasPasswordOrOffer(me) || !mounted) return;
    final accountId = acct['id'] as int;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChangeContactScreen(
        title: 'Change mobile number',
        intro: "Enter the new mobile number for account ${acct['account_no']} and your current password. "
            "We'll text a code to the new number to confirm it's yours.",
        fieldLabel: 'New mobile number',
        keyboard: TextInputType.phone,
        validator: _mobileValidator,
        codeDescription: (value) => 'We sent a code by SMS to $value.',
        start: (value, password) => api.startMobileChange(accountId, value, password),
        confirm: (code) => api.confirmMobileChange(accountId, code),
        successMessage: 'Mobile number updated.',
      ),
    ));
    if (done == true) await onChanged(); // reloads the account, which rebuilds this page with the new number
  }

  Future<void> _deleteAccount() async {
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> me;
    try {
      me = await api.me();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted || !await _hasPasswordOrOffer(me) || !mounted) return;
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordConfirmDialog(
        title: 'Delete your account?',
        message: "This permanently deletes your NetPulse login. Your internet subscription and billing "
            "records aren't affected, and you can sign up again and link your account later.",
        confirmLabel: 'Delete account',
        busyLabel: 'Deleting...',
        destructive: true,
        action: api.deleteAccount,
      ),
    );
    if (deleted == true) accountDeleted();
  }

  Future<void> _unlink() async {
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> me;
    try {
      me = await api.me();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted || !await _hasPasswordOrOffer(me) || !mounted) return;
    final id = acct['id'] as int;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordConfirmDialog(
        title: 'Unlink this account?',
        message: 'You can link it again later with the account number and registered mobile number.',
        confirmLabel: 'Unlink',
        busyLabel: 'Unlinking...',
        action: (pw) => api.unlink(id, pw),
      ),
    );
    if (done == true) await onChanged();
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
      // Sign-in details load separately: the email and whether there's a password belong to the login, not
      // to this internet account, so they come from their own request.
      Loader<Map<String, dynamic>>(
        key: ValueKey(_meVersion),
        load: api.me,
        builder: (c, me) {
          final hasPassword = me['has_password'] == true;
          return Panel(
            child: Column(children: [
              _editableRow(c, 'Email Address', '${me['email']}', 'Change email address', () => _changeEmail(me)),
              const Divider(height: 1),
              _editableRow(c, 'Password', hasPassword ? '••••••••••' : 'Not set',
                  hasPassword ? 'Change password' : 'Set password', () => _changePassword(me)),
              const Divider(height: 1),
              _editableRow(c, 'Mobile Number', '${acct['mobile']}', 'Change mobile number', () => _changeMobile(me)),
            ]),
          );
        },
      ),
      OutlinedButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ReportIssueScreen(accountId: acct['id'] as int))),
        child: const Text('Report an issue'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _unlink, child: const Text('Unlink this account')),
      const SizedBox(height: 8),
      FilledButton(
        style: _bigButton.merge(
            FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318), foregroundColor: Colors.white)),
        onPressed: _deleteAccount,
        child: const Text('Delete Account'),
      ),
    ]);
  }
}

/// One line of the sign-in details panel: label on the left, the current value on the right with a small
/// "Change ..." link under it.
Widget _editableRow(BuildContext context, String label, String value, String linkText, VoidCallback onTap) {
  final primary = Theme.of(context).colorScheme.primary;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 108, child: Text(label)),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(linkText, style: TextStyle(fontSize: 12, color: primary)),
            ),
          ),
        ]),
      ),
    ]),
  );
}

/// A password box with its show / hide eye, used by the change-password screen, the change-email and
/// change-mobile screens, and the delete-account dialog.
Widget _passwordField({
  required TextEditingController controller,
  required String label,
  required bool hide,
  required VoidCallback onToggle,
  required String? Function(String?) validator,
  String? helper,
  Iterable<String>? autofillHints,
}) =>
    TextFormField(
      controller: controller,
      autofillHints: autofillHints,
      obscureText: hide,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: IconButton(
          tooltip: hide ? 'Show password' : 'Hide password',
          icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: onToggle,
        ),
      ),
      validator: validator,
    );

String? _emailValidator(String? v) {
  final value = v?.trim() ?? '';
  if (value.isEmpty) return 'Enter the new email address';
  if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
  return null;
}

/// The rule for a new password, matching the server's. Null when it's fine.
String? _newPasswordProblem(String value) {
  if (value.length < 8 || !value.contains(RegExp('[A-Z]')) || !value.contains(RegExp('[0-9]'))) {
    return '8+ characters, an uppercase letter and a number';
  }
  return null;
}

String? _mobileValidator(String? v) {
  final value = (v ?? '').replaceAll(RegExp(r'[\s-]'), '');
  if (value.isEmpty) return 'Enter a mobile number';
  if (!RegExp(r'^\+?\d{10,13}$').hasMatch(value)) return 'Enter a valid mobile number';
  return null;
}

/// After the NetPulse login has been deleted: back to a fresh sign-in screen.
void accountDeleted() {
  navigatorKey.currentState?.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (r) => false,
  );
  messengerKey.currentState?.showSnackBar(
    const SnackBar(content: Text('Your NetPulse account was deleted.')),
  );
}

/// Changes an email address or a mobile number, which share the same two steps: type the new value with
/// the current password, then enter the code sent to the NEW address / number. Pops with true when done.
class ChangeContactScreen extends StatefulWidget {
  final String title, intro, fieldLabel, successMessage;
  final TextInputType keyboard;
  final String? Function(String?) validator;
  final String Function(String value) codeDescription;
  final Future<void> Function(String value, String password) start;
  final Future<void> Function(String code) confirm;
  const ChangeContactScreen({
    super.key,
    required this.title,
    required this.intro,
    required this.fieldLabel,
    required this.successMessage,
    required this.keyboard,
    required this.validator,
    required this.codeDescription,
    required this.start,
    required this.confirm,
  });
  @override
  State<ChangeContactScreen> createState() => _ChangeContactScreenState();
}

class _ChangeContactScreenState extends State<ChangeContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _value = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false, _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_codeSent) {
        await widget.start(_value.text.trim(), _password.text);
        if (mounted) setState(() => _codeSent = true); // now ask for the code that was just sent
        return;
      }
      await widget.confirm(_code.text.trim());
      if (!mounted) return;
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(widget.successMessage)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_codeSent ? 'Enter the code' : widget.title)),
        body: SafeArea(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              if (!_codeSent) ...[
                Text(widget.intro),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _value,
                  keyboardType: widget.keyboard,
                  decoration: InputDecoration(labelText: widget.fieldLabel),
                  validator: widget.validator,
                ),
                const SizedBox(height: 12),
                _passwordField(
                  controller: _password,
                  autofillHints: [AutofillHints.password],
                  label: 'Current password',
                  hide: _hide,
                  onToggle: () => setState(() => _hide = !_hide),
                  validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null,
                ),
              ] else ...[
                stepTwoDots(context),
                CodeEntry(
                  controller: _code,
                  description: widget.codeDescription(_value.text.trim()),
                  busy: _busy,
                  onResend: () => widget.start(_value.text.trim(), _password.text),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => setState(() => _codeSent = false),
                  child: const Text('Go back'),
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
                child: Text(_busy ? 'Please wait...' : (_codeSent ? 'Confirm' : 'Send code')),
              ),
            ]),
          ),
        ),
      );
}

/// Changes the password from inside the app: current password, then the new one. The server signs out
/// the user's other devices and gives this one a fresh login, so nobody has to sign in again here.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false, _hideCurrent = true, _hideNew = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.changePassword(_current.text, _new.text);
      if (!mounted) return;
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Password changed. Your other devices were signed out.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: SafeArea(
          child: AutofillGroup(child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              _passwordField(
                controller: _current,
                autofillHints: [AutofillHints.password],
                label: 'Current password',
                hide: _hideCurrent,
                onToggle: () => setState(() => _hideCurrent = !_hideCurrent),
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null,
              ),
              const SizedBox(height: 12),
              _passwordField(
                controller: _new,
                autofillHints: [AutofillHints.newPassword],
                label: 'New password',
                helper: 'Password must be 8 characters or more with an uppercase character and a number',
                hide: _hideNew,
                onToggle: () => setState(() => _hideNew = !_hideNew),
                validator: (v) {
                  final value = v ?? '';
                  if (value.isEmpty) return 'Enter a new password';
                  final problem = _newPasswordProblem(value);
                    if (problem != null) return problem;
                  if (value == _current.text) return "Choose a password that's different from your current one";
                  return null;
                },
              ),
              const SizedBox(height: 12),
              _passwordField(
                controller: _confirm,
                autofillHints: [AutofillHints.newPassword],
                label: 'Confirm new password',
                hide: _hideNew,
                onToggle: () => setState(() => _hideNew = !_hideNew),
                validator: (v) => v != _new.text ? "Passwords don't match" : null,
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
                child: Text(_busy ? 'Please wait...' : 'Change password'),
              ),
            ]),
          )),
        ),
      );
}

/// True when this login has a password to confirm with. A Google-only login doesn't yet, so it's offered
/// the set-a-password flow instead and this returns false.
Future<bool> _ensurePassword(BuildContext context, Map<String, dynamic> me) async {
  if (me['has_password'] == true) return true;
  final setNow = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Set a password first'),
      content: const Text("This needs your password, and you signed in with Google so you don't have one yet. "
          "Set one now: we'll email you a code, and you'll sign in again afterwards."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Set password')),
      ],
    ),
  );
  if (setNow == true && context.mounted) _openSetPasswordScreen(context, me);
  return false;
}

void _openSetPasswordScreen(BuildContext context, Map<String, dynamic> me) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ForgotPasswordScreen(initialEmail: '${me['email']}')));
}

/// The usual "type your password to confirm" step for any change: checks the login has a password,
/// shows the dialog, and runs [action] with it. True once the action has gone through.
Future<bool> confirmWithPassword(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String busyLabel,
  required Future<void> Function(String password) action,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  Map<String, dynamic> me;
  try {
    me = await api.me();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
  if (!context.mounted || !await _ensurePassword(context, me) || !context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _PasswordConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      busyLabel: busyLabel,
      action: action,
    ),
  );
  return done == true;
}

/// Asks for the password one more time before something is changed or removed. [action] runs with the
/// typed password (and throws if the server refuses it); the dialog pops true once it succeeds.
class _PasswordConfirmDialog extends StatefulWidget {
  final String title, message, confirmLabel, busyLabel;
  final bool destructive;
  final Future<void> Function(String password) action;
  const _PasswordConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.busyLabel,
    required this.action,
    this.destructive = false,
  });
  @override
  State<_PasswordConfirmDialog> createState() => _PasswordConfirmDialogState();
}

class _PasswordConfirmDialogState extends State<_PasswordConfirmDialog> {
  final _password = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password to confirm');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.action(_password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${widget.message}\n\nEnter your password to confirm.'),
            const SizedBox(height: 16),
            _passwordField(
              controller: _password,
              autofillHints: [AutofillHints.password],
              label: 'Password',
              hide: _hide,
              onToggle: () => setState(() => _hide = !_hide),
              validator: (_) => null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: widget.destructive
                ? FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318), foregroundColor: Colors.white)
                : null,
            onPressed: _busy ? null : _confirm,
            child: Text(_busy ? widget.busyLabel : widget.confirmLabel),
          ),
        ],
      );
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