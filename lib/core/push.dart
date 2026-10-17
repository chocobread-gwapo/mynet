// Firebase marks getToken()/onTokenRefresh as deprecated in favor of register()/onRegistered, but the newer pair is
// not a drop-in replacement: onRegistered hands out a Firebase Installation ID (FID, for "direct send"), not the FCM
// token this app's server sends to. Switching would need the server to address pushes by FID too, so the working
// methods are kept on purpose.
// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:mynet/core/session.dart';

/// Push notifications through Firebase, so the phone is told about changes (payment received, service
/// suspended/restored, new bill, link request decided...) even when the app is closed.
///
/// Everything here is best-effort: if Firebase isn't set up on this build (no google-services.json yet), or the
/// user says no to notifications, the app carries on exactly as before. Nothing in here can break sign-in.
class Push {
  static bool _started = false;
  static StreamSubscription<String>? _refreshSub;

  /// Call once the user is signed in (the Shell does). Safe to call many times.
  static Future<void> start() async {
    if (_started) {
      await _register();
      return;
    }
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(); // Android 13+ shows the "Allow notifications?" prompt
      await _makeChannel();
      _refreshSub = messaging.onTokenRefresh.listen((t) => _send(t));
      _started = true;
      await _register();
    } catch (e) {
      debugPrint('Push not available: $e');
    }
  }

  /// The channel the server's pushes are sent to ("heads-up" style, with sound).
  static Future<void> _makeChannel() async {
    try {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'netpulse_alerts',
        'Account alerts',
        description: 'Payments, bills and service changes',
        importance: Importance.high,
      ));
    } catch (_) {
      // Without it Android uses the default channel: pushes still arrive, just less prominently.
    }
  }

  static Future<void> _register() async {
    try {
      final t = await FirebaseMessaging.instance.getToken();
      if (t != null) await _send(t);
    } catch (e) {
      debugPrint('Push token unavailable: $e');
    }
  }

  static Future<void> _send(String token) async {
    api.pushToken = token;
    try {
      await api.registerDevice(token);
    } catch (_) {
      // Offline or signed out: the next start() tries again.
    }
  }

  static Future<void> dispose() async {
    await _refreshSub?.cancel();
    _started = false;
  }
}