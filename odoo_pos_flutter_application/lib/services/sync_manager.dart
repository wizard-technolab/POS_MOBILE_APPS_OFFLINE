// lib/services/sync_manager.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/utils/utils.dart' as sqflite show firstIntValue;
import 'app_config.dart';
import 'odoo_service.dart';
import '../data/repositories/order_repository.dart';
import 'subscription_service.dart';
import 'db_helper.dart';
import 'delta_sync_manager.dart';

class SyncManager extends ChangeNotifier {
  // Singleton pattern to ensure the _syncLock and state are shared
  static final SyncManager _instance = SyncManager._internal();
  factory SyncManager() => _instance;
  SyncManager._internal() {
    // Initialize any state here if needed
  }

  // ── Repositories ──────────────────────────────────────
  final OrderRepository _orderRepo = OrderRepository();

  // ── Public observable state ───────────────────────────
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  bool _isConnected = false;
  bool get isOnline => _isConnected;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  int _syncedCount = 0;
  int get syncedCount => _syncedCount;

  int _failedCount = 0;
  int get failedCount => _failedCount;

  int _pendingCount = 0;
  int get pendingCount => _pendingCount;

  String _lastError = '';
  String get lastError => _lastError;

  // ── Internal lock to prevent overlapping syncs ────────
  Completer<void>? _syncLock;

  // ── Periodic background sync timer ────────────────────
  Timer? _backgroundTimer;

  // ─────────────────────────────────────────────────────
  // CONNECTIVITY CHECK
  // ─────────────────────────────────────────────────────

  Future<bool> isConnected() async {
    try {
      final baseUrl = await AppConfig.getServerUrl();

      if (baseUrl.isEmpty) {
        _setConnected(false);
        return false;
      }

      final response = await http
          .get(
            Uri.parse('$baseUrl/web/health'),
          )
          .timeout(const Duration(seconds: 5));

      final ok = response.statusCode == 200;
      _setConnected(ok);
      return ok;
    } catch (_) {
      _setConnected(false);
      return false;
    }
  }

