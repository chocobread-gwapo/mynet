import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The server the test traffic goes to: Cloudflare's public speed-test endpoints (the ones behind
/// speed.cloudflare.com). Point this at your own server later if you want the test to measure the path to it.
const speedTestBase = 'https://speed.cloudflare.com';

enum SpeedPhase { idle, ping, download, upload, done, failed }

/// A snapshot of the test while it runs; the last one has [phase] done (or failed).
class SpeedProgress {
  final SpeedPhase phase;
  final double liveMbps; // the speed right now, during the download and upload phases
  final double? pingMs, jitterMs, downloadMbps, uploadMbps;
  final String? error;
  const SpeedProgress({
    this.phase = SpeedPhase.idle,
    this.liveMbps = 0,
    this.pingMs,
    this.jitterMs,
    this.downloadMbps,
    this.uploadMbps,
    this.error,
  });

  SpeedProgress copyWith({
    SpeedPhase? phase,
    double? liveMbps,
    double? pingMs,
    double? jitterMs,
    double? downloadMbps,
    double? uploadMbps,
    String? error,
  }) =>
      SpeedProgress(
        phase: phase ?? this.phase,
        liveMbps: liveMbps ?? this.liveMbps,
        pingMs: pingMs ?? this.pingMs,
        jitterMs: jitterMs ?? this.jitterMs,
        downloadMbps: downloadMbps ?? this.downloadMbps,
        uploadMbps: uploadMbps ?? this.uploadMbps,
        error: error ?? this.error,
      );
}

/// Measures latency, download and upload speed, one after the other (about 15 seconds in all).
/// Use [run] to start and listen to the progress; [cancel] stops it early.
class SpeedTester {
  bool _cancelled = false;
  final List<http.Client> _clients = [];

  void cancel() {
    _cancelled = true;
    for (final c in _clients) {
      c.close(); // closing a client aborts whatever it is still downloading or uploading
    }
    _clients.clear();
  }

  http.Client _newClient() {
    final c = http.Client();
    _clients.add(c);
    return c;
  }

  Stream<SpeedProgress> run() {
    final out = StreamController<SpeedProgress>(onCancel: cancel);
    () async {
      var p = const SpeedProgress(phase: SpeedPhase.ping);
      void emit(SpeedProgress next) {
        p = next;
        if (!out.isClosed) out.add(p);
      }

      try {
        emit(p);
        final lat = await _ping();
        emit(p.copyWith(phase: SpeedPhase.download, pingMs: lat.ping, jitterMs: lat.jitter, liveMbps: 0));
        final down = await _download((mbps) => emit(p.copyWith(liveMbps: mbps)));
        emit(p.copyWith(phase: SpeedPhase.upload, downloadMbps: down, liveMbps: 0));
        final up = await _upload((mbps) => emit(p.copyWith(liveMbps: mbps)));
        emit(p.copyWith(phase: SpeedPhase.done, uploadMbps: up, liveMbps: 0));
      } catch (e) {
        if (!_cancelled) {
          // The technical reason is shown in small print so a failure can be diagnosed (and reported) accurately.
          emit(p.copyWith(
            phase: SpeedPhase.failed,
            error: "Couldn't complete the speed test. Check your connection and try again.\n(${p.phase.name}: $e)",
          ));
        }
      } finally {
        cancel();
        await out.close();
      }
    }();
    return out.stream;
  }

  Future<({double ping, double jitter})> _ping() async {
    final client = _newClient();
    final rtts = <double>[];
    for (var i = 0; i < 7 && !_cancelled; i++) {
      final sw = Stopwatch()..start();
      final res = await client.get(Uri.parse('$speedTestBase/__down?bytes=0')).timeout(const Duration(seconds: 5));
      sw.stop();
      if (res.statusCode >= 400) throw StateError('status ${res.statusCode}');
      if (i > 0) rtts.add(sw.elapsedMicroseconds / 1000.0); // the first request also pays for connecting, so skip it
    }
    if (rtts.isEmpty) throw StateError('no ping result');
    final sorted = [...rtts]..sort();
    var jitter = 0.0;
    for (var i = 1; i < rtts.length; i++) {
      jitter += (rtts[i] - rtts[i - 1]).abs();
    }
    return (ping: sorted[sorted.length ~/ 2], jitter: rtts.length > 1 ? jitter / (rtts.length - 1) : 0.0);
  }

