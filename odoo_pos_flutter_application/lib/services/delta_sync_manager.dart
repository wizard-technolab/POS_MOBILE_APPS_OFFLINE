// lib/services/delta_sync_manager.dart
// Smart Delta/Incremental Sync Manager
// Only syncs data that has changed, reducing bandwidth and battery usage

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import 'app_config.dart';
import 'db_helper.dart';
import 'odoo_service.dart';
import 'api_client.dart';
import '../data/repositories/product_repository.dart';
import '../data/repositories/order_repository.dart';
import '../data/repositories/customer_repository.dart';

class DeltaSyncManager {
  static final DeltaSyncManager _instance = DeltaSyncManager._internal();
  factory DeltaSyncManager() => _instance;
  DeltaSyncManager._internal();

  final ProductRepository _productRepo = ProductRepository();
  final OrderRepository _orderRepo = OrderRepository();
  final CustomerRepository _customerRepo = CustomerRepository();

  // Upload throttling: prevents one sync cycle from hammering the backend
  // when many offline records are pending. Remaining records stay queued for
  // the next automatic/manual sync cycle.
  static const int _orderUploadBatchLimit = 20;
  static const int _customerUploadBatchLimit = 30;
  static const Duration _uploadThrottleDelay = Duration(milliseconds: 400);

  // Guard to prevent multiple concurrent sync operations
  bool _isSyncing = false;

  // ─────────────────────────────────────────────
  // PRODUCT DELTA SYNC
  // ─────────────────────────────────────────────

