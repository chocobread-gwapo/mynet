import 'package:flutter/material.dart';

import 'package:mynet/api.dart';
import 'package:mynet/core/config.dart';
import 'package:mynet/screens/login_screen.dart';

final api = Api();

// These let code without a BuildContext (like the API client) switch screens and show a message.
final navigatorKey = GlobalKey<NavigatorState>();

final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Ends a "Remember me"-unticked login once the app has been out of sight for [backgroundLogoutAfter].
/// Timers don't run reliably while an app is in the background, so this just notes when the app was
/// hidden and compares the clock the moment it comes back. (If Android kills the app in the meantime,
/// the in-memory login is already gone, so there's nothing left to end.)
class BackgroundLogout with WidgetsBindingObserver {
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
