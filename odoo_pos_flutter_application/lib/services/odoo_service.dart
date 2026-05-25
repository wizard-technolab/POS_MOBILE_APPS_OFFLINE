import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../models/sync_model.dart';
import 'app_config.dart';
import 'db_helper.dart';

// Format millisecond timestamp to readable string like "05 May 2026, 10:30 AM"
String _formatTimestamp(dynamic raw) {
  if (raw == null) return 'Never';
  try {
    final ms = raw is int ? raw : int.parse(raw.toString());
    if (ms == 0) return 'Never';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final min = dt.minute.toString().padLeft(2, '0');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${dt.day.toString().padLeft(2, '0')} ${months[dt.month - 1]} ${dt.year}, $hour:$min $ampm';
  } catch (_) {
    return 'Never';
  }
}

class OdooService {
  static String? _token;
  static String? _savedUsername;
  static String? _savedPassword;

  // ─────────────────────────────────────────────────────────────────────────
  // BASE URL
  // ─────────────────────────────────────────────────────────────────────────
  static Future<String> get baseUrl async {
    final url = await AppConfig.getServerUrl();
    if (url.isEmpty) {
      throw Exception(
          'Server URL is not configured. Please set it in Settings.');
    }
    return url;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GET TOKEN — memory → SharedPreferences → auto re-auth
  // Products screen જેવો જ pattern
  // ─────────────────────────────────────────────────────────────────────────
  static Future<String> _getToken() async {
    // 1. Memory માં છે?
    if (_token != null && _token!.isNotEmpty) return _token!;

    // 2. SharedPreferences માં છે?
    final saved = await AppConfig.getApiToken();
    if (saved.isNotEmpty) {
      _token = saved;
      return _token!;
    }

    // 3. Auto re-authenticate
    final email = await AppConfig.getApiEmail();
    final password = await AppConfig.getApiPassword();
    if (email.isEmpty || password.isEmpty) {
      throw Exception('Please go to Settings and tap "Connect to Odoo".');
    }

    final url = await baseUrl;
    final response = await http
        .post(
          Uri.parse('$url/api/v1/auth'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));

    final data = jsonDecode(response.body);
    if (data['status'] == 'success' && data['token'] != null) {
      _token = data['token'] as String;
      await AppConfig.saveApiToken(_token!);
      return _token!;
    }

    throw Exception('Authentication failed. Check credentials in Settings.');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LOGIN (backward compatible)
  // ─────────────────────────────────────────────────────────────────────────
// Replace ONLY this login() method inside lib/services/odoo_service.dart

  static Future<bool> login({
    required String username,
    required String password,
  }) async {
    try {
      final url = await baseUrl;

      // JWT LOGIN API
      final response = await http
          .post(
            Uri.parse('$url/api/v1/auth'),
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'email': username,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return false;
      }

      final data = jsonDecode(response.body);

      /*
      Expected backend response:

      {
        "status": "success",
        "token": "JWT_TOKEN_HERE",
        "user_id": 7
      }
    */

      if (data['status'] == 'success' && data['token'] != null) {
        final String token = data['token'] ?? '';
        final int uid = data['user_id'] ?? 0;

        // SAVE TOKEN IN MEMORY
        _token = token;

        // SAVE TOKEN FOR OTHER SCREENS + OFFLINE USE
        await AppConfig.saveApiToken(token);

        // SAVE USER ID
        await AppConfig.saveUid(uid);

        // SAVE LOGIN CREDENTIALS FOR AUTO RE-AUTH
        await AppConfig.saveApiEmail(username);
        await AppConfig.saveApiPassword(password);

        // SAVE FOR SESSION RECOVERY
        _savedUsername = username;
        _savedPassword = password;

        // Fetch and cache user profile details (like real email) immediately after login
        await getCurrentUser();

        return true;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  // ─────────────────────────────────────────
  // SET SESSION INFO (for offline login)
  // ─────────────────────────────────────────
  static void setSessionInfo({
    required String username,
    required String password,
  }) {
    _savedUsername = username;
    _savedPassword = password;
  }

  // ─────────────────────────────────────────
  // AUTO RE-LOGIN (session expire fix)
  // ─────────────────────────────────────────
  static Future<bool> ensureSession() async {
    if (_token != null) return true;
    if (_savedUsername == null || _savedPassword == null) {
      return false;
    }
    return await login(
      username: _savedUsername!,
      password: _savedPassword!,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FETCH ORDERS — GET /api/orders (JWT Bearer token)
  // ─────────────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchOrderLines(int orderId,
      {int? sessionId}) async {
    final url = await baseUrl;
    String token = await _getToken();

    // Only append session_id if valid to avoid URL string "null"
    final sessionParam =
        (sessionId != null && sessionId > 0) ? '?session_id=$sessionId' : '';

    var response = await http.get(
      Uri.parse('$url/api/order/$orderId/lines$sessionParam'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));

    // Token expired — re-auth once and retry
    if (response.statusCode == 401) {
      _token = null;
      await AppConfig.saveApiToken('');
      token = await _getToken();

      response = await http.get(
        Uri.parse('$url/api/order/$orderId/lines$sessionParam'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
    }

    // Safety check — if response is HTML (not JSON), throw a clear error
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      throw Exception(
          'Server returned an unexpected response (HTTP ${response.statusCode}). '
          'Make sure the Odoo module is updated and restarted.');
    }

    final data = jsonDecode(response.body);

    if (data['status'] != 'success') {
      final msg = data['message'] ?? 'Failed to fetch order lines.';
      throw Exception(msg);
    }

    final raw = data['data'];
    if (raw == null) return [];
    if (raw is List) return List<Map<String, dynamic>>.from(raw);
    return [];
  }

  // ─────────────────────────────────────────────────────────────────────────────
// FETCH ORDERS — GET /api/orders (JWT Bearer token)
// ─────────────────────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> fetchOrders({
    String filter = 'all',
    int limit = 100,
    int? sessionId, // Add this parameter
  }) async {
    final url = await baseUrl;
    String token = await _getToken();

    // ── Session isolation check ──
    // To prevent mixing orders from different POS sessions (e.g., Restaurant vs
    // Clothes Shop), we must never fetch orders without a session ID filter.
    // sessionId is now passed from the caller (OrdersScreen)
    if (sessionId == null || sessionId <= 0) {
      debugPrint(
          '⚠️ fetchOrders called with no active session. Returning empty list to prevent data mixing.');
      return [];
    }

    String filterParam = '';
    if (filter == 'synced') filterParam = '&filter=synced';
    if (filter == 'pending') filterParam = '&filter=pending';
    if (filter == 'cancelled') filterParam = '&filter=cancelled';

    // Add session_id to URL so only that session's orders are returned
    final sessionParam = sessionId > 0 ? '&session_id=$sessionId' : '';
    final fieldsParam = '&fields=company_id'; // Explicitly request company_id

    var response = await http.get(
      Uri.parse(
          '$url/api/orders?limit=$limit$filterParam$sessionParam$fieldsParam'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));

    // 401 → token expire → re-auth once and retry
    if (response.statusCode == 401) {
      _token = null;
      await AppConfig.saveApiToken('');
      token = await _getToken();

      response = await http.get(
        Uri.parse(
            '$url/api/orders?limit=$limit$filterParam$sessionParam$fieldsParam'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
    }

    final data = jsonDecode(response.body);

    if (data['status'] != 'success') {
      final msg = data['message'] ?? 'Unexpected response from server.';
      throw Exception(msg);
    }

    final raw = data['data'];
    if (raw == null) return [];
    if (raw is List) {
      return List<Map<String, dynamic>>.from(raw);
    }
    return [];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FETCH PENDING ORDERS — GET /api/orders/pending
  //
  // PURPOSE:
  //   Fetches draft (pending/hold) orders from Odoo server for the selected
  //   session and saves them to local SQLite DB.
  //
  //   Called every time _loadOrders() runs (online mode).
  //   This ensures that when the app goes offline, pending orders placed
  //   from Odoo backend or another device are already in local DB and
  //   visible on the orders screen without any network connection.
  //
  // FLOW:
  //   Online → fetch pending orders → save to local DB
  //   Offline → local DB already has them → show on screen
  // ─────────────────────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> fetchPendingOrders(
      {int? sessionId}) async {
    final url = await baseUrl;
    String token = await _getToken();

    if (sessionId == null || sessionId <= 0) {
      debugPrint('⚠️ fetchPendingOrders: no active session, skipping.');
      return [];
    }

    try {
      var response = await http.get(
        Uri.parse('$url/api/orders/pending?session_id=$sessionId&limit=100'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      // Token expired → re-auth once and retry
      if (response.statusCode == 401) {
        _token = null;
        await AppConfig.saveApiToken('');
        token = await _getToken();
        response = await http.get(
          Uri.parse('$url/api/orders/pending?session_id=$sessionId&limit=100'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 15));
      }

      final data = jsonDecode(response.body);

      if (data['status'] != 'success') {
        debugPrint('⚠️ fetchPendingOrders: ${data['message']}');
        return [];
      }

      final raw = data['data'];
      if (raw == null || raw is! List) return [];
      return List<Map<String, dynamic>>.from(raw);
    } catch (e) {
      // Non-fatal: if server is unreachable, local DB already has cached orders
      debugPrint('⚠️ fetchPendingOrders failed (non-fatal): $e');
      return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONNECTION CHECK
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> checkConnection() async {
    try {
      final url = await baseUrl;
      final response = await http
          .get(Uri.parse('$url/web/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GET CURRENT USER
  // ─────────────────────────────────────────────────────────────────────────
  static Future<UserModel?> getCurrentUser() async {
    try {
      await ensureSession();
      final url = await baseUrl;
      final uid = await AppConfig.getUid();

      if (uid == 0) return null;

      final response = await http.post(
        Uri.parse('$url/web/dataset/call_kw'),
        headers: {
          'Content-Type': 'application/json',
          if (_token != null) 'Cookie': _token!,
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': 'call',
          'params': {
            'model': 'res.users',
            'method': 'read',
            'args': [
              [uid]
            ],
            'kwargs': {
              'fields': ['id', 'name', 'login', 'email', 'groups_id'],
              'context': {'lang': 'en_US'},
            },
          },
        }),
      );

      final data = jsonDecode(response.body);

      if (data['result'] != null && data['result'].isNotEmpty) {
        final userData = data['result'][0];

        // Save real email to AppConfig for subscription validation
        if (userData['email'] != null && userData['email'] is String) {
          await AppConfig.saveUserProfileEmail(userData['email']);
        }

        return UserModel.fromJson(userData);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

// ─────────────────────────────────────────────────────────────────────────
// GET SYNC STATUS (LOCAL SQLITE BASED)
// ─────────────────────────────────────────────────────────────────────────
  static Future<SyncModel?> getSyncStatus() async {
    try {
      final db = await DatabaseHelper().database;

      // Filter by selected session — works correctly because _onSessionSelected()
      // in settings_screen.dart updates all orders with session_id = 0 when
      // the user picks a session for the first time.
      final sessionId = await AppConfig.getPosSessionId();
      final sessionFilter = sessionId > 0 ? ' AND session_id = $sessionId' : '';

      final syncedResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM orders WHERE synced = 1$sessionFilter',
      );

      final pendingResult = await db.rawQuery(
        "SELECT COUNT(*) as count FROM orders WHERE synced = 0 AND status != 'failed'$sessionFilter",
      );

      final failedResult = await db.rawQuery(
        "SELECT COUNT(*) as count FROM orders WHERE status = 'failed'$sessionFilter",
      );

      // Get last sync time from the most recently updated synced order in this session
      final lastSyncResult = await db.rawQuery(
        '''
        SELECT updated_at
        FROM orders
        WHERE synced = 1$sessionFilter
        ORDER BY updated_at DESC
        LIMIT 1
        ''',
      );

      final int synced = (syncedResult.first['count'] as int?) ?? 0;
      final int pending = (pendingResult.first['count'] as int?) ?? 0;
      final int failed = (failedResult.first['count'] as int?) ?? 0;

      String lastSynced = 'Never';

      if (lastSyncResult.isNotEmpty &&
          lastSyncResult.first['updated_at'] != null) {
        // Format timestamp to readable date/time
        lastSynced = _formatTimestamp(lastSyncResult.first['updated_at']);
      }

      return SyncModel(
        synced: synced,
        pending: pending,
        failed: failed,
        lastSynced: lastSynced,
      );
    } catch (e) {
      return SyncModel(
        synced: 0,
        pending: 0,
        failed: 0,
        lastSynced: 'Never',
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SYNC LOCAL DRAFT TO ODOO — POST /api/order/draft
  //
  // Called when a local (isLocal=true) pending order needs to be paid.
  // Local orders only exist in SQLite — Odoo does not know about them yet.
  // We first create the order as a draft in Odoo, then use the returned
  // Odoo order ID to call /api/order/<id>/pay.
  //
  // Parameters:
  //   externalId   — the local external_id stored in SQLite (e.g. "APP-UUID")
  //   sessionId    — POS session ID saved with the local order
  //   deviceCode   — device code from Settings
  //   customerId   — optional partner ID
  //   customerNote — optional order-level customer note
  //   lines        — list of order lines from local SQLite order_lines table
  //   totalAmount  — cart total (used for amount calculation)
  //
  // Returns: the Odoo order ID (int) so the caller can use it in /pay.
  // Throws Exception on failure.
  // ─────────────────────────────────────────────────────────────────────────
  static Future<int> syncLocalDraftToOdoo({
    required String externalId,
    required int sessionId,
    required String deviceCode,
    int? customerId,
    String customerNote = '',
    required List<Map<String, dynamic>> lines,
    required double totalAmount,
    // ── FIX: Accept optional Odoo order ID ──────────────────────────────────
    // When the user restores a pending order to cart and logs out, Flutter
    // passes the original Odoo order id here. The backend uses this to find
    // the existing draft by DB id (Search B) and updates it instead of
    // creating a duplicate — even if externalId is different.
    // For fresh carts (no restored order), this is null and has no effect.
    int? odooOrderId,
  }) async {
    final url = await baseUrl;
    String token = await _getToken();

    // Build lines payload from local SQLite order_lines rows.
    // SQLite saves 'quantity' key; API expects 'qty'.
    final linesPayload = lines.map((line) {
      final qty = (line['quantity'] as num?)?.toInt() ??
          (line['qty'] as num?)?.toInt() ??
          1;
      return {
        'product_id': line['product_id'] as int,
        'qty': qty,
        'price': (line['price'] as num?)?.toDouble() ??
            (line['price_unit'] as num?)?.toDouble() ??
            0.0,
        'tax_rate': (line['tax_rate'] as num?)?.toDouble() ?? 0.0,
        'note': line['note'] as String? ?? '',
        'customer_note': line['customer_note'] as String? ?? '',
      };
    }).toList();

    final payload = {
      'external_id': externalId,
      'session_id': sessionId,
      'device_code': deviceCode,
      if (customerId != null && customerId > 0) 'customer_id': customerId,
      'customer_note': customerNote,
      'lines': linesPayload,
      // Pass Odoo order id when saving a restored pending order as draft.
      // The backend uses this as a fallback (Search B) to find the original
      // draft by DB id and update it — preventing a duplicate from being
      // created when the Flutter-side externalId has changed after restore.
      if (odooOrderId != null && odooOrderId > 0) 'odoo_order_id': odooOrderId,
    };

    var response = await http
        .post(
          Uri.parse('$url/api/order/draft'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    // Token expired — re-auth once and retry
    if (response.statusCode == 401) {
      _token = null;
      await AppConfig.saveApiToken('');
      token = await _getToken();
      response = await http
          .post(
            Uri.parse('$url/api/order/draft'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      throw Exception(
          'Server returned an unexpected response (HTTP ${response.statusCode}). '
          'Make sure the Odoo module is updated and restarted.');
    }

    final data = jsonDecode(response.body);

    if (data['status'] == 'success') {
      // Return the real Odoo order ID so caller can use it in /pay
      final odooOrderId = data['data']?['order_id'] as int?;
      if (odooOrderId == null) {
        throw Exception('Odoo did not return an order_id. Try again.');
      }
      return odooOrderId;
    }

    throw Exception(data['message'] ?? 'Failed to sync draft order to Odoo.');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PAY DRAFT ORDER — POST /api/order/<order_id>/pay
  //
  // Called when user taps "Proceed to Payment" on a PENDING (draft) order
  // in Order History. This completes payment for an existing draft order.
  //
  // Parameters:
  //   orderId    — Odoo order ID (from the pending order row)
  //   method     — Payment method name: 'Cash' or 'Bank'
  //   amount     — Total amount to pay
  //   deviceCode — Device code from Settings (required by API)
  //
  // Returns: true if payment succeeded, throws Exception on failure.
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> payDraftOrder({
    required int orderId,
    required String method,
    required double amount,
    required String deviceCode,
  }) async {
    final url = await baseUrl;
    String token = await _getToken();

    final payload = {
      'device_code': deviceCode,
      'payments': [
        {'method': method, 'amount': amount},
      ],
    };

    var response = await http
        .post(
          Uri.parse('$url/api/order/$orderId/pay'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    // Token expired — re-auth once and retry
    if (response.statusCode == 401) {
      _token = null;
      await AppConfig.saveApiToken('');
      token = await _getToken();

      response = await http
          .post(
            Uri.parse('$url/api/order/$orderId/pay'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
    }

    // Safety check — ensure we got JSON back (not an HTML error page)
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      throw Exception(
          'Server returned an unexpected response (HTTP \${response.statusCode}). '
          'Make sure the Odoo module is updated and restarted.');
    }

    final data = jsonDecode(response.body);

    if (data['status'] == 'success') {
      return true;
    }

    // Throw server error message so the UI can display it
    throw Exception(data['message'] ?? 'Payment failed. Please try again.');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SYNC NOW
  // ─────────────────────────────────────────────────────────────────────────
  static Future<bool> syncNow() async {
    try {
      final sessionId = await AppConfig.getPosSessionId();
      final orders = await fetchOrders(limit: 1000, sessionId: sessionId);
      return orders.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LOGOUT
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> logout() async {
    try {
      final url = await baseUrl;

      await http.post(
        Uri.parse('$url/web/session/destroy'),
        headers: {
          'Content-Type': 'application/json',
          if (_token != null) 'Cookie': _token!,
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': 'call',
          'params': {},
        }),
      );
    } catch (_) {}

    _token = null;
    _savedUsername = null;
    _savedPassword = null;
    await AppConfig.clear();
  }
}