  /// Smart product sync: Only fetch new/changed, delete removed products
  Future<void> deltaSyncProducts({int sessionId = 0}) async {
    if (_isSyncing) {
      debugPrint('⏳ Delta product sync already in progress, skipping');
      return;
    }

    try {
      _isSyncing = true;
      bool hasChanges = false;

      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping delta product sync');
        return;
      }

      // Step 1: Get all product IDs from server
      final serverProductIds = await _getServerProductIds(baseUrl, token);
      if (serverProductIds.isEmpty) {
        debugPrint('ℹ️ No products on server');
        return;
      }

      // Step 2: Get all local product IDs
      final localProductIds = await _getLocalProductIds(sessionId);

      // Step 3: Find differences
      final newProductIds = serverProductIds
          .where((id) => !localProductIds.contains(id))
          .toList();
      final changedProductIds = serverProductIds.where((id) {
        // Products that might have changed (we'll check on fetch)
        return localProductIds.contains(id);
      }).toList();
      final deletedProductIds = localProductIds
          .where((id) => !serverProductIds.contains(id))
          .toList();

      debugPrint(
          '📊 Product Delta: New=${newProductIds.length}, Changed=${changedProductIds.length}, Deleted=${deletedProductIds.length}');

      // Step 4: Fetch only new and changed products
      if (newProductIds.isNotEmpty || changedProductIds.isNotEmpty) {
        final idsToFetch = [...newProductIds, ...changedProductIds];
        final products =
            await _fetchProductsByIds(baseUrl, token, idsToFetch, sessionId);

        if (products.isNotEmpty) {
          final count = await _productRepo.incrementalUpdateProducts(
            products,
            sessionId: sessionId,
          );
          if (count > 0) hasChanges = true;
          debugPrint('✅ Delta synced ${products.length} product updates');
        }
      }

      // Step 5: Delete products not on server anymore
      if (deletedProductIds.isNotEmpty) {
        for (final productId in deletedProductIds) {
          await _productRepo.deleteProduct(productId);
        }
        hasChanges = true;
        debugPrint(
            '🗑️ Deleted ${deletedProductIds.length} products not on server');
      }

      if (hasChanges) {
        productsChangedNotifier.value++;
      }
    } catch (e) {
      debugPrint('❌ Delta product sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// Get all product IDs from local database
  Future<List<int>> _getLocalProductIds(int sessionId) async {
    try {
      final db = await DatabaseHelper().database;

      List<Map<String, dynamic>> result;
      if (sessionId > 0) {
        result = await db.rawQuery('''
          SELECT p.id FROM products p
          INNER JOIN session_products sp ON p.id = sp.product_id
          WHERE sp.session_id = ?
        ''', [sessionId]);
      } else {
        result = await db.query('products', columns: ['id']);
      }

      return result.map((row) => row['id'] as int).toList();
    } catch (e) {
      debugPrint('❌ Error getting local product IDs: $e');
      return [];
    }
  }

  /// Get all product IDs from server (quick ID list)
  Future<List<int>> _getServerProductIds(String baseUrl, String token) async {
    try {
      final sessionId = await AppConfig.getPosSessionId();
      final queryString = sessionId > 0
          ? '?include_combos=true&session_id=$sessionId'
          : '?include_combos=true';

      final response = await ApiClient.get(
        '/api/products/ids$queryString',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final List<dynamic> ids = body is List
            ? body
            : (body['data'] ?? body['ids'] ?? body['products'] ?? []);
        return ids
            .map((id) {
              if (id is int) return id;
              if (id is String) return int.tryParse(id) ?? 0;
              return 0;
            })
            .where((id) => id > 0)
            .toList();
      }

      debugPrint(
          '⚠️ Failed to get product IDs from server: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('❌ Error getting server product IDs: $e');
      return [];
    }
  }

  /// Fetch products by specific IDs from server
  Future<List<Map<String, dynamic>>> _fetchProductsByIds(
      String baseUrl, String token, List<int> productIds, int sessionId) async {
    try {
      if (productIds.isEmpty) return [];

      // Batch fetch (send IDs as comma-separated list or JSON)
      final idsParam = productIds.join(',');
      final sessionParam = sessionId > 0 ? '&session_id=$sessionId' : '';

      final response = await ApiClient.get(
        '/api/products/by-ids?ids=$idsParam$sessionParam',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 30),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final List<dynamic> items =
            body is List ? body : (body['data'] ?? body['products'] ?? []);

        return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }

      debugPrint('⚠️ Failed to fetch products by IDs: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('❌ Error fetching products by IDs: $e');
      return [];
    }
  }

  // ─────────────────────────────────────────────
  // ORDER DELTA SYNC
  // ─────────────────────────────────────────────

  /// Smart order sync: upload local unsent, download new from server
  /// Server is source of truth for conflicts
  Future<void> deltaSyncOrders({int sessionId = 0}) async {
    if (_isSyncing) {
      debugPrint(
          '⏳ Delta sync already in progress, skipping duplicate request');
      return;
    }

    try {
      _isSyncing = true;
      debugPrint('🔄 Starting delta order sync sequence...');

      int retryCount = 0;
      const maxRetries = 3;
      bool success = false;

      while (retryCount <= maxRetries && !success) {
        try {
          // Quick check: If server isn't reachable, don't enter the upload loops
          // to avoid wasting time on timeouts.
          final isHealthy = await OdooService.checkConnection();
          if (!isHealthy) throw Exception('Odoo server is unreachable');

          // Step 1: Upload local unsent paid orders to server
          await _uploadUnsyncedOrders(sessionId: sessionId);

          // Step 1.5: Upload local held (draft) orders to server
          await _uploadDraftOrders(sessionId: sessionId);

          // Step 2: Upload local cancelled orders to server (offline cancels)
          await _uploadCancelledOrders(sessionId: sessionId);

          // Step 3: Download new/updated orders from server
          await _downloadServerOrders(sessionId: sessionId);

          success = true;
          debugPrint('✅ Delta order sync completed successfully');
        } catch (e) {
          retryCount++;
          if (retryCount <= maxRetries) {
            // Exponential backoff: 5s, 10s, 15s...
            final delay = Duration(seconds: 5 * retryCount);
            debugPrint(
                '⚠️ Sync attempt $retryCount failed. Retrying in ${delay.inSeconds}s... Error: $e');
            await Future.delayed(delay);
          } else {
            debugPrint(
                '❌ Delta order sync failed after $maxRetries retries: $e');
            rethrow; // Final failure re-thrown to the catch block below
          }
        }
      }

      // Notify UI listeners (like OrdersScreen) that data has changed after sync
      if (success) orderPlacedNotifier.value++;
    } catch (e) {
      debugPrint('❌ Delta order sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// Upload all unsynced local orders to server
  Future<void> _uploadUnsyncedOrders({int sessionId = 0}) async {
    try {
      final unsyncedOrders =
          await _orderRepo.getUnsyncedOrders(sessionId: sessionId);

      if (unsyncedOrders.isEmpty) {
        debugPrint('ℹ️ No unsynced orders to upload');
        return;
      }

      final orderBatch = unsyncedOrders.take(_orderUploadBatchLimit).toList();
      debugPrint(
          '📤 Uploading ${orderBatch.length}/${unsyncedOrders.length} unsynced orders this cycle…');

      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping order upload');
        return;
      }

      int uploadCount = 0;
      for (final order in orderBatch) {
        final orderId = order['id'] as int;
        final attempts = (order['sync_attempts'] as int?) ?? 0;

        if (attempts > 10) {
          await _orderRepo.updateOrderStatus(orderId, 'failed');
          continue;
        }

        try {
          final orderLines = await _orderRepo.getOrderLines(orderId);
          if (orderLines.isEmpty) {
            await _orderRepo.updateOrderStatus(orderId, 'failed');
            continue;
          }

          final orderSessionId = order['session_id'] as int? ?? sessionId;
          final odooId = (order['odoo_order_id'] as num?)?.toInt() ?? 0;

          // Server-synced draft orders downloaded from /api/orders/pending may
          // not have device_code stored in SQLite. If such an order is restored
          // and paid while offline, the upload later calls /api/order/<id>/pay.
          // The backend requires device_code, so fall back to the configured
          // device code instead of sending null/empty and getting HTTP 400.
          final savedDeviceCode =
              (order['device_code'] as String?)?.trim() ?? '';
          final effectiveDeviceCode = savedDeviceCode.isNotEmpty
              ? savedDeviceCode
              : await AppConfig.getDeviceCode();

          // If order exists on Odoo (restored draft), use /pay endpoint to update items & pay
          final path = (odooId > 0) ? '/api/order/$odooId/pay' : '/api/order';

          final payload = {
            'name': order['name'], // ✅ Send custom device-generated name
            'external_id': order['external_id'],
            'device_code': effectiveDeviceCode,
            'customer_id': (order['customer_id'] as int?) != null &&
                    (order['customer_id'] as int) > 0
                ? order['customer_id']
                : null,
            'pos_config_id': order['pos_config_id'],
            if (orderSessionId > 0) 'session_id': orderSessionId,
            'lines': orderLines
                .map((line) => {
                      'product_id': line['product_id'],
                      'qty': line[
                          'qty'], // Fix: Standardize on 'qty' key for Odoo API
                      'price': line['price'],
                      'tax_rate': line['tax_rate'],
                    })
                .toList(),
            'payments': [
              {
                'method':
                    (order['payment_method'] as String?)?.isNotEmpty == true
                        ? order['payment_method']
                        : 'Cash',
                'amount': order['total']
              }
            ],
          };

          final response = await ApiClient.post(
            path,
            headers: {'Content-Type': 'application/json'},
            body: payload,
            timeout: const Duration(seconds: 30),
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            final data = jsonDecode(response.body);
            final odooId = data['data']?['order_id'] as int? ?? 0;
            final pMethod = order['payment_method'] as String? ?? 'Cash';

            await _orderRepo.markOrderAsSynced(
              orderId,
              paymentMethod: pMethod,
              odooOrderId: odooId,
              sessionId: orderSessionId,
            );
            uploadCount++;
            debugPrint('✅ Order $orderId uploaded');
            await Future.delayed(_uploadThrottleDelay);
          } else {
            await _orderRepo.incrementSyncAttempts(orderId);
            debugPrint(
                '⚠️ Order $orderId upload failed: ${response.statusCode} ${response.body}');
          }
        } catch (e) {
          await _orderRepo.incrementSyncAttempts(orderId);
          debugPrint('❌ Order $orderId upload error: $e');
        }
      }

      debugPrint('📊 Uploaded $uploadCount orders');
    } catch (e) {
      debugPrint('❌ Order upload error: $e');
    }
  }

  /// Upload offline-held draft orders to Odoo via POST /api/order/draft.
  /// This ensures orders put on hold while offline are synced to the server.
  Future<void> _uploadDraftOrders({int sessionId = 0}) async {
    try {
      final unsyncedDrafts =
          await _orderRepo.getUnsyncedDraftOrders(sessionId: sessionId);

      if (unsyncedDrafts.isEmpty) {
        debugPrint('ℹ️ No unsynced draft orders to upload');
        return;
      }

      final draftBatch = unsyncedDrafts.take(_orderUploadBatchLimit).toList();
      debugPrint(
          '📤 Uploading ${draftBatch.length}/${unsyncedDrafts.length} unsynced drafts this cycle…');

      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping draft upload');
        return;
      }

      int uploadCount = 0;
      for (final order in draftBatch) {
        final orderId = order['id'] as int;
        final attempts = (order['sync_attempts'] as int?) ?? 0;

        if (attempts > 10) {
          await _orderRepo.updateOrderStatus(orderId, 'failed');
          continue;
        }

        try {
          final orderLines = await _orderRepo.getOrderLines(orderId);
          final orderSessionId = order['session_id'] as int? ?? sessionId;
          final savedDeviceCode =
              (order['device_code'] as String?)?.trim() ?? '';
          final effectiveDeviceCode = savedDeviceCode.isNotEmpty
              ? savedDeviceCode
              : await AppConfig.getDeviceCode();

          final odooId = order['odoo_order_id'] as int? ?? 0;
          final externalId = order['external_id'] as String? ?? '';
          final hasExternalId = externalId.isNotEmpty;

          // Endpoint choice: use server ID for backend orders, external ID for app-originated ones.
          final path = (odooId > 0 && !hasExternalId)
              ? '/api/order/$odooId/draft'
              : '/api/order/draft';

          final payload = {
            if (hasExternalId) 'external_id': externalId,
            'device_code': effectiveDeviceCode,
            'session_id': orderSessionId,
            'customer_id': (order['customer_id'] as int?) != null &&
                    (order['customer_id'] as int) > 0
                ? order['customer_id']
                : null,
            'customer_note': order['customer_note'] ?? '',
            'lines': orderLines
                .map((line) => {
                      'product_id': line['product_id'],
                      'qty': line[
                          'quantity'], // Standardize on 'qty' for draft sync
                      'price': line['price'],
                      'tax_rate': line['tax_rate'],
                      if (line['note']?.toString().isNotEmpty ?? false)
                        'note': line['note'],
                      if (line['customer_note']?.toString().isNotEmpty ?? false)
                        'customer_note': line['customer_note'],
                      if (line['product_name']?.toString().isNotEmpty ?? false)
                        'product_name': line['product_name'],
                      if (line['image']?.toString().isNotEmpty ?? false)
                        'image': line['image'],
                    })
                .toList(),
          };

          final response = await ApiClient.post(
            path,
            headers: {'Content-Type': 'application/json'},
            body: payload,
            timeout: const Duration(seconds: 30),
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            final data = jsonDecode(response.body);
            final odooId = data['data']?['order_id'] as int? ?? 0;
            if (odooId > 0) {
              await _orderRepo.saveDraftOdooOrderId(orderId, odooId,
                  sessionId: orderSessionId);
              uploadCount++;
              debugPrint('✅ Draft order $orderId synced to Odoo');
              await Future.delayed(_uploadThrottleDelay);
            }
          } else {
            await _orderRepo.incrementSyncAttempts(orderId);
            debugPrint(
                '⚠️ Draft order $orderId upload failed: ${response.statusCode}');
          }
        } catch (e) {
          await _orderRepo.incrementSyncAttempts(orderId);
          debugPrint('❌ Draft order $orderId upload error: $e');
        }
      }

      debugPrint('📊 Uploaded $uploadCount draft orders');
    } catch (e) {
      debugPrint('❌ Draft upload error: $e');
    }
  }

  /// Upload offline-cancelled orders to Odoo via POST /api/order/cancel.
  /// Called during sync so cancels done while offline appear in Odoo order list.
  Future<void> _uploadCancelledOrders({int sessionId = 0}) async {
    try {
      final cancelledOrders =
          await _orderRepo.getUnsyncedCancelledOrders(sessionId: sessionId);

      if (cancelledOrders.isEmpty) {
        debugPrint('ℹ️ No unsynced cancelled orders to upload');
        return;
      }

      final cancelBatch = cancelledOrders.take(_orderUploadBatchLimit).toList();
      debugPrint(
          '📤 Uploading ${cancelBatch.length}/${cancelledOrders.length} cancelled orders this cycle…');

      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping cancel upload');
        return;
      }

      int uploadCount = 0;
      for (final order in cancelBatch) {
        final orderId = order['id'] as int;
        final attempts = (order['sync_attempts'] as int?) ?? 0;

        // Skip orders that have failed too many times
        if (attempts > 10) {
          await _orderRepo.updateOrderStatus(orderId, 'failed');
          continue;
        }

        try {
          final orderSessionId = order['session_id'] as int? ?? sessionId;
          final savedDeviceCode =
              (order['device_code'] as String?)?.trim() ?? '';
          final effectiveDeviceCode = savedDeviceCode.isNotEmpty
              ? savedDeviceCode
              : await AppConfig.getDeviceCode();

          // Build cancel payload — lines are optional but helpful for Odoo records
          final orderLines = await _orderRepo.getOrderLines(orderId);
          final payload = {
            'name': order['name'], // ✅ Send custom device-generated name
            'external_id': order['external_id'],
            'device_code': effectiveDeviceCode,
            'session_id': orderSessionId,
            if ((order['customer_id'] as int?) != null &&
                (order['customer_id'] as int) > 0)
              'customer_id': order['customer_id'],
            'total': order['total'],
            // Include lines so cancelled order shows what was in cart in Odoo
            'lines': orderLines
                .map((line) => {
                      'product_id': line['product_id'],
                      'qty': line['qty'], // Fix: Standardize on 'qty' key
                      'price': line['price'],
                      'tax_rate': line['tax_rate'] ?? 0.0,
                      'note': line['note'] ?? '',
                      'customer_note': line['customer_note'] ?? '',
                    })
                .toList(),
          };

          final response = await ApiClient.post(
            '/api/order/cancel',
            headers: {'Content-Type': 'application/json'},
            body: payload,
            timeout: const Duration(seconds: 30),
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            // Mark as synced so it won't be re-uploaded next time
            await _orderRepo.markOrderAsSynced(
              orderId,
              paymentMethod: order['payment_method'] as String? ?? 'Cash',
              sessionId: orderSessionId,
              status: 'cancel',
            );
            uploadCount++;
            debugPrint('✅ Cancelled order $orderId synced to Odoo');
            await Future.delayed(_uploadThrottleDelay);
          } else {
            await _orderRepo.incrementSyncAttempts(orderId);
            debugPrint(
                '⚠️ Cancel order $orderId upload failed: ${response.statusCode}');
          }
        } catch (e) {
          await _orderRepo.incrementSyncAttempts(orderId);
          debugPrint('❌ Cancel order $orderId upload error: $e');
        }
      }

      debugPrint('📊 Uploaded $uploadCount cancelled orders');
    } catch (e) {
      debugPrint('❌ Cancelled order upload error: $e');
    }
  }

  /// Download new orders from server and sync with local DB
  /// Server is source of truth - server data overwrites local conflicts
  Future<void> _downloadServerOrders({int sessionId = 0}) async {
    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();
      final lastSyncTime = await _getLastOrderSyncTime(sessionId);

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping order download');
        return;
      }

      final sessionParam = sessionId > 0 ? '&session_id=$sessionId' : '';
      // Fetch orders from server since last sync
      final response = await ApiClient.get(
        '/api/orders/since?timestamp=${lastSyncTime.millisecondsSinceEpoch}$sessionParam',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 30),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final List<dynamic> orders =
            body is List ? body : (body['data'] ?? body['orders'] ?? []);

        if (orders.isEmpty) {
          debugPrint('ℹ️ No new server orders to download');
          return;
        }

        debugPrint('📥 Downloading ${orders.length} orders from server...');

        int downloadCount = 0;
        for (final orderData in orders) {
          try {
            final serverId = orderData['id'] as int?;
            if (serverId == null) continue;

            // Use server-side external_pos_id (Flutter UUID) and server ID to match
            final serverExtId = orderData['external_pos_id'] as String? ?? '';

            // 1. Try to find local order by server ID
            Map<String, dynamic>? existingOrder = await _orderRepo
                .getOrderByOdooId(serverId, sessionId: sessionId);

            // 2. Try to find by UUID if not matched by ID
            if (existingOrder == null && serverExtId.isNotEmpty) {
              existingOrder = await _orderRepo.getOrderByExternalId(serverExtId,
                  sessionId: sessionId);
            }

            if (existingOrder == null) {
              // New order from server - insert it
              final newId = await _insertServerOrder(orderData, sessionId);
              if (newId > 0) {
                downloadCount++;
                // Save lines received in delta sync for offline use
                final serverLines = orderData['lines'];
                if (serverLines is List && serverLines.isNotEmpty) {
                  await _orderRepo.saveOrderLines(
                      newId, serverLines.cast<Map<String, dynamic>>());
                }
              }
            } else {
              // Order exists - update with server data (server has priority)
              await _updateOrderWithServerData(
                  existingOrder['id'], orderData, sessionId);

              // Update lines if server provided them (ensures cache is fresh)
              final serverLines = orderData['lines'];
              if (serverLines is List && serverLines.isNotEmpty) {
                await _orderRepo.saveOrderLines(existingOrder['id'],
                    serverLines.cast<Map<String, dynamic>>());
              }
            }
          } catch (e) {
            debugPrint('❌ Error processing server order: $e');
          }
        }

        await _updateLastOrderSyncTime(DateTime.now(), sessionId);
        debugPrint('📊 Downloaded and synced $downloadCount orders');
      } else {
        throw Exception(
            'Failed to download server orders (HTTP ${response.statusCode})');
      }
    } catch (e) {
      debugPrint('❌ Order download error: $e');
      rethrow; // Propagate to retry loop in deltaSyncOrders
    }
  }

