import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mynet/core/config.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/screens/login_screen.dart';
import 'package:mynet/screens/shell.dart';

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
