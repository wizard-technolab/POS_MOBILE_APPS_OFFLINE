import 'package:flutter/material.dart';
import 'package:odocart/services/odoo_service.dart'; // Import OdooService
import 'package:sqflite/sqflite.dart';
import '../../services/db_helper.dart';
import 'package:flutter/foundation.dart';
import '../../features/orders/data/order_line_repository.dart';
import '../../services/app_config.dart';

// ─────────────────────────────────────────────────────
// ORDER REPOSITORY
// ─────────────────────────────────────────────────────
class OrderRepository {
  final dbHelper = DatabaseHelper();
  final OrderLineRepository _lineRepo = OrderLineRepository();

  // ── CREATE Offline Order ────────────────────
  // status: 'pending' for paid offline orders (auto-syncs when online),
  //         'draft' for cart saved on session-switch (does NOT auto-sync).
  // paymentMethod: actual method selected by cashier (Cash / Bank) — saved so
  //                sync_manager sends the correct payment to Odoo.
  Future<int> createOfflineOrder({
    required String externalId,
    required String deviceCode,
    required int customerId,
    required String? customerName,
    required int sessionId,
    required String customerNote,
    required List<Map<String, dynamic>> lines,
    required double total,
    required double taxAmount,
    String status =
        'draft', // 'pending' = paid & waiting sync; 'draft' = session switch save
    String paymentMethod =
        'Cash', // Actual payment method for Odoo sync payload
    String companyName =
        '', // Company name shown on receipt header for offline orders
  }) async {
    try {
      final db = await dbHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      final generatedName = status == 'cancel'
          ? '/'
          : await _generateNextOrderName(sessionId, deviceCode);

      // Insert order — status and paymentMethod are saved so sync works correctly
      final orderId = await db.insert(
        'orders',
        {
          'name':
              generatedName, // Use '/' for cancelled, else generated sequence
          'external_id': externalId,
          'device_code': deviceCode,
          'customer_id': customerId,
          'customer_name': customerName,
          'customer_note': customerNote,
          'session_id': sessionId,
          'status': status,
          'synced': 0,
          'sync_attempts': 0,
          'odoo_order_id': 0, // Not yet synced to Odoo as draft
          'total': total,
          'tax_amount': taxAmount,
          // Save payment method so sync_manager can send correct method to Odoo
          'payment_method': paymentMethod,
          // Save company name so offline order receipt shows correct header
          'company_name': companyName,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // ✅ Save lines BEFORE returning
      if (lines.isNotEmpty) {
        await _lineRepo.insertLinesForOrder(
          orderId: orderId,
          lines: lines,
          createdAt: now,
          sessionId: sessionId,
        );

        debugPrint('✅ Inserted ${lines.length} lines for order $orderId');
      } else {
        debugPrint('⚠️ Warning: Created order $orderId with 0 lines');
      }

      return orderId;
    } catch (e) {
      debugPrint('❌ createOfflineOrder error: $e');
      return 0;
    }
  }

  /// Generates the next name in sequence: "Session Name - Device Code - 0001"
  Future<String> _generateNextOrderName(
      int sessionId, String deviceCode) async {
    final db = await dbHelper.database;

    // 1. Resolve Session Name reliably
    // Priority: Database Lookup (most reliable) > Raw Config > Display Name > Fallback
    String sessionName = '';
    if (sessionId > 0) {
      final sessRow = await db.query('sessions',
          columns: ['name'], where: 'id = ?', whereArgs: [sessionId]);
      if (sessRow.isNotEmpty) {
        sessionName = sessRow.first['name'] as String? ?? '';
      }
    }

    if (sessionName.isEmpty) {
      sessionName = await AppConfig.getRawPosSessionName();
      if (sessionName.isEmpty) {
        sessionName = await AppConfig.getPosSessionName();
        if (sessionName.contains(' — ')) {
          sessionName = sessionName.split(' — ').first;
        }
      }
    }

    // Ensure we don't return an empty prefix "Order - 1"
    if (sessionName.isEmpty) {
      sessionName = "Order";
    }

    final resetTime = await AppConfig.getSequenceResetTime(sessionId);

    // 2. Query for the last order in THIS session using BOTH ID and name pattern.
    // This ensures that even if Session IDs were reused, the session name prefix isolates the sequence.
    final List<Map<String, dynamic>> lastOrder = await db.query(
      'orders',
      columns: ['name'],
      where: 'session_id = ? AND created_at > ? AND name != ? AND name LIKE ?',
      // Count named cancelled orders too. A restored order cancelled as
      // ...00004 must still reserve 00004, otherwise the next order would
      // reuse the same number. Anonymous cancel rows keep name='/' and remain
      // excluded so they do not consume a sequence.
      whereArgs: [sessionId, resetTime, '/', '$sessionName - %'],
      orderBy:
          'created_at DESC', // Chronological order is more reliable for sequences
      limit: 1,
    );

    int nextSequence = 1;

    if (lastOrder.isNotEmpty) {
      final String lastName = lastOrder.first['name'] ?? '';
      // Robust parsing: split by any dash/em-dash with optional surrounding spaces and take last part
      final parts = lastName.split(RegExp(r'\s*[-—]\s*'));
      if (parts.isNotEmpty) {
        final seqStr = parts.last;
        final lastSeq = int.tryParse(seqStr) ?? 0;
        if (lastSeq > 0) {
          nextSequence = lastSeq + 1;
        }
      }
    }

    // 3. Format result: "Session Name - Device Code - 000001"
    final String seqPadded = nextSequence.toString().padLeft(6, '0');

    // If sessionName contains the full display string, we might want just the first part.
    // Assuming sessionName is "Bakery Shop"
    return "$sessionName - $deviceCode - $seqPadded";
  }

  // ── GET All Orders ──────────────────────────
  Future<List<Map<String, dynamic>>> getAllOrders({int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      if (sessionId != null && sessionId > 0) {
        return await db.query('orders',
            where: 'session_id = ?',
            whereArgs: [sessionId],
            orderBy: 'created_at DESC');
      } else {
        return []; // Strictly require session ID to avoid mixing orders from different sessions
      }
    } catch (e) {
      return [];
    }
  }

  // Get cart items saved as draft when user switched session without paying.
  // Returns ALL pending (draft) orders for the session — both local-only
  // and server-synced — without duplicates.
  //
  // DEDUP LOGIC:
  //   Local draft not yet on server  → odoo_order_id = 0, synced = 0  → INCLUDE
  //   Server draft synced to local   → odoo_order_id > 0, synced = 1  → INCLUDE
  //   Local draft already on server  → odoo_order_id > 0, synced = 1  → EXCLUDE
  //     (server version shown via insertOrUpdateOrders, local version is duplicate)
  //
  // Rule: show local draft ONLY when odoo_order_id = 0 (not yet on server).
  // Server drafts (odoo_order_id > 0) come from insertOrUpdateOrders and are
  // already in the orders table — they are picked up by the server orders loop.
  Future<List<Map<String, dynamic>>> getLocalPendingOrders(
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;

      if (sessionId != null && sessionId > 0) {
        return await db.rawQuery('''
          SELECT o.*,
                 (SELECT COUNT(*) FROM order_lines l WHERE l.order_id = o.id) AS line_count
          FROM orders o
          WHERE o.status = 'draft'
            AND o.session_id = ?
            AND (o.odoo_order_id IS NULL OR o.odoo_order_id = 0)
          ORDER BY o.created_at DESC
        ''', [sessionId]);
      } else {
        return [];
      }
    } catch (e) {
      return [];
    }
  }

  // Returns server-synced draft orders (odoo_order_id > 0, status = 'draft').
  //
  // These are pending orders that came from Odoo backend or another device,
  // cached locally by fetchPendingOrders() while the app was online.
  //
  // Used in _loadLocalOrders() (offline mode) so that going offline does NOT
  // hide pending orders that were placed from Odoo or another device.
  //
  // Online mode: these orders are shown via the serverOrders loop — no need
  // to include them here (would cause duplicates).
  Future<List<Map<String, dynamic>>> getServerSyncedDraftOrders(
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      if (sessionId != null && sessionId > 0) {
        return await db.rawQuery('''
          SELECT o.*,
                 (SELECT COUNT(*) FROM order_lines l WHERE l.order_id = o.id) AS line_count
          FROM orders o
          WHERE o.status = 'draft'
            AND o.session_id = ?
            AND o.odoo_order_id IS NOT NULL
            AND o.odoo_order_id > 0
          ORDER BY o.created_at DESC
        ''', [sessionId]);
      } else {
        return [];
      }
    } catch (e) {
      return [];
    }
  }

