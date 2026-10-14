import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// The Android emulator reaches your PC's localhost at the special address 10.0.2.2 — that's what
/// this pointed at before. A real phone instead needs your PC's own address on the local network
/// (find it with ipconfig; Wi-Fi or Ethernet both work, as long as the phone's Wi-Fi is on the same
/// router). Switch this back to 'http://10.0.2.2:8000/api/v1' if you go back to the emulator.
const String baseUrl = 'http://192.168.18.19:8000/api/v1';

const _tokenKey = 'auth_token';
const _oldEmailKey = 'remembered_email'; // an earlier version saved the email here; it's only cleaned up now
const _rememberKey = 'remember_me'; // '1' or '0': the box's state at the last sign-in
const _storage = FlutterSecureStorage();

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class Api {
  String? token;

  /// True while the current login is the in-memory-only kind ("Remember me" was unticked). Those logins
  /// are also ended after the app has been in the background for a while (see _BackgroundLogout in main.dart).
  bool sessionOnly = false;

  /// Set by the app at startup. Called when the server rejects the login token this client sent,
  /// so the app can send the user back to the sign-in screen.
  void Function()? onUnauthorized;

  /// Reads a token saved from a previous session, if any. Called once at app startup.
  Future<String?> loadSavedToken() async {
    try {
      return await _storage.read(key: _tokenKey);
    } catch (_) {
      return null; // corrupted or inaccessible storage: just treat it as logged out
    }
  }

  /// With [persist] false (the "Remember me" box is unticked) the token lives in memory only: it works
  /// until the app is closed, and any copy saved by an earlier sign-in is removed so it can't outlive that.
  Future<void> _saveToken(String value, {bool persist = true}) async {
    token = value;
    sessionOnly = !persist;
    if (persist) {
      await _storage.write(key: _tokenKey, value: value);
    } else {
      await _storage.delete(key: _tokenKey);
    }
  }

  /// Whether "Remember me" was ticked at the last sign-in. False when nothing is saved, so the box
  /// starts unticked until someone chooses otherwise. Also deletes the email an earlier version of the
  /// app saved for pre-filling the login screen: the app no longer remembers or fills in emails.
  Future<bool> loadRememberMe() async {
    try {
      await _storage.delete(key: _oldEmailKey);
      return await _storage.read(key: _rememberKey) == '1';
    } catch (_) {
      return false;
    }
  }

  /// Saves the state of the "Remember me" box, so it's still as it was left next time.
  Future<void> saveRememberMe(bool remember) async {
    try {
      await _storage.write(key: _rememberKey, value: remember ? '1' : '0');
    } catch (_) {
      // Convenience only: never fail a sign-in over it.
    }
  }

  /// Clears both the in-memory token and the saved copy. Safe to call without awaiting.
  Future<void> clearToken() async {
    token = null;
    sessionOnly = false;
    await _storage.delete(key: _tokenKey);
  }

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final sentToken = token; // remember which token this request used
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    req.headers['Content-Type'] = 'application/json';
    if (sentToken != null) req.headers['Authorization'] = 'Bearer $sentToken';
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      res = await http.Response.fromStream(streamed);
    } catch (_) {
      throw ApiException("Can't reach the server. Check your connection and try again.");
    }

    if (res.statusCode >= 400) {
      // A 401 on a request that carried our token means the server no longer accepts it (expired, or
      // the server's signing key changed). Only the first rejected request acts: it clears the token,
      // so any other requests still in flight with the same token are ignored.
      if (res.statusCode == 401 && sentToken != null && sentToken == token) {
        onUnauthorized?.call();
        throw ApiException('Your session expired. Please sign in again.');
      }
      var msg = 'Something went wrong (${res.statusCode}). Please try again.';
      try {
        final d = jsonDecode(utf8.decode(res.bodyBytes));
        if (d is Map && d['detail'] is String) msg = d['detail'] as String;
      } catch (_) {}
      throw ApiException(msg);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// Logs in or registers. Returns true if an email code was sent and must be confirmed with
  /// [confirmEmailVerification]; false if a token came back directly (already verified, or dev mode —
  /// no email provider configured on the server yet).
  /// [remember] false keeps the resulting login in memory only (see [_saveToken]).
  Future<bool> login(String email, String password, {bool register = false, bool remember = false}) async {
    final d = await _send('POST', register ? '/auth/register' : '/auth/login',
        body: {'email': email, 'password': password}) as Map;
    if (d['verification_required'] == true) return true;
    await _saveToken(d['token'] as String, persist: remember);
    return false;
  }

  Future<void> confirmEmailVerification(String email, String code, {bool remember = false}) async {
    final d = await _send('POST', '/auth/verify-email', body: {'email': email, 'code': code}) as Map;
    await _saveToken(d['token'] as String, persist: remember);
  }

  /// Asks the server to email a password-reset code. Throws an [ApiException] saying so if no account
  /// uses that email.
  Future<void> requestPasswordReset(String email) async {
    await _send('POST', '/auth/forgot-password', body: {'email': email});
  }

  /// Confirms the emailed code and sets the new password. Doesn't sign the user in: the server ends every
  /// existing login on a reset, so this also drops any token saved on this device, and the caller sends
  /// the user back to sign in with the new password.
  Future<void> resetPassword(String email, String code, String newPassword) async {
    await _send('POST', '/auth/reset-password', body: {'email': email, 'code': code, 'new_password': newPassword});
    await clearToken();
  }

  /// Signs in (or silently registers, on a first-ever Google sign-in) with a Google ID token obtained
  /// via GoogleSignIn. Google has already verified the email, so — unlike [login] — this always
  /// returns a token directly; there's no verification_required step to handle.
  Future<void> loginWithGoogle(String googleIdToken, {bool remember = false}) async {
    final d = await _send('POST', '/auth/google', body: {'id_token': googleIdToken}) as Map;
    await _saveToken(d['token'] as String, persist: remember);
  }

  Future<List<dynamic>> accounts() async => (await _send('GET', '/accounts')) as List<dynamic>;

  /// Starts linking an account. Returns true if an SMS code was sent and must be confirmed with
  /// [confirmLinkAccount]; false if the account was linked immediately (dev mode — no SMS provider
  /// configured on the server yet).
  Future<bool> startLinkAccount(String accountNo, String mobile) async {
    final d = await _send('POST', '/accounts/link/start', body: {'account_no': accountNo, 'mobile': mobile});
    return (d as Map)['otp_required'] as bool;
  }

  Future<void> confirmLinkAccount(String accountNo, String mobile, String code) async {
    await _send('POST', '/accounts/link/confirm',
        body: {'account_no': accountNo, 'mobile': mobile, 'code': code});
  }

  Future<void> unlink(int id) async {
    await _send('DELETE', '/accounts/$id/link');
  }

  Future<Map<String, dynamic>> bill(int id) async =>
      Map<String, dynamic>.from(await _send('GET', '/accounts/$id/bill') as Map);

  Future<List<dynamic>> bills(int id) async => (await _send('GET', '/accounts/$id/bills')) as List<dynamic>;

  Future<List<dynamic>> payments(int id) async =>
      (await _send('GET', '/accounts/$id/payments')) as List<dynamic>;

  Future<List<dynamic>> notifications(int id) async =>
      (await _send('GET', '/accounts/$id/notifications')) as List<dynamic>;

  Future<void> reportIssue(int accountId, String category, String message) async {
    await _send('POST', '/accounts/$accountId/issues', body: {'category': category, 'message': message});
  }

  Future<List<dynamic>> issues(int accountId) async =>
      (await _send('GET', '/accounts/$accountId/issues')) as List<dynamic>;

  Future<List<dynamic>> addons() async => (await _send('GET', '/addons')) as List<dynamic>;

  Future<List<dynamic>> accountAddons(int accountId) async =>
      (await _send('GET', '/accounts/$accountId/addons')) as List<dynamic>;

  Future<void> subscribeAddon(int accountId, int addonId) async {
    await _send('POST', '/accounts/$accountId/addons', body: {'addon_id': addonId});
  }

  Future<void> unsubscribeAddon(int accountId, int addonId) async {
    await _send('DELETE', '/accounts/$accountId/addons/$addonId');
  }

  Future<List<dynamic>> plans() async => (await _send('GET', '/plans')) as List<dynamic>;

  Future<void> upgrade(int id, int planId) async {
    await _send('POST', '/accounts/$id/upgrade', body: {'plan_id': planId});
  }

  /// Starts a payment. Returns payment_id/checkout_url/real directly if no code was needed (dev mode —
  /// no verification channel configured on the server yet); returns null if a code was sent and must
  /// be confirmed with [confirmPayment].
  Future<Map<String, dynamic>?> startPayment(int id, int amount, String channel) async {
    final d = await _send('POST', '/accounts/$id/payments/start', body: {'amount': amount, 'channel': channel}) as Map;
    if (d['otp_required'] == true) return null;
    return Map<String, dynamic>.from(d);
  }

  /// Confirms a payment verification code. Returns payment_id, checkout_url, and real.
  Future<Map<String, dynamic>> confirmPayment(int id, String code) async {
    final d = await _send('POST', '/accounts/$id/payments/confirm', body: {'code': code});
    return Map<String, dynamic>.from(d as Map);
  }

  /// Asks the server to check a real payment's status with PayMongo.
  /// Returns 'paid', 'failed', or 'pending'.
  Future<String> checkPayment(int accountId, int paymentId) async {
    final d = await _send('POST', '/accounts/$accountId/payments/$paymentId/check');
    return d['payment_status'] as String;
  }

  /// Development only: asks the dev API to act as the payment gateway.
  Future<void> devConfirm(int paymentId) async {
    await _send('POST', '/dev/payments/$paymentId/confirm');
  }
}