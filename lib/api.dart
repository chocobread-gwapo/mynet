import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// The Android emulator reaches your PC's localhost at 10.0.2.2.
/// On a real phone, use your PC's address on the same Wi-Fi, e.g. http://192.168.1.20:8000/api/v1
const String baseUrl = 'http://10.0.2.2:8000/api/v1';

const _tokenKey = 'auth_token';
const _storage = FlutterSecureStorage();

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class Api {
  String? token;

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

  Future<void> _saveToken(String value) async {
    token = value;
    await _storage.write(key: _tokenKey, value: value);
  }

  /// Clears both the in-memory token and the saved copy. Safe to call without awaiting.
  Future<void> clearToken() async {
    token = null;
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
  Future<bool> login(String email, String password, {bool register = false}) async {
    final d = await _send('POST', register ? '/auth/register' : '/auth/login',
        body: {'email': email, 'password': password}) as Map;
    if (d['verification_required'] == true) return true;
    await _saveToken(d['token'] as String);
    return false;
  }

  Future<void> confirmEmailVerification(String email, String code) async {
    final d = await _send('POST', '/auth/verify-email', body: {'email': email, 'code': code}) as Map;
    await _saveToken(d['token'] as String);
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