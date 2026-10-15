import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mynet/core/speed_test.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/screens/report_issue_screen.dart';
import 'package:mynet/widgets/common.dart';

/// Measures ping, download and upload speed from this phone and compares the download with the plan's speed.
class SpeedTestScreen extends StatefulWidget {
  final int planMbps;
  final int accountId;
  const SpeedTestScreen({super.key, required this.planMbps, required this.accountId});
  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  SpeedTester? _tester;
  StreamSubscription<SpeedProgress>? _sub;
  SpeedProgress _p = const SpeedProgress();

  bool get _running => _p.phase == SpeedPhase.ping || _p.phase == SpeedPhase.download || _p.phase == SpeedPhase.upload;

  void _start() {
    _sub?.cancel();
    final tester = SpeedTester();
    _tester = tester;
    setState(() => _p = const SpeedProgress(phase: SpeedPhase.ping));
    _sub = tester.run().listen((p) {
      if (mounted) setState(() => _p = p);
    });
  }

  void _stop() {
    _sub?.cancel();
    _tester?.cancel();
    setState(() => _p = const SpeedProgress());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tester?.cancel();
    super.dispose();
  }

  String _num(double? v, {int digits = 1}) => v == null ? '--' : v.toStringAsFixed(v >= 100 ? 0 : digits);

  Widget _stat(String label, String value, String unit) => Expanded(
        child: Column(children: [
          Text(label, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          Text(unit, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
        ]),
      );

  /// What to show in the middle of the dial, and the small caption under it.
  (String, String) _dial() {
    switch (_p.phase) {
      case SpeedPhase.ping:
        return ('--', 'Checking latency...');
      case SpeedPhase.download:
        return (_num(_p.liveMbps), 'Download, Mbps');
      case SpeedPhase.upload:
        return (_num(_p.liveMbps), 'Upload, Mbps');
      case SpeedPhase.done:
        return (_num(_p.downloadMbps), 'Download, Mbps');
      default:
        return ('--', 'Ready');
    }
  }

  Widget _verdict(BuildContext context) {
    final down = _p.downloadMbps ?? 0;
    final plan = widget.planMbps;
    final ratio = plan > 0 ? down / plan : 1.0;
    final pct = (ratio * 100).round();
    final String title, advice;
    final Color color;
    if (ratio >= 0.8) {
      title = 'Looking good';
      advice = 'You are getting $pct% of your $plan Mbps plan.';
      color = kGood;
    } else if (ratio >= 0.5) {
      title = 'A bit below your plan';
      advice = 'You are getting $pct% of your $plan Mbps plan. Wi-Fi is often the reason: try again closer to the '
          'router, or on a device connected by cable.';
      color = kWarn;
    } else {
      title = 'Much slower than your plan';
      advice = 'You are getting $pct% of your $plan Mbps plan. Try restarting your router and testing again '
          'next to it. If it stays this slow, tell us.';
      color = const Color(0xFFB42318);
    }
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: color)),
        const SizedBox(height: 6),
        Text(advice),
        if (ratio < 0.5) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ReportIssueScreen(accountId: widget.accountId))),
            child: const Text('Report an issue'),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaleMax = math.max(widget.planMbps * 1.25, 20.0);
    final value = (_p.phase == SpeedPhase.download || _p.phase == SpeedPhase.upload)
        ? _p.liveMbps
        : (_p.phase == SpeedPhase.done ? (_p.downloadMbps ?? 0) : 0.0);
    final (big, caption) = _dial();
    return Scaffold(
      appBar: AppBar(title: const Text('Speed test')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const SizedBox(height: 8),
          Center(
            child: SizedBox(
              width: 260,
              height: 230,
              child: CustomPaint(
                painter: _DialPainter(
                  fraction: (value / scaleMax).clamp(0.0, 1.0),
                  track: scheme.surfaceContainerHighest,
                  fill: scheme.primary,
                ),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(big,
                        style: const TextStyle(
                            fontSize: 52, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                    Text(caption, style: TextStyle(color: Theme.of(context).hintColor)),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Panel(
            child: Row(children: [
              _stat('Ping', _num(_p.pingMs, digits: 0), 'ms'),
              _stat('Jitter', _num(_p.jitterMs), 'ms'),
              _stat('Download', _num(_p.downloadMbps), 'Mbps'),
              _stat('Upload', _num(_p.uploadMbps), 'Mbps'),
            ]),
          ),
          if (_p.phase == SpeedPhase.done) _verdict(context),
          if (_p.phase == SpeedPhase.failed && _p.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_p.error!, style: const TextStyle(color: Color(0xFFB42318))),
            ),
          const SizedBox(height: 4),
          if (_running)
            OutlinedButton(style: bigButton, onPressed: _stop, child: const Text('Stop'))
          else
            FilledButton(
              style: bigButton,
              onPressed: _start,
              child: Text(_p.phase == SpeedPhase.done || _p.phase == SpeedPhase.failed ? 'Test again' : 'Start test'),
            ),
          const SizedBox(height: 16),
          Text(
            'The test takes about 15 seconds and can use a few hundred MB of data, so run it on Wi-Fi. It measures '
            'the connection between this phone and a test server, so your Wi-Fi signal affects the result.',
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
          ),
        ]),
      ),
    );
  }
}

/// A speedometer-style arc: a grey track with the part up to the current speed filled in.
class _DialPainter extends CustomPainter {
  final double fraction; // 0..1 of the way round
  final Color track, fill;
  _DialPainter({required this.fraction, required this.track, required this.fill});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: math.min(size.width, size.height) / 2 - stroke);
    const start = 0.75 * math.pi; // 135 degrees, bottom left
    const sweep = 1.5 * math.pi; // round the top to bottom right
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(rect, start, sweep, false, base..color = track);
    if (fraction > 0) canvas.drawArc(rect, start, sweep * fraction, false, base..color = fill);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.fraction != fraction || old.track != track || old.fill != fill;
}
