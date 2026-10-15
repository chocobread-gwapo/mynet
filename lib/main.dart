import 'package:flutter/material.dart';

import 'package:mynet/app.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  api.onUnauthorized = sessionExpired;
  WidgetsBinding.instance.addObserver(BackgroundLogout());
  runApp(const App());
}