  // ── GET Orders by Status (for offline) ──
  // Pass sessionId to filter orders by session — so each POS session only
  // sees its own orders (e.g. Restaurant session won't show Clothes session orders).
  Future<List<Map<String, dynamic>>> getOrdersWithStatus(
    String status, {
    int? sessionId,
  }) async {
    try {
      final db = await dbHelper.database;

      if (sessionId != null && sessionId > 0) {
        return await db.rawQuery('''
          SELECT o.*,
                 (SELECT COUNT(*) FROM order_lines l WHERE l.order_id = o.id) AS line_count
          FROM orders o
          WHERE o.status = ? AND o.session_id = ?
          ORDER BY o.created_at DESC
        ''', [status, sessionId]);
      } else {
        return []; // Strictly require session ID to avoid mixing orders from different sessions
      }
    } catch (e) {
      return [];
    }
  }

  // ── GET Order by ID ─────────────────────────
  Future<Map<String, dynamic>?> getOrderById(int orderId) async {
    try {
      final db = await dbHelper.database;
      final result = await db.query(
        'orders',
        where: 'id = ?',
        whereArgs: [orderId],
      );
      return result.isNotEmpty ? result.first : null;
    } catch (e) {
      return null;
    }
  }

  // ── GET Order by Odoo ID (WITH LINE COUNT) ────────────────────
  // Computes line_count in the query so OrderModel has correct item count
  Future<Map<String, dynamic>?> getOrderByOdooId(int odooId,
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;

      String sessionFilter = '';
      List<dynamic> whereArgs = [odooId];

      if (sessionId != null && sessionId > 0) {
        sessionFilter = ' AND o.session_id = ?';
        whereArgs.add(sessionId);
      }

      final result = await db.rawQuery('''
        SELECT o.*,
               (SELECT COUNT(*) FROM order_lines l WHERE l.order_id = o.id) AS line_count
        FROM orders o
        WHERE o.odoo_order_id = ?
        $sessionFilter
        LIMIT 1
      ''', whereArgs);

      return result.isNotEmpty ? result.first : null;
    } catch (e) {
      debugPrint('❌ getOrderByOdooId error: $e');
      return null;
    }
  }

  // ── GET Order by External ID ────────────────
  Future<Map<String, dynamic>?> getOrderByExternalId(String externalId,
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      String where = 'external_id = ?';
      List<dynamic> whereArgs = [externalId];
      if (sessionId != null && sessionId > 0) {
        where += ' AND session_id = ?';
        whereArgs.add(sessionId);
      }
      final result = await db.query(
        'orders',
        where: where,
        whereArgs: whereArgs,
      );
      return result.isNotEmpty ? result.first : null;
    } catch (e) {
      return null;
    }
  }

  // ── GET Order Lines (delegates to OrderLineRepository) ─────────────────
  Future<List<Map<String, dynamic>>> getOrderLines(int orderId,
          {int? sessionId}) =>
      _lineRepo.getOrderLines(orderId, sessionId: sessionId);

  // ── SAVE Order Lines (delegates to OrderLineRepository) ────────────────
  Future<void> saveOrderLines(int orderId, List<Map<String, dynamic>> lines,
          {int? sessionId}) =>
      _lineRepo.saveOrderLines(orderId, lines, sessionId: sessionId);

  // ── GET Unsynced/Pending Orders ─────────────
  // Fetches orders with status = 'pending' — paid offline orders waiting to sync.
  // 'draft' orders (session-switch saves) are excluded — not paid yet.
  Future<List<Map<String, dynamic>>> getUnsyncedOrders({int? sessionId}) async {
    try {
      final db = await dbHelper.database;

      String where = 'synced = 0 AND status = ?';
      List<dynamic> whereArgs = ['pending'];

      if (sessionId != null && sessionId > 0) {
        where += ' AND session_id = ?';
        whereArgs.add(sessionId);
      }

      return await db.query(
        'orders',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'created_at ASC',
      );
    } catch (e) {
      return [];
    }
  }

  // ── GET Unsynced Cancelled Orders ───────────────────────────────────────
  // Returns offline-cancelled orders that have NOT yet been reported to Odoo.
  // These are orders the cashier cancelled while offline (status='cancel', synced=0).
  // The sync manager calls /api/order/cancel for each of these.
  Future<List<Map<String, dynamic>>> getUnsyncedCancelledOrders(
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;

      String where = 'synced = 0 AND status = ?';
      List<dynamic> whereArgs = ['cancel'];

      if (sessionId != null && sessionId > 0) {
        where += ' AND session_id = ?';
        whereArgs.add(sessionId);
      }

      return await db.query(
        'orders',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'created_at ASC',
      );
    } catch (e) {
      return [];
    }
  }

  // ── GET Unsynced Draft Orders (for background Odoo draft sync) ───────────
  //
  // Returns all local draft orders that have NOT yet been uploaded to Odoo.
  //
  // CRITERIA:
  //   status = 'draft'       → order is pending (not paid yet)
  //   odoo_order_id = 0      → not yet synced to Odoo as a draft
  //   sync_attempts < 5      → stop retrying after 5 failures
  //
  // Called by sync_manager._syncDraftOrdersToOdoo() during every sync cycle.
  Future<List<Map<String, dynamic>>> getUnsyncedDraftOrders(
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      final sessionFilter = (sessionId != null && sessionId > 0)
          ? ' AND o.session_id = $sessionId'
          : '';
      return await db.rawQuery('''
        SELECT o.*,
               (SELECT COUNT(*) FROM order_lines l WHERE l.order_id = o.id) AS line_count
        FROM orders o
        WHERE o.status = 'draft'
          $sessionFilter
          AND o.synced = 0
          AND (o.sync_attempts IS NULL OR o.sync_attempts < 5)
        ORDER BY o.created_at ASC
      ''');
    } catch (e) {
      debugPrint('❌ getUnsyncedDraftOrders error: $e');
      return [];
    }
  }

  // ── SAVE Odoo Order ID for a Draft ────────────────────────────────────────
  //
  // Called after POST /api/order/draft succeeds.
  // Stores the Odoo pos.order ID so this draft is NOT re-uploaded on future syncs.
  // Also used by orders_screen.dart to skip redundant sync when paying a draft.
  //
  // Parameters:
  //   localOrderId  — the SQLite orders.id of the local draft row
  //   odooOrderId   — the Odoo pos.order id returned by /api/order/draft
  Future<void> saveDraftOdooOrderId(int localOrderId, int odooOrderId) async {
    try {
      final db = await dbHelper.database;
      await db.update(
        'orders',
        {
          'odoo_order_id': odooOrderId,
          'synced': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [localOrderId],
      );
      debugPrint(
        '✅ Saved odoo_order_id=$odooOrderId for local draft id=$localOrderId',
      );
    } catch (e) {
      debugPrint('❌ saveDraftOdooOrderId error: $e');
    }
  }

  // ── UPDATE Order Status ─────────────────────
  Future<int> updateOrderStatus(
    int orderId,
    String status, {
    String? paymentMethod,
    int? synced,
  }) async {
    try {
      final db = await dbHelper.database;
      return await db.update(
        'orders',
        {
          if (paymentMethod != null) 'payment_method': paymentMethod,
          if (synced != null) 'synced': synced,
          // Keep the existing order name when changing the status. This is
          // important for restored orders: cancelling Clothes shop/...00004
          // should mark that same sequence as cancelled, not rename it to '/'.
          'status': status,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── INSERT SYNCED ORDER ─────────────────────────────────────────────────
  // Saves a successfully placed online order to local SQLite with synced=1.
  // Used after a successful POST /api/order so the orders list immediately
  // shows the correct payment method (Cash/Bank) without waiting for the
  // server to return it in the next GET /api/orders fetch.
  Future<void> insertSyncedOrder({
    required int odooId,
    String? name, // Add name parameter
    required String externalId,
    required String customerName,
    required String customerNote,
    required double total,
    required String paymentMethod,
    required int sessionId,
    required List<Map<String, dynamic>> lines,
    String? companyName,
  }) async {
    try {
      final db = await dbHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Use local auto-increment, store odooId in odoo_order_id
      final localId = await db.insert(
          'orders',
          {
            'name': name ?? 'ORDER-$odooId', // Use provided name or fallback
            'odoo_order_id': odooId,
            'external_id': externalId,
            'customer_name': customerName,
            'customer_note': customerNote,
            'session_id': sessionId,
            'total': total,
            'tax_amount': 0.0,
            'status': 'done', // already paid on server
            'company_name': companyName ?? '',
            'payment_method':
                paymentMethod, // actual selected method — Cash or Bank
            'synced': 1, // on Odoo — do not re-sync
            'sync_attempts': 0,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

      // Save order lines so order detail view works correctly.
      // price_unit, price_subtotal, price_subtotal_incl must all be saved here
      // so getOrderLines() can return correct values without falling back to
      // the products table (which may not have the price at time of sale).
      for (final line in lines) {
        final lineQty = (line['qty'] as num?)?.toDouble() ??
            (line['quantity'] as num?)?.toDouble() ??
            1.0;
        final linePrice = (line['price'] as num?)?.toDouble() ??
            (line['price_unit'] as num?)?.toDouble() ??
            0.0;
        final lineTax = (line['tax_rate'] as num?)?.toDouble() ?? 0.0;
        final lineSub = double.parse((lineQty * linePrice).toStringAsFixed(2));
        final lineTaxAmt = double.parse(
          (lineSub * lineTax / 100).toStringAsFixed(2),
        );
        final lineSubIncl = double.parse(
          (lineSub + lineTaxAmt).toStringAsFixed(2),
        );

        await db.insert(
            'order_lines',
            {
              'order_id': localId,
              'session_id': sessionId,
              'product_id': line['product_id'] as int? ?? 0,
              'product_name': line['product_name'] as String? ?? 'Unknown',
              'quantity': lineQty.toInt(),
              'price': linePrice,
              'price_unit':
                  linePrice, // needed by getOrderLines price_unit CASE
              'price_subtotal': lineSub, // excl. tax
              'price_subtotal_incl':
                  lineSubIncl, // incl. tax — shown in order detail
              'tax_rate': lineTax,
              'note': line['note'] as String? ?? '',
              'customer_note': line['customer_note'] as String? ?? '',
              'image': line['image'] as String? ?? '',
              'variant_attributes':
                  line['variant_attributes'] as String? ?? '[]',
              'created_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    } catch (e) {
      // Non-fatal — order is already on Odoo server
      debugPrint('insertSyncedOrder error: $e');
    }
  }

  // ── MARK Order as Synced by Odoo Order ID ──────────────────────────────────
  // Used when paying a REMOTE pending order (isLocal=false).
  // Remote orders have widget.order.id == Odoo server ID, which does NOT match
  // the local SQLite auto-increment 'id'. We must look up by 'odoo_order_id'
  // to find the correct local row, then update payment_method on that row.
  // If no local row exists (order was never cached locally), we insert one.
  Future<int> markOrderAsSyncedByOdooId(
    int odooOrderId, {
    required String paymentMethod,
    required String orderName,
    required double amountTotal,
    required int sessionId,
  }) async {
    try {
      final db = await dbHelper.database;

      // Try to find the existing local row by odoo_order_id
      final existing = await db.query(
        'orders',
        columns: ['id'],
        where: 'odoo_order_id = ? AND session_id = ?',
        whereArgs: [odooOrderId, sessionId],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        // Row exists — update payment_method and status
        final localId = existing.first['id'] as int;
        return await db.update(
          'orders',
          {
            'synced': 1,
            'status': 'done',
            'payment_method': paymentMethod,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [localId],
        );
      } else {
        // No local row — insert a minimal one so the order shows correct method
        // after the server refresh (avoids Cash fallback in fromJson).
        await db.insert(
          'orders',
          {
            'odoo_order_id': odooOrderId,
            'name': orderName,
            'customer_name': 'Walk-in',
            'total': amountTotal,
            'status': 'done',
            'session_id': sessionId,
            'payment_method': paymentMethod,
            'synced': 1,
            'sync_attempts': 0,
            'created_at': DateTime.now().millisecondsSinceEpoch,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return 1;
      }
    } catch (e) {
      debugPrint('❌ markOrderAsSyncedByOdooId error: $e');
      return 0;
    }
  }

  // ── MARK Order as Synced ────────────────────
  // paymentMethod: the method the cashier actually used (Cash or Bank).
  // Pass this so the order card shows the correct method after payment.
  Future<int> markOrderAsSynced(
    int orderId, {
    String paymentMethod = 'Cash',
    int? odooOrderId,
  }) async {
    try {
      final db = await dbHelper.database;
      return await db.update(
        'orders',
        {
          'synced': 1,
          'status': 'done',
          'payment_method':
              paymentMethod, // Save actual method used at payment time
          if (odooOrderId != null && odooOrderId > 0)
            'odoo_order_id': odooOrderId,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── INCREMENT Sync Attempts ─────────────────
  Future<int> incrementSyncAttempts(int orderId) async {
    try {
      final db = await dbHelper.database;
      final order = await getOrderById(orderId);
      if (order == null) return 0;

      final attempts = (order['sync_attempts'] ?? 0) as int;
      return await db.update(
        'orders',
        {
          'sync_attempts': attempts + 1,
          'last_sync_attempt': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── DELETE Order ────────────────────────────
  Future<int> deleteOrder(int orderId) async {
    try {
      final db = await dbHelper.database;

      // Delete order lines first
      await db.delete(
        'order_lines',
        where: 'order_id = ?',
        whereArgs: [orderId],
      );

      // Delete order
      return await db.delete('orders', where: 'id = ?', whereArgs: [orderId]);
    } catch (e) {
      return 0;
    }
  }

  // ── CANCEL Offline Order ────────────────────────────────
  // Marks a locally saved draft order as 'cancel' by external_id.
  // ── UPDATE existing offline order (lines + header) ──────────────────────
  // Used when an editing-pending cart is put on hold (session switch) so the
  // original pending order is updated instead of a duplicate being created.
  //
  // Steps:
  //   1. Update header fields (total, tax, customer, note) on the orders row.
  //   2. Delete all old order_lines for this order.
  //   3. Insert the new lines from the current cart state.
  Future<bool> updateOfflineOrder({
    required int orderId,
    required List<Map<String, dynamic>> lines,
    required double total,
    required double taxAmount,
    required int customerId,
    String? customerName,
    String? customerNote,
    String? status,
    int synced = 0, // Default to 0 (unsynced) for draft updates
  }) async {
    try {
      final db = await dbHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      // 1. Update order header
      await db.update(
        'orders',
        {
          'total': total,
          'tax_amount': taxAmount,
          'customer_id': customerId,
          'customer_name': customerName ?? '',
          'customer_note': customerNote ?? '',
          if (status != null) 'status': status,
          'synced': synced,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );

      final orderRows = await db.query(
        'orders',
        columns: ['session_id'],
        where: 'id = ?',
        whereArgs: [orderId],
        limit: 1,
      );
      final lineSessionId = orderRows.isNotEmpty
          ? ((orderRows.first['session_id'] as int?) ?? 0)
          : 0;

      // 2. Delete old lines — they will be replaced with the current cart state
      await db
          .delete('order_lines', where: 'order_id = ?', whereArgs: [orderId]);

      // 3. Insert updated lines
      for (final line in lines) {
        final qty = (line['quantity'] as num?)?.toDouble() ?? 1.0;
        final price = (line['price'] as num?)?.toDouble() ?? 0.0;
        final taxRate = (line['tax_rate'] as num?)?.toDouble() ?? 0.0;
        final subtotal = qty * price;
        final subtotalIncl = subtotal * (1 + taxRate / 100);

        await db.insert('order_lines', {
          'order_id': orderId,
          'session_id': lineSessionId,
          'product_id': line['product_id'] ?? 0,
          'product_name': line['product_name'] ?? '',
          'quantity': qty.toInt(),
          'price': price,
          'price_unit': price,
          'tax_rate': taxRate,
          'note': line['note'] ?? '',
          'customer_note': line['customer_note'] ?? '',
          'image': line['image'] ?? '',
          'variant_attributes': line['variant_attributes'] ?? '{}',
          'price_subtotal': double.parse(subtotal.toStringAsFixed(2)),
          'price_subtotal_incl': double.parse(subtotalIncl.toStringAsFixed(2)),
          'created_at': now,
        });
      }

      debugPrint('✅ Updated offline order $orderId with ${lines.length} lines');
      return true;
    } catch (e) {
      debugPrint('❌ updateOfflineOrder error: $e');
      return false;
    }
  }

  Future<int> cancelOfflineOrder(String externalId) async {
    try {
      final db = await dbHelper.database;
      return await db.update(
        'orders',
        {
          'name':
              '/', // Assign "/" to cancelled orders so they don't break sequence parsing
          'status': 'cancel',
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'external_id = ?',
        whereArgs: [externalId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── GET Order Statistics ────────────────────
  Future<OrderStats> getOrderStats({int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      final sessionFilter = (sessionId != null && sessionId > 0)
          ? ' WHERE session_id = $sessionId'
          : '';
      final sessionFilterAnd = (sessionId != null && sessionId > 0)
          ? ' AND session_id = $sessionId'
          : '';

      final totalResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM orders$sessionFilter',
      );
      final total = Sqflite.firstIntValue(totalResult) ?? 0;

      final syncedResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM orders WHERE synced = 1$sessionFilterAnd',
      );
      final synced = Sqflite.firstIntValue(syncedResult) ?? 0;

      // Pending = paid offline orders waiting to sync (status='pending')
      final pendingResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM orders WHERE synced = 0 AND status = "pending"$sessionFilterAnd',
      );
      final pending = Sqflite.firstIntValue(pendingResult) ?? 0;

      final failedResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM orders WHERE status = "failed"$sessionFilterAnd',
      );
      final failed = Sqflite.firstIntValue(failedResult) ?? 0;

      return OrderStats(
        total: total,
        synced: synced,
        pending: pending,
        failed: failed,
      );
    } catch (e) {
      return OrderStats.empty();
    }
  }

  // ── CLEAR All Orders (dangerous) ────────────
  Future<void> clearAllOrders() async {
    try {
      final db = await dbHelper.database;
      await db.delete('order_lines');
      await db.delete('orders');
    } catch (e) {
      null;
    }
  }

  String _extractCustomerName(Map<String, dynamic> order) {
    final partner = order['partner_id'];

    if (partner is List && partner.length > 1) {
      return partner[1].toString();
    }

    return 'Walk-in';
  }

  Future<void> insertOrUpdateOrders(
    List<Map<String, dynamic>> orders, {
    required int currentSessionId,
  }) async {
    final db = await dbHelper.database;

    // ── Session isolation guard ──
    // Strictly require a valid session ID. Syncing orders without a session
    // selected leads to data mixing across POS terminals.
    if (currentSessionId <= 0) {
      debugPrint(
          '⚠️ insertOrUpdateOrders: currentSessionId is 0. Aborting sync to prevent order mixing.');
      return;
    }

    for (final order in orders) {
      final serverId = order['id'] as int?;
      if (serverId == null) continue;

      final serverState = order['state'] as String? ?? '';
      final serverExtId = order['external_pos_id'] as String? ?? '';
      final serverStatus = _mapServerStatus(serverState);

      // Extract partner ID from [id, name] tuple, direct number, or string
      final rawPartner = order['partner_id'];
      int serverCustomerId = 0;
      if (rawPartner is List && rawPartner.isNotEmpty) {
        serverCustomerId = (rawPartner[0] as num?)?.toInt() ?? 0;
      } else if (rawPartner is num) {
        serverCustomerId = rawPartner.toInt();
      } else if (rawPartner is String) {
        serverCustomerId = int.tryParse(rawPartner) ?? 0;
      }

      // Resolve server-side name, being careful not to blindly accept "Walk-in"
      // if the server might have failed to resolve partner_id string.
      final directName = order['customer_name'] as String?;
      final resolvedName = (directName != null &&
              directName.isNotEmpty &&
              directName != 'Walk-in')
          ? directName
          : _extractCustomerName(order);

      // ── Session guard: skip orders from other sessions ──
      final rawCompany = order['company_id'];
      final serverCompanyName = (rawCompany is List && rawCompany.length > 1)
          ? rawCompany[1].toString()
          : (rawCompany?.toString() ?? '');

      final rawSid = order['session_id'];
      var serverSessionId = (rawSid is List && rawSid.isNotEmpty)
          ? (int.tryParse(rawSid[0].toString()) ?? 0)
          : (int.tryParse(rawSid?.toString() ?? '0') ?? 0);

      // Fallback: if server returns 0, assume it belongs to current session
      // if we're inside a session-filtered fetch.
      if (serverSessionId == 0 && currentSessionId > 0) {
        serverSessionId = currentSessionId;
      }

      // CRITICAL: Reject any order that does not belong to the current session.
      if (serverSessionId != currentSessionId) {
        continue;
      }

      // Extract payment method from server response.
      final serverPaymentMethods = order['payment_methods'];

      final serverPaymentMethod =
          (serverPaymentMethods is List && serverPaymentMethods.isNotEmpty)
              ? serverPaymentMethods.first as String
              : null;

      // Check if local order already exists by Odoo ID
      final existingById = await db.query(
        'orders',
        columns: [
          'id',
          'synced',
          'status',
          'external_id',
          'odoo_order_id',
          'customer_name',
          'payment_method',
          'name',
          'session_id',
        ],
        where: 'odoo_order_id = ? AND session_id = ?',
        whereArgs: [serverId, currentSessionId],
        limit: 1,
      );

      if (existingById.isNotEmpty) {
        final row = existingById.first;
        final localId = row['id'] as int;
        final localName = row['customer_name'] as String?;
        final localStatus = row['status'] as String? ?? '';

        // Guard: never downgrade a locally-paid order back to draft.
        //
        // Scenario: cashier pays a pending draft → local row marked 'done'/'pending'.
        // Server refresh fires before Odoo finishes processing → server still
        // returns state='draft'. Without this guard, insertOrUpdateOrders would
        // overwrite status='done' with 'draft', making the order reappear as
        // pending (duplicate on the Orders screen).
        //
        // Rule 1: Never downgrade a locally-paid order ('done'/'pending') back to 'draft'.
        // Rule 2: Never overwrite a modified local draft (synced=0) with an older server version.

        final localIsPaid = localStatus == 'done' || localStatus == 'pending';
        final localIsDirtyDraft =
            localStatus == 'draft' && (row['synced'] as int? ?? 0) == 0;

        if (serverStatus == 'draft' && (localIsPaid || localIsDirtyDraft)) {
          debugPrint(
              '⏳ Skipping server update for dirty/paid local order $serverId to prevent data loss');
          continue;
        }

        final effectiveStatus = serverStatus;
        final effectiveSynced = 1;

        // ── Update local record with server data ──
        await db.update(
          'orders',
          {
            'name': order['name'] as String? ??
                row['name'], // ✅ Keep local name updated with server-computed name
            'customer_id': serverCustomerId,
            'synced': effectiveSynced,
            'status': effectiveStatus,
            // Always update payment method if server provides one,
            // otherwise keep local payment_method to preserve what the cashier selected.
            'payment_method': serverPaymentMethod ??
                (serverStatus == 'done'
                    ? row['payment_method'] ?? 'Paid'
                    : row['payment_method'] ?? 'Cash'),
            // Only update customer_name if server provides a real name,
            // OR if local record currently says "Walk-in".
            if (resolvedName != 'Walk-in' ||
                (localName == null || localName == 'Walk-in'))
              'customer_name': resolvedName,
            'company_name': serverCompanyName,
            'session_id': serverSessionId,
            'odoo_order_id': serverId,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [localId],
        );

        // Cache lines
        var serverLines = order['lines'];

        try {
          // If lines not included in order response, fetch them
          if (serverLines is! List || serverLines.isEmpty) {
            serverLines = await OdooService.fetchOrderLines(serverId,
                sessionId: currentSessionId);
          }

          if (serverLines is List && serverLines.isNotEmpty) {
            await saveOrderLines(
              localId,
              serverLines.cast<Map<String, dynamic>>(),
              sessionId: currentSessionId,
            );
          }
        } catch (e) {
          debugPrint('⚠️ Error updating order lines for $serverId: $e');
        }

        continue;
      }

      // ── Match by external_pos_id ──
      if (serverExtId.isNotEmpty) {
        final existingByExtId = await db.query(
          'orders',
          columns: [
            'id',
            'synced',
            'status',
            'customer_name',
            'payment_method',
            'name',
            'session_id',
          ],
          where: 'external_id = ? AND session_id = ?',
          whereArgs: [serverExtId, currentSessionId],
          limit: 1,
        );

        if (existingByExtId.isNotEmpty) {
          final row = existingByExtId.first;
          final localId = row['id'] as int;
          final localName = row['customer_name'] as String?;
          final localStatusExt = row['status'] as String? ?? '';

          final localIsPaidExt =
              localStatusExt == 'done' || localStatusExt == 'pending';
          final localIsDirtyDraftExt =
              localStatusExt == 'draft' && (row['synced'] as int? ?? 0) == 0;

          if (serverStatus == 'draft' &&
              (localIsPaidExt || localIsDirtyDraftExt)) {
            debugPrint(
                '⏳ Skipping server update (via Ext ID) for dirty/paid order $serverId');
            continue;
          }

          final effectiveStatusExt = serverStatus;
          final effectiveSyncedExt = 1;

          // Found a match via UUID — link it to the Odoo ID and mark as synced.
          // This prevents duplicate entries in the Orders screen.
          await db.update(
            'orders',
            {
              'name': order['name'] as String? ??
                  row['name'], // ✅ Keep local name updated with server-computed name
              'customer_id': serverCustomerId,
              'synced': effectiveSyncedExt,
              'status': effectiveStatusExt,
              'odoo_order_id': serverId,
              // Keep local payment_method when server has not confirmed payment yet
              'payment_method': serverPaymentMethod ??
                  (serverStatus == 'done'
                      ? row['payment_method'] ?? 'Paid'
                      : row['payment_method'] ?? 'Cash'),
              // Only update customer_name if server provides a real name,
              // OR if local record currently says "Walk-in".
              if (resolvedName != 'Walk-in' ||
                  (localName == null || localName == 'Walk-in'))
                'customer_name': resolvedName,
              'company_name': serverCompanyName,
              'session_id': serverSessionId,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'id = ?',
            whereArgs: [localId],
          );

          // Cache lines
          var serverLines = order['lines'];

          try {
            // If lines not included in order response, fetch them
            if (serverLines is! List || serverLines.isEmpty) {
              serverLines = await OdooService.fetchOrderLines(serverId,
                  sessionId: currentSessionId);
            }

            if (serverLines is List && serverLines.isNotEmpty) {
              await saveOrderLines(
                localId,
                serverLines.cast<Map<String, dynamic>>(),
                sessionId: currentSessionId,
              );
            }
          } catch (e) {
            debugPrint('⚠️ Error updating order lines for $serverId: $e');
          }

          continue;
        }
      }

      final newLocalId = await db.insert(
        'orders',
        {
          'name': order['name'] as String? ??
              'ORDER-${order['id']}', // Ensure name is always present
          'odoo_order_id': serverId,
          'customer_id': serverCustomerId,
          'customer_name': resolvedName,
          'total': (order['amount_total'] ?? 0).toDouble(),
          'company_name': serverCompanyName,
          'status': serverStatus,
          'session_id': serverSessionId,
          // Use 'Paid' instead of 'Cash' as fallback for server orders if no method provided.
          // This prevents misleading the user when an order was paid in the backend.
          'payment_method':
              serverPaymentMethod ?? (serverStatus == 'done' ? 'Paid' : 'Cash'),
          'created_at': DateTime.tryParse(
                order['date_order'] ?? '',
              )?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          // FIX: draft orders stay synced=0 so they appear in pending count.
          // Only paid/done orders are marked synced=1.
          'synced': serverStatus == 'done' ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // ── Cache lines ──
      // CRITICAL: Always fetch fresh lines from API to ensure product names are included
      // Server's GET /orders might not return full line details
      var serverLines = order['lines'];

      try {
        // If lines not included in order response, fetch them
        if (serverLines is! List || serverLines.isEmpty) {
          debugPrint('📥 Fetching line details for new order $serverId...');
          serverLines = await OdooService.fetchOrderLines(serverId,
              sessionId: currentSessionId);
        }

        if (serverLines.isNotEmpty) {
          // Ensure product_name is present in each line
          final enrichedLines =
              (serverLines.cast<Map<String, dynamic>>()).map((line) {
            // If product_name is missing, try to extract from name or product_id tuple
            if ((line['product_name'] as String?)?.isEmpty ?? true) {
              final rawPid = line['product_id'];

              if (line['name'] is String &&
                  (line['name'] as String).isNotEmpty) {
                line['product_name'] = line['name'];
              } else if (rawPid is List && rawPid.length > 1) {
                line['product_name'] = rawPid[1].toString();
              } else {
                line['product_name'] = 'Product ${line['product_id'] ?? '?'}';
              }
            }
            return line;
          }).toList();

          await saveOrderLines(newLocalId, enrichedLines,
              sessionId: currentSessionId);

          debugPrint(
            '✅ Cached ${enrichedLines.length} lines for order '
            '$serverId (local $newLocalId) with product names',
          );
        }
      } catch (e) {
        debugPrint('⚠️ Error caching order lines: $e');
      }
    }
  }

  String _mapServerStatus(String? state) {
    switch (state) {
      case 'paid':
      case 'done':
      case 'invoiced': // Orders paid from Odoo backend
        return 'done';
      case 'cancel':
        return 'cancel';
      case 'new': // Orders created from Odoo backend, not yet paid
        return 'draft';
      default:
        return 'draft';
    }
  }
}

// ─────────────────────────────────────────────────────
// ORDER STATISTICS MODEL
// ─────────────────────────────────────────────────────
class OrderStats {
  final int total;
  final int synced;
  final int pending;
  final int failed;

  OrderStats({
    required this.total,
    required this.synced,
    required this.pending,
    required this.failed,
  });

  factory OrderStats.empty() =>
      OrderStats(total: 0, synced: 0, pending: 0, failed: 0);

  int get remaining => pending + failed;
}