  /// Insert a new order from server into local database
  Future<int> _insertServerOrder(
      Map<String, dynamic> serverOrder, int sessionId) async {
    try {
      final db = await DatabaseHelper().database;

      // Use session ID from server if available
      final orderSessionId = serverOrder['session_id'] as int? ?? sessionId;

      final serverId = serverOrder['id'];
      final serverMethods = serverOrder['payment_methods'];
      final pMethod = (serverMethods is List && serverMethods.isNotEmpty)
          ? serverMethods.first.toString()
          : 'Cash';
      // Let SQLite auto-increment the 'id' for local orders.
      // The 'external_id' is used for server-side uniqueness.
      final newLocalId = await db.insert('orders', {
        // Ensure 'name' is always present, fallback to Odoo ID if server doesn't provide
        'name': serverOrder['name'] as String? ?? 'ORDER-$serverId',
        // CRITICAL: Ensure 'id' is NOT included in the map.
        // SQLite must auto-increment the local ID to avoid Primary Key conflicts
        // with existing offline orders.
        // Map Odoo's external_pos_id to SQLite's external_id
        'external_id':
            serverOrder['external_pos_id'] ?? serverOrder['external_id'],
        'odoo_order_id': serverId,
        'device_code': serverOrder['device_code']?.toString() ?? '',
        'customer_id': (serverOrder['customer_id'] is List &&
                (serverOrder['customer_id'] as List).isNotEmpty)
            ? (int.tryParse(serverOrder['customer_id'][0].toString()) ?? 0)
            : (int.tryParse(serverOrder['customer_id']?.toString() ?? '') ?? 0),
        'customer_name': serverOrder['customer_name']?.toString() ?? 'Walk-in',
        'pos_config_id': (serverOrder['pos_config_id'] is List &&
                (serverOrder['pos_config_id'] as List).isNotEmpty)
            ? (int.tryParse(serverOrder['pos_config_id'][0].toString()) ?? 0)
            : (int.tryParse(serverOrder['pos_config_id']?.toString() ?? '') ??
                0),
        'session_id': orderSessionId,
        'payment_method': pMethod,
        'total': serverOrder['total'],
        'tax_amount': serverOrder['tax_amount'],
        // Respect server state — cancelled orders from server must show as cancel,
        // not be inserted as 'done'.
        'status': (serverOrder['state'] == 'cancel') ? 'cancel' : 'done',
        'synced': 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      debugPrint(
          '✨ Inserted new server order ${serverOrder['id']} (local ID: $newLocalId)');
      return newLocalId;
    } catch (e) {
      debugPrint('❌ Error inserting server order: $e');
      return 0;
    }
  }

  /// Update local order with server data (server has priority)
  Future<void> _updateOrderWithServerData(
      int orderId, Map<String, dynamic> serverOrder, int sessionId) async {
    try {
      final db = await DatabaseHelper().database;

      // Use session ID from server if available
      final orderSessionId = serverOrder['session_id'] as int? ?? sessionId;

      final serverId = serverOrder['id'];
      final serverMethods = serverOrder['payment_methods'];
      final pMethod = (serverMethods is List && serverMethods.isNotEmpty)
          ? serverMethods.first.toString()
          : null;
      await db.update(
        'orders',
        {
          'name': serverOrder['name'] as String? ?? 'ORDER-$serverId',
          'device_code': serverOrder['device_code']?.toString() ?? '',
          'session_id': orderSessionId,
          'customer_id': (serverOrder['customer_id'] is List &&
                  (serverOrder['customer_id'] as List).isNotEmpty)
              ? (int.tryParse(serverOrder['customer_id'][0].toString()) ?? 0)
              : (int.tryParse(serverOrder['customer_id']?.toString() ?? '') ??
                  0),
          'customer_name': serverOrder['customer_name'],
          if (pMethod != null) 'payment_method': pMethod,
          'total': serverOrder['total'],
          'tax_amount': serverOrder['tax_amount'],
          // Respect server state — 'cancel' orders must stay cancelled,
          // not be overwritten as 'done' when downloaded from server.
          'status': (serverOrder['state'] == 'cancel') ? 'cancel' : 'done',
          'synced': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );

      debugPrint('✏️ Updated order $orderId with server data');
    } catch (e) {
      debugPrint('❌ Error updating order with server data: $e');
    }
  }

  // ─────────────────────────────────────────────
  // AUTH/SUBSCRIPTION DELTA SYNC
  // ─────────────────────────────────────────────

  /// Smart auth/subscription sync - only update if changed
  Future<void> deltaSyncAuthData() async {
    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        return;
      }

      // Get current local auth data hash
      final localAuthData = await _getLocalAuthDataHash();

      // Fetch from server
      final response = await ApiClient.get(
        '/api/auth/profile',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final serverAuthData = body['data'] ?? body;
        final serverHash = _hashMap(serverAuthData);

        if (localAuthData != serverHash) {
          // Auth data changed on server
          await _updateLocalAuthData(serverAuthData);
          debugPrint('✅ Auth data updated from server');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Auth sync error: $e');
    }
  }

  /// Get hash of local auth data to detect changes
  Future<String> _getLocalAuthDataHash() async {
    try {
      final email = await AppConfig.getApiEmail();
      final subscription = await AppConfig.getSubscriptionCode();
      final expDate = await AppConfig.getSubscriptionExpDate();

      final data = {
        'email': email,
        'subscription': subscription,
        'exp_date': expDate,
      };

      return _hashMap(data);
    } catch (e) {
      return '';
    }
  }

  /// Update local auth data if changed on server
  Future<void> _updateLocalAuthData(Map<String, dynamic> authData) async {
    try {
      if (authData['email'] != null) {
        // Only update if different
        final currentEmail = await AppConfig.getApiEmail();
        if (currentEmail != authData['email']) {
          await AppConfig.saveApiEmail(authData['email']);
        }
      }

      if (authData['subscription'] != null) {
        final currentSub = await AppConfig.getSubscriptionCode();
        if (currentSub != authData['subscription']) {
          await AppConfig.saveSubscriptionCode(authData['subscription']);
        }
      }

      if (authData['exp_date'] != null) {
        await AppConfig.saveSubscriptionExpDate(authData['exp_date']);
      }
    } catch (e) {
      debugPrint('❌ Error updating auth data: $e');
    }
  }

  // ─────────────────────────────────────────────
  // SYNC TRACKING HELPERS
  // ─────────────────────────────────────────────

  /// Get last order sync timestamp
  Future<DateTime> _getLastOrderSyncTime(int sessionId) async {
    try {
      final db = await DatabaseHelper().database;
      final result = await db.query(
        'sync_log',
        where: "entity_type = ? AND action = ? AND entity_id = ?",
        whereArgs: ['order', 'download', sessionId],
        orderBy: 'created_at DESC',
        limit: 1,
      );

      if (result.isNotEmpty) {
        final timestamp = result.first['created_at'] as int?;
        if (timestamp != null) {
          return DateTime.fromMillisecondsSinceEpoch(timestamp);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error getting last sync time: $e');
    }

    // Default to 7 days ago
    return DateTime.now().subtract(const Duration(days: 7));
  }

  /// Update last order sync timestamp
  Future<void> _updateLastOrderSyncTime(DateTime time, int sessionId) async {
    try {
      final db = await DatabaseHelper().database;
      await db.insert(
        'sync_log',
        {
          'entity_type': 'order',
          'action': 'download',
          'entity_id': sessionId,
          'status': 'success',
          'created_at': time.millisecondsSinceEpoch,
        },
      );
    } catch (e) {
      debugPrint('⚠️ Error updating sync time: $e');
    }
  }

  /// Hash a map to detect changes
  String _hashMap(Map<String, dynamic> data) {
    final jsonStr = jsonEncode(data);
    return sha256.convert(utf8.encode(jsonStr)).toString();
  }

  // ─────────────────────────────────────────────
  // CUSTOMER DELTA SYNC
  // ─────────────────────────────────────────────

  /// Smart customer sync: upload local unsynced changes to Odoo.
  /// This ensures that customers created or updated while offline are synced to the server.
  Future<void> deltaSyncCustomers() async {
    if (_isSyncing) {
      debugPrint('⏳ Delta customer sync already in progress, skipping');
      return;
    }

    try {
      _isSyncing = true;
      debugPrint('🔄 Starting delta customer sync...');

      int retryCount = 0;
      const maxRetries = 3;
      bool success = false;

      while (retryCount <= maxRetries && !success) {
        try {
          final isHealthy = await OdooService.checkConnection();
          if (!isHealthy) throw Exception('Odoo server is unreachable');

          // Step 1: Upload local unsynced changes to Odoo.
          // Handles record conflicts (deleted on server, duplicates).
          await _uploadUnsyncedCustomers();

          // Step 2: Download new/updated customers from server
          await _downloadServerCustomers();

          success = true;
        } catch (e) {
          retryCount++;
          if (retryCount <= maxRetries) {
            final delay = Duration(seconds: 5 * retryCount);
            debugPrint(
                '⚠️ Customer sync attempt $retryCount failed. Retrying in ${delay.inSeconds}s...');
            await Future.delayed(delay);
          } else {
            rethrow;
          }
        }
      }

      // Notify UI listeners that customer data has changed after a successful sync
      if (success) customerChangedNotifier.value++;
    } catch (e) {
      debugPrint('❌ Delta customer sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  /// Download new or updated customers from server and sync with local DB
  Future<void> _downloadServerCustomers() async {
    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping customer download');
        return;
      }

      // 1. Get all customer IDs from server
      final serverCustomerIds = await _getServerCustomerIds(baseUrl, token);
      if (serverCustomerIds.isEmpty) {
        debugPrint('ℹ️ No customers on server');
        return;
      }

      // 2. Get local customer IDs
      final localCustomerIds = await _getLocalCustomerIds();

      // 3. Identify New and Potential Changed customers
      final newCustomerIds = serverCustomerIds
          .where((id) => !localCustomerIds.contains(id))
          .toList();

      // Following the product delta pattern: we fetch IDs that exist on both sides
      // assuming the server /ids endpoint returns recently modified records.
      final changedCustomerIds = serverCustomerIds
          .where((id) => localCustomerIds.contains(id))
          .toList();

      if (newCustomerIds.isEmpty && changedCustomerIds.isEmpty) {
        debugPrint('ℹ️ No new or updated customers to download');
        return;
      }

      final idsToFetch = [...newCustomerIds, ...changedCustomerIds];
      debugPrint('📥 Downloading ${idsToFetch.length} customer updates...');

      final customers = await _fetchCustomersByIds(baseUrl, token, idsToFetch);

      if (customers.isNotEmpty) {
        await _customerRepo.insertOrUpdateCustomers(
          customers.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        );
        debugPrint('📊 Downloaded and synced ${customers.length} customers');
      }
    } catch (e) {
      debugPrint('❌ Customer download error: $e');
      rethrow;
    }
  }

  /// Get all synced customer IDs from local database
  Future<List<int>> _getLocalCustomerIds() async {
    try {
      final db = await DatabaseHelper().database;
      // Only get positive IDs (Odoo IDs). Negative IDs are local-only/offline.
      final result =
          await db.query('customers', columns: ['id'], where: 'id > 0');
      return result.map((row) => row['id'] as int).toList();
    } catch (e) {
      debugPrint('❌ Error getting local customer IDs: $e');
      return [];
    }
  }

  /// Upload local unsynced changes to Odoo.
  /// Detects and handles conflicts like record deletion on server or duplicate constraints.
  Future<void> _uploadUnsyncedCustomers() async {
    try {
      final unsynced = await _customerRepo.getUnsyncedCustomers();
      if (unsynced.isEmpty) {
        debugPrint('ℹ️ No unsynced customers to upload');
        return;
      }

      final customerBatch = unsynced.take(_customerUploadBatchLimit).toList();
      debugPrint(
          '📤 Uploading ${customerBatch.length}/${unsynced.length} unsynced customers this cycle...');
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();

      if (baseUrl.isEmpty || token.isEmpty) {
        debugPrint('⚠️ Missing credentials — skipping customer upload');
        return;
      }

      for (final customer in customerBatch) {
        final localId = customer['id'] as int;
        final isNew = localId < 0;
        final attempts = (customer['sync_attempts'] as int?) ?? 0;

        if (attempts > 10) {
          // Record is likely corrupted or incompatible with server rules.
          // Mark as synced to prevent blocking the sync queue indefinitely.
          await _customerRepo.markCustomerAsSynced(localId);
          continue;
        }

        try {
          final payload = {
            'name': customer['name'],
            'phone': customer['phone'] ?? '',
            'email': customer['email'] ?? '',
          };

          final path = isNew
              ? '/api/customers/create'
              : '/api/customers/$localId/update';

          final response = await (isNew
                  ? ApiClient.post(path,
                      headers: {'Content-Type': 'application/json'},
                      body: payload)
                  : ApiClient.put(path,
                      headers: {'Content-Type': 'application/json'},
                      body: payload))
              .timeout(const Duration(seconds: 15));

          final statusCode = response.statusCode;

          if (statusCode == 200 || statusCode == 201) {
            final data = jsonDecode(response.body);
            if (data['status'] == 'success') {
              if (isNew && data['data'] != null) {
                final serverId = data['data']['id'] as int? ?? 0;
                if (serverId > 0) {
                  await _resolveNewCustomerIdentity(localId, serverId);
                }
              } else {
                await _customerRepo.markCustomerAsSynced(localId);
              }
              await Future.delayed(_uploadThrottleDelay);
            }
          } else if (statusCode == 404 && !isNew) {
            // CONFLICT: record deleted on server. Remove locally.
            debugPrint(
                '⚠️ Customer $localId not found on Odoo. Deleting local copy.');
            final db = await DatabaseHelper().database;
            await db.delete('customers', where: 'id = ?', whereArgs: [localId]);
          } else if (statusCode == 400 || statusCode == 409) {
            // CONFLICT: Validation or duplicate error (e.g. Email already used).
            final data = jsonDecode(response.body);
            final msg = (data['message'] ?? '').toString().toLowerCase();

            if (msg.contains('already exists') || msg.contains('duplicate')) {
              // If the server provides the existing customer's ID, link it.
              final serverId = data['data']?['id'] as int?;
              if (serverId != null && serverId > 0) {
                debugPrint(
                    '🔗 Merging local $localId with existing server customer $serverId');
                await _resolveNewCustomerIdentity(localId, serverId);
              } else {
                await _customerRepo.incrementSyncAttempts(localId);
              }
            } else {
              await _customerRepo.incrementSyncAttempts(localId);
            }
          } else {
            await _customerRepo.incrementSyncAttempts(localId);
          }
        } catch (e) {
          debugPrint('❌ Error uploading customer $localId: $e');
          await _customerRepo.incrementSyncAttempts(localId);
        }
      }
    } catch (e) {
      debugPrint('❌ Customer upload batch failed: $e');
    }
  }

  /// Replaces a temporary offline ID (negative) with a real server ID.
  /// Updates both the customer record and any linked offline orders.
  Future<void> _resolveNewCustomerIdentity(int localId, int serverId) async {
    try {
      final db = await DatabaseHelper().database;
      await db.transaction((txn) async {
        await txn.rawInsert('''
          INSERT OR REPLACE INTO customers 
          (id, name, phone, email, synced, is_dirty, sync_attempts, created_at, updated_at)
          SELECT ?, name, phone, email, 1, 0, 0, created_at, updated_at
          FROM customers WHERE id = ?
        ''', [serverId, localId]);
        await txn.delete('customers', where: 'id = ?', whereArgs: [localId]);
        // Update local orders to point to the new ID so they sync correctly
        await txn.update('orders', {'customer_id': serverId},
            where: 'customer_id = ?', whereArgs: [localId]);
      });
      debugPrint('✅ Identity resolved: $localId -> $serverId');
    } catch (e) {
      debugPrint('❌ Identity resolution error: $e');
    }
  }

  /// Get all customer IDs from server (quick ID list)
  Future<List<int>> _getServerCustomerIds(String baseUrl, String token) async {
    try {
      final response = await ApiClient.get(
        '/api/customers/ids',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 10),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final List<dynamic> ids = body is List
            ? body
            : (body['data'] ?? body['ids'] ?? body['customers'] ?? []);
        return ids
            .map((id) => int.tryParse(id.toString()) ?? 0)
            .where((id) => id > 0)
            .toList();
      }
      debugPrint(
          '⚠️ Failed to get customer IDs from server: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('❌ Error getting server customer IDs: $e');
      return [];
    }
  }

  /// Fetch customers by specific IDs from server
  Future<List<Map<String, dynamic>>> _fetchCustomersByIds(
      String baseUrl, String token, List<int> customerIds) async {
    try {
      if (customerIds.isEmpty) return [];

      final idsParam = customerIds.join(',');
      final response = await ApiClient.get(
        '/api/customers/by-ids?ids=$idsParam',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 30),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        final List<dynamic> items =
            body is List ? body : (body['data'] ?? body['customers'] ?? []);

        return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      debugPrint('⚠️ Failed to fetch customers by IDs: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('❌ Error fetching customers by IDs: $e');
      return [];
    }
  }
}
