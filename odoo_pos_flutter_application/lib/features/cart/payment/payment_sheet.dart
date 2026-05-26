import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../widgets/top_notification.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../../../data/repositories/order_repository.dart';
import '../../../features/orders/data/order_line_repository.dart';
import '../../../services/app_config.dart';
import '../../../services/cart_service.dart';
import '../../../services/db_helper.dart';
import '../cart_theme.dart';

// ─────────────────────────────────────────────────
// PAYMENT SHEET — Calls /api/order (with offline fallback)
// ─────────────────────────────────────────────────
class PaymentSheet extends StatefulWidget {
  const PaymentSheet({super.key});

  @override
  State<PaymentSheet> createState() => PaymentSheetState();
}

class PaymentSheetState extends State<PaymentSheet> {
  String _method = 'Cash'; // 'Cash' or 'Bank'
  bool _loading = false;
  String _error = '';
  bool _success = false;

  // Hold Order state — used when user taps "Hold Order" instead of paying
  bool _holdLoading = false;
  String _holdError = '';

  // ────────────────────────────────────────────────────
  // HOLD ORDER — saves cart as draft pending in Odoo
  // No payment is taken. Order appears in Orders > Pending tab.
  // If offline, saves to local SQLite with status='draft'.
  // User pays later from the Pending tab via /api/order/<id>/pay.
  // ────────────────────────────────────────────────────
  Future<void> _holdOrder() async {
    setState(() {
      _holdLoading = true;
      _holdError = '';
    });

    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();
      final deviceCode = await AppConfig.getDeviceCode();
      final cart = CartService.instance;
      final sessionId = await AppConfig.getPosSessionId();

      if (deviceCode.isEmpty) {
        setState(() {
          _holdError = 'Device code not set. Go to Settings.';
          _holdLoading = false;
        });
        return;
      }

      // Unique ID for this hold order — used for idempotency on Odoo side
      final externalId = cart.editingPendingExternalId ?? const Uuid().v4();

      // Build order lines payload from current cart (no payments — hold only)
      final lines = [
        ...cart.cart.values.map((item) => {
              'product_id': item.productId,
              'qty': item.qty,
              'price': item.price,
              'tax_rate': item.taxRate,
              if (item.note.isNotEmpty) 'note': item.note,
              if (item.customerNote.isNotEmpty)
                'customer_note': item.customerNote,
              'product_name': item.name, // Explicitly include product name
              'image': item.image, // Explicitly include product image
            }),
        ...cart.comboCart.values
            .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
      ];

      // Check server connectivity before attempting network call
      bool isOnline = false;
      if (baseUrl.isNotEmpty) {
        try {
          final healthCheck = await http
              .get(Uri.parse('$baseUrl/web/health'))
              .timeout(const Duration(seconds: 5));
          isOnline = healthCheck.statusCode == 200;
        } catch (_) {
          isOnline = false;
        }
      }

      if (!isOnline) {
        // Offline — save to local SQLite as draft
        // sync_manager will NOT auto-sync drafts (only status='pending' = paid offline)
        // User must manually pay this from Orders > Pending tab when back online
        final orderRepo = OrderRepository();
        final customerId = cart.customerNotifier.value?.id ?? 0;
        final customerName = cart.customerNotifier.value?.name ?? 'Walk-in';

        final localLines = [
          ...cart.cart.values.map((item) => {
                'product_id': item.productId,
                'quantity': item.qty,
                'price': item.price,
                'tax_rate': item.taxRate,
                'note': item.note,
                'customer_note': item.customerNote,
                'image': item.image,
                'product_name': item.name,
                'variant_attributes': jsonEncode(item.variantAttributes),
              }),
          ...cart.comboCart.values
              .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
        ];

        // If the user restored an existing order via "Add back to cart" and is
        // now holding it again, UPDATE the existing local row instead of creating
        // a new one. Without this, the old row stays (pending/cancel) and a new
        // draft row is also created — resulting in 2 records for the same order.
        if (cart.editingPendingLocalId != null) {
          await orderRepo.updateOfflineOrder(
            orderId: cart.editingPendingLocalId!,
            lines: localLines,
            total: cart.total,
            taxAmount: cart.taxAmount,
            customerId: customerId,
            customerName: customerName,
            customerNote: cart.customerNoteNotifier.value,
            synced: 0, // Stay unsynced in local DB as we are offline
          );

          debugPrint(
            '✅ Re-held existing order (local id=${cart.editingPendingLocalId}) '
            'updated to draft in local DB',
          );
        } else {
          await orderRepo.createOfflineOrder(
            externalId: externalId,
            deviceCode: deviceCode,
            customerId: customerId,
            customerName: customerName,
            customerNote: cart.customerNoteNotifier.value,
            sessionId: sessionId,
            lines: localLines,
            total: cart.total,
            taxAmount: cart.taxAmount,
            // 'draft' = hold order (not yet paid)
            // Different from 'pending' which = paid offline order waiting to sync
            status: 'draft',
          );
        }
      } else {
        // Online — hold/update the order on Odoo server.
        //
        // TWO STRATEGIES depending on whether we are editing an existing order:
        //
        // Strategy A — Odoo-backend order (state='new', editingPendingOdooOrderId set,
        //   editingPendingExternalId is null): These orders have no external_pos_id.
        //   Call POST /api/order/<id>/draft to update the existing Odoo record in place.
        //   Using /api/order/draft here would generate a new UUID and create a duplicate.
        //
        // Strategy B — Flutter-created draft (editingPendingExternalId set) or new cart:
        //   Call POST /api/order/draft with external_id for upsert (idempotent).

        final editingOdooId = cart.editingPendingOdooOrderId;
        final hasOdooId = editingOdooId != null && editingOdooId > 0;
        final hasExternalId = cart.editingPendingExternalId != null &&
            cart.editingPendingExternalId!.isNotEmpty;

        int? serverOrderId;
        if (hasOdooId && !hasExternalId) {
          // Strategy A: Update existing Odoo-backend order by its server ID
          final updatePayload = {
            'device_code': deviceCode,
            'session_id': sessionId,
            if (cart.customerNotifier.value != null)
              'customer_id': cart.customerNotifier.value!.id,
            if (cart.customerNoteNotifier.value.isNotEmpty)
              'customer_note': cart.customerNoteNotifier.value,
            'lines': lines,
          };

          final response = await http
              .post(
                Uri.parse('$baseUrl/api/order/$editingOdooId/draft'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode(updatePayload),
              )
              .timeout(const Duration(seconds: 20));

          final data = jsonDecode(response.body);
          if (data['status'] != 'success') {
            throw Exception(
                data['message'] ?? 'Failed to hold order. Please try again.');
          }
          serverOrderId = data['data']?['order_id'] as int?;
          debugPrint(
              '✅ Updated Odoo-backend order $editingOdooId to draft via /api/order/$editingOdooId/draft');
        } else {
          // Strategy B: Create or update draft using external_id (upsert)
          final payload = {
            'external_id': externalId,
            'session_id': sessionId,
            'device_code': deviceCode,
            if (cart.customerNotifier.value != null)
              'customer_id': cart.customerNotifier.value!.id,
            if (cart.customerNoteNotifier.value.isNotEmpty)
              'customer_note': cart.customerNoteNotifier.value,
            'lines': lines,
          };

          final response = await http
              .post(
                Uri.parse('$baseUrl/api/order/draft'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 20));

          final data = jsonDecode(response.body);
          if (data['status'] != 'success') {
            throw Exception(
                data['message'] ?? 'Failed to hold order. Please try again.');
          }
          serverOrderId = data['data']?['order_id'] as int?;
        }

        // Update local row to 'draft' so Orders screen reflects latest state
        // without a duplicate entry appearing in the pending list.
        if (cart.editingPendingLocalId != null) {
          final customerId = cart.customerNotifier.value?.id ?? 0;
          final customerName = cart.customerNotifier.value?.name ?? 'Walk-in';

          final localLines = [
            ...cart.cart.values.map((item) => {
                  'product_id': item.productId,
                  'quantity': item.qty,
                  'price': item.price,
                  'tax_rate': item.taxRate,
                  'note': item.note,
                  'customer_note': item.customerNote,
                  'image': item.image,
                  'product_name': item.name,
                  'variant_attributes': jsonEncode(item.variantAttributes),
                }),
            ...cart.comboCart.values
                .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
          ];

          await OrderRepository().updateOfflineOrder(
            orderId: cart.editingPendingLocalId!,
            lines: localLines,
            total: cart.total,
            taxAmount: cart.taxAmount,
            customerId: customerId,
            customerName: customerName,
            customerNote: cart.customerNoteNotifier.value,
            synced: 1, // Mark as synced because the API call just succeeded
          );

          if (serverOrderId != null && serverOrderId > 0) {
            await OrderRepository().saveDraftOdooOrderId(
                cart.editingPendingLocalId!, serverOrderId);
          }

          debugPrint(
            '✅ Re-held existing order (local id=${cart.editingPendingLocalId}) '
            'updated to draft after online API success',
          );
        }
      }

      // Clear cart — order is now held in Odoo or local SQLite
      cart.clearEditingPendingState();
      cart.clearCart();

      // Trigger orders screen refresh so new pending order appears in Pending tab
      orderPlacedNotifier.value++;

      if (mounted) {
        Navigator.of(context).pop(); // Close payment sheet

        showTopNotification(
          context,
          'Order held. Find it in Orders › Pending.',
          color: CartTheme.purple,
          icon: Icons.pause_circle_rounded,
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _holdError = e.toString().replaceFirst('Exception: ', '');
          _holdLoading = false;
        });
      }
    }
  }

  // ────────────────────────────────────────────────────
  // PLACE ORDER — WITH OFFLINE FALLBACK
  // ────────────────────────────────────────────────────
  Future<void> _placeOrder() async {
    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();
      final deviceCode = await AppConfig.getDeviceCode();
      final cart = CartService.instance;
      final sessionId = await AppConfig.getPosSessionId();
      // Fetch company name saved at session-select time — used for offline receipt header
      final companyName = await AppConfig.getCompanyName();

      if (deviceCode.isEmpty) {
        setState(() {
          _error = 'Device code not set. Go to Settings.';
          _loading = false;
        });
        return;
      }

      final externalId = cart.editingPendingExternalId ?? const Uuid().v4();
      final total = cart.total;

      final payload = {
        'external_id': externalId,
        'device_code': deviceCode,

        // ✅ NEW: session
        'session_id': sessionId,

        if (cart.customerNotifier.value != null)
          'customer_id': cart.customerNotifier.value!.id,

        // Include order-level customer note if provided
        if (cart.customerNoteNotifier.value.isNotEmpty)
          'customer_note': cart.customerNoteNotifier.value,

        'lines': [
          // Regular cart items — include per-product note if set
          ...cart.cart.values.map((item) => {
                'product_id': item.productId,
                'qty': item.qty,
                'price': item.price,
                // Use each item's own taxRate — not the cart-level average.
                // Ensures correct tax per product even if items have different rates.
                'tax_rate': item.taxRate,
                if (item.note.isNotEmpty) 'note': item.note,
                if (item.customerNote.isNotEmpty)
                  'customer_note': item.customerNote,
              }),
          // Combo items (flattened to multiple lines)
          ...cart.comboCart.values
              .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
        ],

        'payments': [
          {'method': _method, 'amount': total}
        ],
      };

      // ─────────────────────────────────────────────
      // CHECK CONNECTIVITY BEFORE ATTEMPTING ONLINE
      // ─────────────────────────────────────────────
      bool isOnline = false;
      if (baseUrl.isNotEmpty) {
        try {
          final healthCheck = await http
              .get(Uri.parse('$baseUrl/web/health'))
              .timeout(const Duration(seconds: 5));
          isOnline = healthCheck.statusCode == 200;
        } catch (_) {
          isOnline = false;
        }
      }

      // If offline or no server URL — save directly to local DB, skip network call
      if (!isOnline) {
        debugPrint(
            '📱 Offline detected — saving order directly to local DB...');
        try {
          final orderRepo = OrderRepository();
          final customerId = cart.customerNotifier.value?.id ?? 0;
          final customerName = cart.customerNotifier.value?.name ?? 'Walk-in';

          final lines = [
            ...cart.cart.values.map((item) => {
                  'product_id': item.productId,
                  'quantity': item.qty,
                  'price': item.price,
                  // Use each item's own taxRate — not the cart-level average.
                  // Ensures correct tax per product even if items have different rates.
                  'tax_rate': item.taxRate,
                  'note': item.note,
                  'customer_note':
                      item.customerNote, // Include per-item customer note
                  // Pass product image so it is saved in order_lines and shown
                  // in Order History item detail popup for offline orders.
                  'image': item.image,
                  // Save product name so Order History list can display it correctly
                  'product_name': item.name,
                  // Save variant attribute pairs as JSON for Order History detail chips
                  'variant_attributes': jsonEncode(item.variantAttributes),
                }),
            ...cart.comboCart.values
                .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
          ];

          int orderId;

          // If we are paying a pending draft order that was restored via Add to Cart,
          // UPDATE the existing local row instead of creating a new one.
          // This prevents a duplicate: the old draft staying as 'pending' while
          // a new 'pending' row is also created for the same sale.
          if (cart.editingPendingLocalId != null) {
            final db = await DatabaseHelper().database;
            final now = DateTime.now().millisecondsSinceEpoch;

            // Update the existing draft row: mark as 'pending' (paid, waiting sync),
            // save the chosen payment method, and replace the order lines with the
            // (possibly modified) cart contents.
            await db.update(
              'orders',
              {
                'status': 'pending',
                'payment_method': _method,
                'customer_id': customerId,
                'customer_name': customerName,
                'customer_note': cart.customerNoteNotifier.value,
                'total': cart.total,
                'tax_amount': cart.taxAmount,
                'synced': 0,
                'company_name': companyName,
                'updated_at': now,
              },
              where: 'id = ?',
              whereArgs: [cart.editingPendingLocalId],
            );

            // Replace old lines with updated cart lines
            await db.delete(
              'order_lines',
              where: 'order_id = ?',
              whereArgs: [cart.editingPendingLocalId!],
            );
            await OrderLineRepository().insertLinesForOrder(
              orderId: cart.editingPendingLocalId!,
              lines: lines,
              createdAt: now,
              sessionId: sessionId,
            );

            orderId = cart.editingPendingLocalId!;
            debugPrint(
              '✅ Updated existing pending draft (local id=$orderId) to paid/pending sync',
            );
          } else {
            // Normal path: no pending draft being edited — create a new offline order.
            orderId = await orderRepo.createOfflineOrder(
              externalId: externalId,
              deviceCode: deviceCode,
              customerId: customerId,
              customerName: customerName,
              customerNote: cart.customerNoteNotifier.value,
              sessionId: sessionId,
              lines: lines,
              total: cart.total,
              taxAmount: cart.taxAmount,
              // 'pending' = paid offline order, ready to sync when server is back online
              status: 'pending',
              companyName: companyName,
              // Save selected payment method so sync sends correct method to Odoo
              paymentMethod: _method,
            );
          }

          if (orderId > 0) {
            cart.clearCart();
            orderPlacedNotifier.value++;
            if (mounted) {
              setState(() {
                _success = true;
                _loading = false;
              });
              showTopNotification(
                context,
                '📱 Order saved offline. Will sync when online.',
                color: Colors.blue[700]!,
                icon: Icons.wifi_off_rounded,
              );
            }
          } else {
            if (mounted) {
              setState(() {
                _error = 'Failed to save order offline. Please try again.';
                _loading = false;
              });
            }
          }
        } catch (offlineError) {
          if (mounted) {
            setState(() {
              _error = 'Could not save order offline. Please try again.';
              _loading = false;
            });
          }
          debugPrint('❌ Offline save failed: $offlineError');
        }
        return; // Done — no need to attempt online
      }

      // ─────────────────────────────────────────────
      // ONLINE: TRY SERVER
      // ─────────────────────────────────────────────
      //
      // TWO PATHS depending on whether we are paying a server-synced draft:
      //
      // PATH A — Server-synced draft (editingPendingOdooOrderId > 0):
      //   The order already exists in Odoo as state='draft' (either created
      //   from the Odoo backend or from another device). We call
      //   POST /api/order/<id>/pay to pay it IN PLACE.
      //   Using /api/order here would fail the external_id match and create
      //   a NEW order — causing 2 entries (old draft + new paid) in both
      //   Odoo and the orders screen.
      //
      // PATH B — Local-only draft or new order (editingPendingOdooOrderId is null):
      //   Order is either brand-new or was saved locally only (odoo_order_id=0).
      //   Use the existing /api/order flow which handles external_id matching
      //   and idempotency for local drafts.
      try {
        final odooOrderId = cart.editingPendingOdooOrderId;
        final bool isServerSyncedDraft = odooOrderId != null && odooOrderId > 0;

        http.Response response;

        if (isServerSyncedDraft) {
          // PATH A: Pay an existing Odoo draft order using its server ID.
          // Only send payment info — lines are already on the server.
          // The backend will attach payments and call action_pos_order_paid().
          debugPrint(
            '📤 Paying server-synced draft order (odoo_order_id=$odooOrderId) '
            'via POST /api/order/$odooOrderId/pay',
          );

          final payPayload = {
            'device_code': deviceCode,
            'session_id': sessionId,
            // Send current cart lines so the server updates the order before paying.
            // Without this, Odoo keeps the OLD draft lines and the newly added
            // items never appear in the backend or on the receipt.
            'lines': [
              ...cart.cart.values.map((item) => {
                    'product_id': item.productId,
                    'qty': item.qty,
                    'price': item.price,
                    'tax_rate': item.taxRate,
                    if (item.note.isNotEmpty) 'note': item.note,
                    if (item.customerNote.isNotEmpty)
                      'customer_note': item.customerNote,
                  }),
              ...cart.comboCart.values
                  .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
            ],
            'payments': [
              {'method': _method, 'amount': total}
            ],
          };

          response = await http
              .post(
                Uri.parse('$baseUrl/api/order/$odooOrderId/pay'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode(payPayload),
              )
              .timeout(const Duration(seconds: 20));
        } else {
          // PATH B: Normal flow — new order or local draft with external_id match.
          debugPrint('📤 Placing order via POST /api/order');
          response = await http
              .post(
                Uri.parse('$baseUrl/api/order'),
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
              'Server returned an unexpected response (HTTP ${response.statusCode}).');
        }

        final data = jsonDecode(response.body);

        if (data['status'] == 'success') {
          debugPrint('✅ Server response data: ${jsonEncode(data)}');
          // Update local SQLite to reflect the paid state immediately.
          try {
            final odooOrderId = data['data']?['order_id'] as int? ?? 0;
            final orderRepo = OrderRepository();

            // CASE 1: We were editing a local pending draft order (Add to Cart flow).
            // editingPendingLocalId is the SQLite row id of that draft.
            // We must update THAT specific row to 'done' instead of inserting a new row.
            // Without this fix, the old draft stays as 'pending' and a new 'done' row
            // is inserted — resulting in 2 orders (one pending, one synced) for the same sale.
            if (cart.editingPendingLocalId != null) {
              await orderRepo.markOrderAsSynced(
                cart.editingPendingLocalId!,
                paymentMethod: _method,
                odooOrderId: odooOrderId > 0 ? odooOrderId : null,
              );

              // Update order lines in local DB with the current cart items.
              // When user adds/removes items before payment, the local DB still has
              // the OLD lines from when the pending order was originally created.
              // Without this update, order detail sheet shows stale items even
              // after payment succeeds — user sees the old pending items, not what
              // was actually paid.
              final updatedLines = [
                ...cart.cart.values.map((item) => {
                      'product_id': item.productId,
                      'product_name': item.name,
                      'quantity': item.qty,
                      'price': item.price,
                      'tax_rate': item.taxRate,
                      'note': item.note,
                      'customer_note': item.customerNote,
                      'image': item.image,
                      'variant_attributes': jsonEncode(item.variantAttributes),
                    }),
                ...cart.comboCart.values.expand(
                    (combo) => combo.toOrderLines(taxRate: cart.taxRate)),
              ];

              if (updatedLines.isNotEmpty) {
                // Replace old lines with the items that were actually paid
                await orderRepo.updateOfflineOrder(
                  orderId: cart.editingPendingLocalId!,
                  lines: updatedLines,
                  total: total,
                  taxAmount: cart.taxAmount,
                  customerId: cart.customerNotifier.value?.id ?? 0,
                  customerName: cart.customerNotifier.value?.name,
                  customerNote: cart.customerNoteNotifier.value,
                  synced: 1, // Fix: Ensure it stays synced after payment
                );
                debugPrint(
                  '✅ Updated order lines for local id=${cart.editingPendingLocalId} '
                  '— ${updatedLines.length} line(s) saved after payment',
                );
              }

              debugPrint(
                '✅ Updated existing pending draft (local id=${cart.editingPendingLocalId}) '
                'to done with odoo_order_id=$odooOrderId',
              );
            } else if (odooOrderId > 0) {
              // CASE 2: Normal new order (not editing a pending draft).
              // Try to find and update the local row by Odoo ID.
              // If no local row exists, insert a minimal one so the order
              // immediately shows the correct payment method.
              await orderRepo.markOrderAsSyncedByOdooId(
                odooOrderId,
                paymentMethod: _method,
                orderName: 'ORDER-$odooOrderId',
                amountTotal: total,
                sessionId: sessionId,
              );
            }
          } catch (saveErr) {
            // Non-fatal — order is already confirmed on Odoo server
            debugPrint('⚠️ Could not save order locally: $saveErr');
          }

          cart.clearCart();
          cart.clearEditingPendingState();
          // Notify OrdersScreen to reload — user won't need to manually refresh
          orderPlacedNotifier.value++;
          if (mounted) {
            setState(() {
              _success = true;
              _loading = false;
            });
          }
          return; // ← Success! Exit here
        } else {
          if (mounted) {
            setState(() {
              _error = data['message'] ?? 'Order failed';
              _loading = false;
            });
          }
          return;
        }
      } catch (onlineError) {
        // ─────────────────────────────────────────────
        // SERVER DOWN → SAVE OFFLINE
        // ─────────────────────────────────────────────
        debugPrint('⚠️ Online order failed: $onlineError');
        debugPrint('📱 Attempting to save order offline...');

        try {
          final orderRepo = OrderRepository();
          final customerId = cart.customerNotifier.value?.id ?? 0;
          final customerName = cart.customerNotifier.value?.name ?? 'Walk-in';

          // Convert cart items to order lines — include per-product note and customer_note
          final lines = [
            // Regular cart items
            ...cart.cart.values.map((item) => {
                  'product_id': item.productId,
                  'quantity': item.qty,
                  'price': item.price,
                  // Use each item's own taxRate — not the cart-level average.
                  // Ensures correct tax per product even if items have different rates.
                  'tax_rate': item.taxRate,
                  'note':
                      item.note, // Save per-product kitchen note offline too
                  'customer_note': item
                      .customerNote, // Save per-product customer note offline too
                  'image':
                      item.image, // Save product image for Order History popup
                  // Save product name so Order History list can display it correctly
                  'product_name': item.name,
                  // Save variant attribute pairs as JSON for Order History detail chips
                  'variant_attributes': jsonEncode(item.variantAttributes),
                }),
            // Combo items (flattened to multiple lines)
            ...cart.comboCart.values
                .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
          ];

          // FIX: fetch active session id so the order is linked to the correct POS session.
          // Without this, sync status counts on settings screen cannot filter by session.
          final sessionId = await AppConfig.getPosSessionId();
          final fallbackCompanyName = await AppConfig.getCompanyName();

          int orderId;

          // If we are paying a pending draft order that was restored via Add to Cart,
          // UPDATE the existing local row to 'pending' (paid, waiting sync) instead of
          // creating a new row. This prevents 2 orders appearing for the same sale.
          if (cart.editingPendingLocalId != null) {
            final db = await DatabaseHelper().database;
            final now = DateTime.now().millisecondsSinceEpoch;

            await db.update(
              'orders',
              {
                'status': 'pending',
                'payment_method': _method,
                'customer_id': customerId,
                'customer_name': customerName,
                'customer_note': cart.customerNoteNotifier.value,
                'total': cart.total,
                'tax_amount': cart.taxAmount,
                'synced': 0,
                'company_name': fallbackCompanyName,
                'updated_at': now,
              },
              where: 'id = ?',
              whereArgs: [cart.editingPendingLocalId],
            );

            // Replace old lines with updated cart lines
            await db.delete(
              'order_lines',
              where: 'order_id = ?',
              whereArgs: [cart.editingPendingLocalId!],
            );
            await OrderLineRepository().insertLinesForOrder(
              orderId: cart.editingPendingLocalId!,
              lines: lines,
              createdAt: now,
              sessionId: sessionId,
            );

            orderId = cart.editingPendingLocalId!;
            debugPrint(
              '✅ Updated existing pending draft (local id=$orderId) to pending sync (server was down)',
            );
          } else {
            // Normal path: create a new offline order.
            // Save to SQLite — status 'pending' so sync_manager picks it up when server is back
            orderId = await orderRepo.createOfflineOrder(
              externalId: externalId,
              deviceCode: deviceCode,
              customerId: customerId,
              customerName: customerName,
              customerNote: cart.customerNoteNotifier.value,
              sessionId: sessionId,
              lines: lines,
              total: cart.total,
              taxAmount: cart.taxAmount,
              // 'pending' = paid offline order ready to sync (not a draft session-switch save)
              status: 'pending',
              // Save actual payment method so Odoo receives correct method on sync
              paymentMethod: _method,
              // Save company name so receipt shows correct header even when offline
              companyName: fallbackCompanyName,
            );
          }

          if (orderId > 0) {
            // ✅ Offline save successful
            cart.clearCart();
            cart.clearEditingPendingState();
            // Notify OrdersScreen to reload — user won't need to manually refresh
            orderPlacedNotifier.value++;
            if (mounted) {
              setState(() {
                _success = true;
                _loading = false;
              });
            }

            debugPrint('✅ Order saved offline with ID: $orderId');

            // Show offline confirmation
            if (mounted) {
              showTopNotification(
                context,
                '📱 Order saved offline. Will sync when online.',
                color: Colors.blue[700]!,
                icon: Icons.wifi_off_rounded,
              );
            }
          } else {
            // ❌ Offline save failed
            if (mounted) {
              setState(() {
                _error = 'Failed to save order. Please try again.';
                _loading = false;
              });
            }
          }
        } catch (offlineError) {
          // ❌ Both online and offline failed
          if (mounted) {
            setState(() {
              _error =
                  'No connection. Could not save order offline. Please try again.';
              _loading = false;
            });
          }
          debugPrint('❌ Offline save also failed: $offlineError');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_success) return _buildSuccessView(context);

    final cart = CartService.instance;
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: CartTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Select Payment Method',
              style: TextStyle(
                  color: CartTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),

          // Payment options
          _paymentOption('Cash', Icons.payments_outlined),
          const SizedBox(height: 10),
          _paymentOption('Bank', Icons.credit_card_outlined),

          const SizedBox(height: 24),

          // Total summary
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: CartTheme.inputBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Text('Total to Pay',
                    style: TextStyle(
                        color: CartTheme.textSecondary, fontSize: 14)),
                const Spacer(),
                Text(
                  '₹${cart.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: CartTheme.purpleLight,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: CartTheme.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CartTheme.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: CartTheme.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error,
                        style: const TextStyle(
                            color: CartTheme.red, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Hold order error message — shown when hold fails
          if (_holdError.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: CartTheme.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CartTheme.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: CartTheme.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_holdError,
                        style: const TextStyle(
                            color: CartTheme.red, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],

          // Hold Order button — saves cart as pending without payment
          // Disabled while place order OR hold order is loading
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_loading || _holdLoading) ? null : _holdOrder,
              icon: _holdLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: CartTheme.purple))
                  : const Icon(Icons.pause_circle_outline_rounded,
                      color: CartTheme.purple, size: 20),
              label: Text(
                _holdLoading ? 'Saving...' : 'Hold Order',
                style: const TextStyle(
                  color: CartTheme.purple,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                side: const BorderSide(color: CartTheme.purple, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 8),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _placeOrder,
              style: ElevatedButton.styleFrom(
                backgroundColor: CartTheme.green,
                disabledBackgroundColor: CartTheme.green.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5))
                  : const Text(
                      'Confirm & Place Order',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _paymentOption(String label, IconData icon) {
    final selected = _method == label;
    return GestureDetector(
      onTap: () => setState(() => _method = label),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? CartTheme.purple.withValues(alpha: 0.15)
              : CartTheme.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? CartTheme.purple : CartTheme.cardBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color:
                    selected ? CartTheme.purpleLight : CartTheme.textSecondary,
                size: 22),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color:
                    selected ? CartTheme.textPrimary : CartTheme.textSecondary,
                fontSize: 15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            const Spacer(),
            if (selected)
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                    color: CartTheme.purple, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessView(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: CartTheme.green.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_outline_rounded,
                color: CartTheme.green, size: 40),
          ),
          const SizedBox(height: 20),
          const Text('Order Placed!',
              style: TextStyle(
                  color: CartTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('Order has been sent to Odoo successfully.',
              style: TextStyle(color: CartTheme.textSecondary, fontSize: 14),
              textAlign: TextAlign.center),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: CartTheme.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('Done',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
