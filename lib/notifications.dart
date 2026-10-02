import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _dueChannelId = 'due_reminders';
final _plugin = FlutterLocalNotificationsPlugin();

/// Call once at startup, before scheduling anything.
Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Manila')); // change this if you're outside PH time

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await _plugin.initialize(settings: const InitializationSettings(android: androidInit, iOS: iosInit));

  const channel = AndroidNotificationChannel(
    _dueChannelId,
    'Bill due reminders',
    description: 'Reminds you a few days before your internet bill is due',
    importance: Importance.high,
  );
  await _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await Permission.notification.request(); // no-op on platforms that don't need it
}

/// Schedules a reminder 3 days before the due date, or clears it if nothing is owed.
/// Safe to call every time account data refreshes — it replaces any previous reminder
/// for the same account rather than stacking duplicates.
Future<void> scheduleDueReminder({
  required int accountId,
  required int amountDue,
  required DateTime dueDate,
  required String planName,
}) async {
  final id = 90000 + accountId; // stable per-account id
  await _plugin.cancel(id: id);
  if (amountDue <= 0) return; // nothing owed right now

  final reminderDay = dueDate.subtract(const Duration(days: 3));
  final reminderTime = tz.TZDateTime(tz.local, reminderDay.year, reminderDay.month, reminderDay.day, 9);
  if (reminderTime.isBefore(tz.TZDateTime.now(tz.local))) return; // too close to the due date for a 3-day warning

  final pesos = (amountDue / 100).toStringAsFixed(2);
  await _plugin.zonedSchedule(
    id: id,
    title: 'Bill due soon',
    body: 'Your $planName bill of ₱$pesos is due in 3 days.',
    scheduledDate: reminderTime,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(_dueChannelId, 'Bill due reminders', importance: Importance.high),
    ),
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );
}