  /// Several downloads at once (one stream often can't fill a fast connection), for about 8 seconds. The first
  /// second is ignored: that's the connection speeding up.
  Future<double> _download(void Function(double mbps) onLive) async {
    const streams = 4;
    const total = Duration(seconds: 8);
    const warmUp = Duration(seconds: 1);
    final clients = [for (var i = 0; i < streams; i++) _newClient()];
    final sw = Stopwatch()..start();
    var bytes = 0, warmBytes = 0, lastBytes = 0;
    Duration? warmAt;
    var lastAt = Duration.zero;
    var smooth = 0.0;
    final ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final now = sw.elapsed;
      if (warmAt == null && now >= warmUp) {
        warmAt = now;
        warmBytes = bytes;
      }
      final secs = (now - lastAt).inMicroseconds / 1e6;
      if (secs > 0) {
        final instant = (bytes - lastBytes) * 8 / secs / 1e6;
        smooth = smooth == 0 ? instant : smooth * 0.6 + instant * 0.4;
        onLive(smooth);
      }
      lastBytes = bytes;
      lastAt = now;
    });

    // Downloads are requested in 10 MB pieces (the loop just asks for the next one), which servers accept far more
    // reliably than one huge file. One stream failing doesn't end the test as long as some data arrived.
    Object? lastError;
    Future<void> worker(http.Client client) async {
      while (!_cancelled && sw.elapsed < total) {
        try {
          final res = await client
              .send(http.Request('GET', Uri.parse('$speedTestBase/__down?bytes=10000000')))
              .timeout(const Duration(seconds: 8));
          if (res.statusCode >= 400) throw StateError('server answered ${res.statusCode}');
          await for (final chunk in res.stream) {
            bytes += chunk.length;
            if (_cancelled || sw.elapsed >= total) break; // leaving the loop drops the rest of this download
          }
        } catch (e) {
          lastError = e;
          if (_cancelled || sw.elapsed >= total) return;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }

    try {
      await Future.wait([for (final c in clients) worker(c)]).timeout(total + const Duration(seconds: 6));
    } on TimeoutException {
      // A stalled stream: use what arrived.
    } finally {
      ticker.cancel();
      sw.stop();
      for (final c in clients) {
        c.close();
      }
    }
    if (_cancelled) throw StateError('cancelled');
    if (bytes == 0) throw lastError ?? StateError('no data received');
    final start = warmAt ?? Duration.zero;
    final counted = warmAt == null ? bytes : bytes - warmBytes;
    final secs = (sw.elapsed - start).inMicroseconds / 1e6;
    return secs > 0 ? counted * 8 / secs / 1e6 : 0.0;
  }

  /// Several uploads at once, for about 6 seconds, counting each chunk once the server has taken it.
  Future<double> _upload(void Function(double mbps) onLive) async {
    const streams = 3;
    const total = Duration(seconds: 6);
    const chunkSize = 1024 * 1024;
    final payload = Uint8List(chunkSize);
    final clients = [for (var i = 0; i < streams; i++) _newClient()];
    final sw = Stopwatch()..start();
    var done = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final secs = sw.elapsedMicroseconds / 1e6;
      if (secs > 0.5) onLive(done * 8 / secs / 1e6);
    });

    Object? lastError;
    Future<void> worker(http.Client client) async {
      while (!_cancelled && sw.elapsed < total) {
        try {
          final res = await client
              .post(
                Uri.parse('$speedTestBase/__up'),
                headers: {'Content-Type': 'application/octet-stream'},
                body: payload,
              )
              .timeout(const Duration(seconds: 8));
          if (res.statusCode >= 400) throw StateError('server answered ${res.statusCode}');
          done += chunkSize;
        } catch (e) {
          lastError = e;
          if (_cancelled || sw.elapsed >= total) return;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }

    try {
      await Future.wait([for (final c in clients) worker(c)]).timeout(total + const Duration(seconds: 8));
    } on TimeoutException {
      // A stalled upload: use what went through.
    } finally {
      ticker.cancel();
      sw.stop();
      for (final c in clients) {
        c.close();
      }
    }
    if (_cancelled) throw StateError('cancelled');
    if (done == 0) throw lastError ?? StateError('nothing was uploaded');
    final secs = sw.elapsedMicroseconds / 1e6;
    return secs > 0 ? done * 8 / secs / 1e6 : 0.0;
  }
}