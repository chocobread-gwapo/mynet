import 'dart:convert';

import 'package:http/http.dart' as http;

/// The Android emulator reaches your PC's localhost at 10.0.2.2.
/// On a real phone, use your PC's address on the same Wi-Fi, e.g. http://192.168.1.20:8000/api/v1
const String baseUrl = 'http://10.0.2.2:8000/api/v1';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class Api {
  String? token;

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    req.headers['Content-Type'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      res = await http.Response.fromStream(streamed);
    } catch (_) {
      throw ApiException("Can't reach the server. Check your connection and try again.");
    }

    if (res.statusCode >= 400) {
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

  Future<void> login(String email, String password, {bool register = false}) async {
    final d = await _send('POST', register ? '/auth/register' : '/auth/login',
        body: {'email': email, 'password': password});
    token = d['token'] as String;
  }

  Future<List<dynamic>> accounts() async => (await _send('GET', '/accounts')) as List<dynamic>;

  Future<void> linkAccount(String accountNo, String mobile) async {
    await _send('POST', '/accounts/link', body: {'account_no': accountNo, 'mobile': mobile});
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

  Future<List<dynamic>> plans() async => (await _send('GET', '/plans')) as List<dynamic>;

  Future<void> upgrade(int id, int planId) async {
    await _send('POST', '/accounts/$id/upgrade', body: {'plan_id': planId});
  }

  Future<int> startPayment(int id, int amount) async {
    final d = await _send('POST', '/accounts/$id/payments', body: {'amount': amount});
    return d['payment_id'] as int;
  }

  /// Development only: asks the dev API to act as the payment gateway.
  Future<void> devConfirm(int paymentId) async {
    await _send('POST', '/dev/payments/$paymentId/confirm');
  }
}