  void _setConnected(bool value) {
    if (_isConnected != value) {
      _isConnected = value;
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────
  // AUTO LOGIN / TOKEN RESTORE
  // ─────────────────────────────────────────────

  Future<bool> _ensureValidSession() async {
    final email = await AppConfig.getApiEmail();
    final password = await AppConfig.getApiPassword();
    final token = await AppConfig.getApiToken();
    final baseUrl = await AppConfig.getServerUrl();

    if (baseUrl.isEmpty) {
      debugPrint('⚠️ Missing server URL');
      return false;
    }

    if (email.isEmpty || password.isEmpty) {
      debugPrint('⚠️ Missing saved email/password');
      return false;
    }

    // Token already exists and has not expired → continue.
    if (token.isNotEmpty && !AppConfig.isJwtExpired(token)) {
      return true;
    }

    await AppConfig.clearApiToken();
    debugPrint('🔁 Token missing/expired → attempting auto re-login...');

    try {
      final success = await OdooService.login(
        username: email,
        password: password,
      );

      if (!success) {
        debugPrint('❌ Auto re-login failed');
        return false;
      }

      final newToken = await AppConfig.getApiToken();

      if (newToken.isEmpty) {
        debugPrint('❌ Login succeeded but token still missing');
        return false;
      }

      debugPrint('✅ Auto re-login successful');
      return true;
    } catch (e) {
      debugPrint('❌ Auto re-login exception: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // BACKGROUND SYNC
  // ─────────────────────────────────────────────

  void startBackgroundSync({
    Duration interval = const Duration(minutes: 5),
  }) {
    stopBackgroundSync();

    _backgroundTimer = Timer.periodic(
      interval,
      (_) => syncAll(),
    );
  }

  void stopBackgroundSync() {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
  }

  // ─────────────────────────────────────────────
  // FULL SYNC
  // ─────────────────────────────────────────────

  Future<void> syncAll() async {
    if (_syncLock != null) {
      await _syncLock!.future;
      return;
    }

    _syncLock = Completer<void>();
    _isSyncing = true;
    _lastError = '';
    notifyListeners();

    try {
      // 1. Check internet/server
      final online = await isConnected();
      if (!online) {
        _lastError = 'Server unreachable';
        debugPrint('⚠️ Server unreachable');
        return;
      }

      // 2. Ensure valid JWT token
      final sessionOk = await _ensureValidSession();

      if (!sessionOk) {
        _lastError = 'Missing credentials or token refresh failed';
        debugPrint('⚠️ Session validation failed');
        return;
      }

      // 2.5 Subscription delta sync (verify license validity, only update if changed)
      await _logSync(
          entityType: 'subscription',
          entityId: 0,
          action: 'sync',
          status: 'started');
      await _syncSubscriptionDown();

      // Check validity immediately after sync; if invalid, stop the full sync process.
      if (!(await AppConfig.isSubscriptionValid())) {
        _lastError = 'Subscription invalid or expired';
        return;
      }

      await _logSync(
          entityType: 'subscription',
          entityId: 0,
          action: 'sync',
          status: 'success');

      // 3. Product delta sync (only fetch new/changed, delete removed)
      final sessionId = await AppConfig.getPosSessionId();
      await _logSync(
          entityType: 'product',
          entityId: sessionId,
          action: 'download',
          status: 'started');
      await _syncProductsDown();
      await _logSync(
          entityType: 'product',
          entityId: sessionId,
          action: 'download',
          status: 'success');

      // 3.5 Auth data delta sync (only update if changed)
      final deltaSyncMgr = DeltaSyncManager();
      await deltaSyncMgr.deltaSyncAuthData();
      await _logSync(
          entityType: 'auth', entityId: 0, action: 'sync', status: 'success');

      // customer sync
      await _logSync(
          entityType: 'customer',
          entityId: 0,
          action: 'upload',
          status: 'started');
      await _syncCustomersUp();
      await _logSync(
          entityType: 'customer',
          entityId: 0,
          action: 'upload',
          status: 'success');

      // 4. Order delta sync (upload unsent, download new with server priority)
      await _logSync(
          entityType: 'order',
          entityId: sessionId,
          action: 'sync',
          status: 'started');
      await _syncOrdersUp();
      await _logSync(
          entityType: 'order',
          entityId: sessionId,
          action: 'sync',
          status: 'success');

      // 5. Refresh counters
      await _refreshCounters();

      _lastSyncTime = DateTime.now();
      debugPrint('✅ Full delta sync completed');
    } catch (e) {
      _lastError = e.toString();
      debugPrint('❌ SyncManager.syncAll error: $e');
    } finally {
      _isSyncing = false;
      _syncLock?.complete();
      _syncLock = null;
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────
  // SUBSCRIPTION DOWN (DELTA SYNC)
  // ─────────────────────────────────────────────
  Future<void> _syncSubscriptionDown() async {
    try {
      final code = await AppConfig.getSubscriptionCode();
      if (code.isEmpty) return;

      final result = await SubscriptionService.validateLicenseCode(code);
      if (result['status'] == 'success') {
        final newExpDate = result['exp_date'] as String?;
        final currentExpDate = await AppConfig.getSubscriptionExpDate();

        // Only update if expiry date changed (delta check)
        if (newExpDate != null && newExpDate != currentExpDate) {
          await AppConfig.saveSubscriptionExpDate(newExpDate);
          debugPrint(
              '✅ Subscription updated during delta sync: valid until $newExpDate');
        } else if (currentExpDate.isNotEmpty) {
          debugPrint('ℹ️ Subscription unchanged: valid until $currentExpDate');
        }
      } else {
        // Only clear if server says it's invalid/expired, ignore network timeouts
        final msg = (result['message'] ?? '').toString().toLowerCase();
        final isNetwork = msg.contains('connection') || msg.contains('timeout');
        if (!isNetwork) {
          debugPrint(
              '🚨 Subscription invalidated by server during delta sync. Clearing local data.');
          await AppConfig.clearSubscription();
        }
      }

      // Update the global notifier so the UI (MainShell) can react immediately
      AppConfig.subscriptionValidNotifier.value =
          await AppConfig.isSubscriptionValid();
    } catch (e) {
      debugPrint('⚠️ Subscription delta sync error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // PRODUCTS DOWN (DELTA SYNC)
  // ─────────────────────────────────────────────

  Future<void> _syncProductsDown() async {
    try {
      final sessionId = await AppConfig.getPosSessionId();
      final deltaSyncMgr = DeltaSyncManager();

      // Use smart delta sync instead of fetching all products
      await deltaSyncMgr.deltaSyncProducts(sessionId: sessionId);

      debugPrint('✅ Delta product sync completed');
    } catch (e) {
      debugPrint('⚠️ Product delta sync error: $e');
    }
  }

// ─────────────────────────────────────────────
// CUSTOMERS UP (sync offline changes to server)
// ─────────────────────────────────────────────
  Future<void> _syncCustomersUp() async {
    try {
      await DeltaSyncManager().deltaSyncCustomers();
    } catch (e) {
      debugPrint('❌ Customer upload error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // ORDERS (DELTA SYNC)
  // ─────────────────────────────────────────────

  Future<void> _syncOrdersUp() async {
    try {
      final sessionId = await AppConfig.getPosSessionId();
      final deltaSyncMgr = DeltaSyncManager();

      // Use smart delta sync: upload unsent, download new from server
      // Server is source of truth for conflicts
      await deltaSyncMgr.deltaSyncOrders(sessionId: sessionId);

      debugPrint('✅ Delta order sync completed');
    } catch (e) {
      debugPrint('❌ Delta order sync error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // SINGLE ORDER SYNC
  // ─────────────────────────────────────────────
  Future<bool> syncSingleOrder(int orderId) async {
    try {
      final online = await isConnected();
      if (!online) return false;

      final sessionOk = await _ensureValidSession();
      if (!sessionOk) return false;

      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        return false;
      }

      final db = await DatabaseHelper().database;

      final orders = await db.query(
        'orders',
        where: 'id = ?',
        whereArgs: [orderId],
        limit: 1,
      );

      if (orders.isEmpty) return false;
      final order = orders.first;

      final orderLines = await _orderRepo.getOrderLines(orderId);
      if (orderLines.isEmpty) return false;
      final orderSessionId = order['session_id'] as int? ?? 0;
      final payload = {
        'external_id': order['external_id'],
        'device_code': order['device_code'],
        'customer_id': (order['customer_id'] as int?) != null &&
                (order['customer_id'] as int) > 0
            ? order['customer_id']
            : null,
        'pos_config_id': order['pos_config_id'],
        if (orderSessionId > 0) 'session_id': orderSessionId,
        'lines': orderLines
            .map(
              (line) => {
                'product_id': line['product_id'],
                'qty': line['quantity'], // Odoo API expects 'qty'
                'price': line['price'],
                'tax_rate': line['tax_rate'] ?? 18.0,
                'note': line['note'] ?? '',
                'customer_note': line['customer_note'] ?? '',
              },
            )
            .toList(),
        'payments': [
          {
            // Use actual saved payment method — not hardcoded Cash
            'method': order['payment_method'] ?? 'Cash',
            'amount': order['total'],
          }
        ],
      };

      final response = await http
          .post(
            Uri.parse('$baseUrl/api/order'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final pMethod = order['payment_method'] as String? ?? 'Cash';
        await _orderRepo.markOrderAsSynced(orderId, paymentMethod: pMethod);
        await _orderRepo.updateOrderStatus(
          orderId,
          'done',
        );

        debugPrint('✅ Single order $orderId synced');
        return true;
      }

      await _orderRepo.incrementSyncAttempts(orderId);

      debugPrint(
        '⚠️ Single order sync HTTP ${response.statusCode}',
      );
      return false;
    } catch (e) {
      debugPrint('❌ Single order sync error: $e');
      await _orderRepo.incrementSyncAttempts(orderId);
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // MANUAL BUTTON
  // ─────────────────────────────────────────────
  Future<bool> syncNow() async {
    try {
      await syncAll();
      return _lastError.isEmpty;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // COUNTERS
  // ─────────────────────────────────────────────

  Future<void> _refreshCounters() async {
    try {
      final db = await DatabaseHelper().database;
      final sessionId = await AppConfig.getPosSessionId();

      final sessionFilter = sessionId > 0 ? ' AND session_id = $sessionId' : '';

      final synced = sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM orders WHERE synced = 1$sessionFilter',
            ),
          ) ??
          0;

      final pending = sqflite.firstIntValue(
            await db.rawQuery(
              "SELECT COUNT(*) FROM orders WHERE synced = 0 AND status != 'failed'$sessionFilter",
            ),
          ) ??
          0;

      final failed = sqflite.firstIntValue(
            await db.rawQuery(
              "SELECT COUNT(*) FROM orders WHERE status = 'failed'$sessionFilter",
            ),
          ) ??
          0;

      _syncedCount = synced;
      _pendingCount = pending;
      _failedCount = failed;
    } catch (e) {
      debugPrint('⚠️ Counter refresh error: $e');
    }
  }

  // ─────────────────────────────────────────────
  // LOGGING
  // ─────────────────────────────────────────────

  Future<void> _logSync({
    required String entityType,
    required int entityId,
    required String action,
    required String status,
    String? error,
  }) async {
    try {
      final db = await DatabaseHelper().database;
      await db.insert(
        'sync_log',
        {
          'entity_type': entityType,
          'entity_id': entityId,
          'action': action,
          'status': status,
          'error': error,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  // DISPOSE
  // ─────────────────────────────────────────────

  @override
  void dispose() {
    stopBackgroundSync();
    super.dispose();
  }
}
