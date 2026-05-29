import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:odocart/services/db_helper.dart';
import 'package:odocart/widgets/top_notification.dart';
import 'package:odocart/data/repositories/order_repository.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../../../services/app_config.dart';
import '../../../services/cart_service.dart';
import '../cart_theme.dart';
import '../customer/customer_search_sheet.dart';
import 'split_models.dart';

class SplitFlowSheet extends StatefulWidget {
  const SplitFlowSheet({super.key});

  @override
  State<SplitFlowSheet> createState() => SplitFlowSheetState();
}

// ─────────────────────────────────────────────────────────────────────────────
// SplitFlowSheetState
// ─────────────────────────────────────────────────────────────────────────────
class SplitFlowSheetState extends State<SplitFlowSheet> {
  // One UUID shared by ALL sub-orders in this split session.
  // Generated once when the sheet opens.
  final String _splitGroupId = const Uuid().v4();

  // 1-based person counter. Increments after each person pays.
  int _currentPersonIndex = 1;

  // Controls which screen is visible (step machine).
  SplitStep _step = SplitStep.selectItems;

  // Full list of remaining items across the whole split.
  // Initialised from CartService. remainingQty decrements as persons pay.
  late List<SplitRemainingItem> _remainingItems;

  // This person's chosen qty for each item key.
  // Cleared and reset to 0 for every new person.
  final Map<String, int> _selectedQty = {};

  // Optional customer selected for the current person (Walk-in if null).
  Map<String, dynamic>? _selectedCustomer;

  // Payment method for the current person ('Cash' or 'Bank').
  String _paymentMethod = 'Cash';

  // API call state — shown on the payment screen.
  bool _loading = false;
  String _error = '';

  // Stored after a successful payment — displayed on personDone screen.
  double _lastPersonAmount = 0;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _buildRemainingItems(); // snapshot cart into _remainingItems
    _initPersonQty(); // set all selected qtys to 0
  }

  // ─────────────────────────────────────────────────────────────────────────
  // _buildRemainingItems
  // Takes a snapshot of the current CartService state and converts it into
  // SplitRemainingItem objects. Called once in initState.
  // ─────────────────────────────────────────────────────────────────────────
  void _buildRemainingItems() {
    final cart = CartService.instance;
    _remainingItems = [
      // Regular (non-combo) items
      ...cart.cart.values.map((item) => SplitRemainingItem(
            key: item.productId.toString(),
            productId: item.productId,
            name: item.name,
            unitPrice: item.price,
            isCombo: false,
            cartItem: item,
            remainingQty: item.qty,
            // Pass extra fields so Order History detail shows correctly
            note: item.note,
            customerNote: item.customerNote,
            image: item.image,
            variantAttributes: item.variantAttributes,
          )),
      // Combo items — treated as whole units (you can split qty but not a combo itself)
      ...cart.comboCart.values.map((combo) => SplitRemainingItem(
            key: combo.cartKey,
            productId: combo.comboProductId,
            name: combo.comboName,
            unitPrice: combo.unitPrice, // base + extras
            isCombo: true,
            comboItem: combo,
            remainingQty: combo.qty,
          )),
    ];
  }

  // ─────────────────────────────────────────────────────────────────────────
  // _initPersonQty
  // Sets all item qty to 0 by default — nothing pre-selected.
  // Cashier taps an item card to toggle it (0 → full remainingQty → 0).
  // "Select All" shortcut is available if needed.
  // Called at start and again each time a new person begins.
  // ─────────────────────────────────────────────────────────────────────────
  void _initPersonQty() {
    _selectedQty.clear();
    for (final item in _remainingItems) {
      // Default = 0 so nothing is pre-selected; cashier taps to select
      _selectedQty[item.key] = 0;
    }
  }

  // ── Computed helpers ───────────────────────────────────────────────────────

  // Only items that still have remaining qty (what the current person can pick from).
  List<SplitRemainingItem> get _activeItems =>
      _remainingItems.where((i) => i.remainingQty > 0).toList();

  // Total units this person has selected across all items.
  int get _selectedCount => _selectedQty.values.fold(0, (sum, q) => sum + q);

  // Total amount this person pays (subtotal + tax).
  double get _personTotal {
    final taxRate = CartService.instance.taxRate;
    double subtotal = 0;
    for (final item in _activeItems) {
      final qty = _selectedQty[item.key] ?? 0;
      subtotal += item.unitPrice * qty;
    }
    // Round to 2 decimal places — same as CartService.total
    return double.parse(
        (subtotal + subtotal * taxRate / 100).toStringAsFixed(2));
  }

  // Shortcut: select ALL remaining units of every item.
  void _selectAll() {
    setState(() {
      for (final item in _activeItems) {
        _selectedQty[item.key] = item.remainingQty;
      }
    });
  }

  // Open customer search sheet in returnMode — result is the chosen customer map.
  Future<void> _pickCustomer(BuildContext context) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CartTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      // returnMode=true means the sheet returns the customer map to caller
      // instead of setting the global cart customer.
      builder: (_) => const CustomerSearchSheet(returnMode: true),
    );
    if (result != null && mounted) {
      setState(() => _selectedCustomer = result);
    }
  }

  // Transition from item-selection to payment screen.
  void _goToPayment() {
    if (_selectedCount == 0) {
      return; // guard — should not happen (button disabled)
    }
    setState(() {
      _step = SplitStep.payment;
      _error = '';
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // _paySplit  — POST /api/order/split for the current person
  //
  // Builds the payload with only THIS person's selected items,
  // calls the split API, then:
  //   - On success + items remain → personDone (next person will follow)
  //   - On success + no items left → allDone (cart cleared)
  //   - On error → show error message, stay on payment screen
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _paySplit() async {
    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();
      final deviceCode = await AppConfig.getDeviceCode();
      final sessionId = await AppConfig.getPosSessionId();
      final cart = CartService.instance;

      final totalRemainingUnits =
          _remainingItems.fold(0, (sum, item) => sum + item.remainingQty);
      final bool isLastPerson = _selectedCount == totalRemainingUnits;
      final bool isRestoredOrder = cart.editingPendingLocalId != null;
      final bool useRegularPaymentForLastPart = isLastPerson && isRestoredOrder;
      final taxRate = cart.taxRate;

      // Guard: device code must be configured
      if (deviceCode.isEmpty) {
        setState(() {
          _error = 'Device code not set. Go to Settings.';
          _loading = false;
        });
        return;
      }

      // Build order lines for THIS person only.
      // Regular items → one line each.
      // Combo items → expanded to parent + child lines via toOrderLines().
      final lines = <Map<String, dynamic>>[];
      for (final item in _activeItems) {
        final qty = _selectedQty[item.key] ?? 0;
        if (qty <= 0) continue; // skip items this person didn't select

        if (item.isCombo && item.comboItem != null) {
          // copyWith(qty: qty) creates a modified combo with only this person's qty.
          // toOrderLines() then generates the correct parent + child lines.
          final adjustedCombo = item.comboItem!.copyWith(qty: qty);
          lines.addAll(adjustedCombo.toOrderLines(taxRate: taxRate));
        } else {
          // Regular item — one simple line with all fields for Order History detail
          lines.add({
            'product_id': item.productId,
            'product_name': item.name,
            'qty': qty,
            'price': item.unitPrice,
            'tax_rate': taxRate,
            'note': item.note,
            'customer_note': item.customerNote,
            'image': item.image,
            'variant_attributes': jsonEncode(item.variantAttributes),
          });
        }
      }

      // Use original external_id for the last part of a restored order so Odoo updates it.
      // Otherwise, generate a unique ID for this person's share.
      final externalId = useRegularPaymentForLastPart
          ? (cart.editingPendingExternalId ?? const Uuid().v4())
          : const Uuid().v4();

      // Build the full API payload for this person's sub-order.
      final payload = <String, dynamic>{
        'split_group_id': _splitGroupId, // shared by all persons in this split
        'split_person_index': _currentPersonIndex, // 1, 2, 3...
        'external_id': externalId, // unique per sub-order
        'device_code': deviceCode,
        'session_id': sessionId,

        // customer_id is optional — null means Walk-in customer in Odoo
        if (_selectedCustomer != null) 'customer_id': _selectedCustomer!['id'],

        'lines': lines,

        'payments': [
          {'method': _paymentMethod, 'amount': _personTotal}
        ],
      };

      // ── Check connectivity before attempting the network call ──────────
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

      // ── Offline path — save directly to SQLite, skip network call ───────
      if (!isOnline) {
        await _savePersonOffline(
          externalId: externalId,
          deviceCode: deviceCode,
          sessionId: sessionId,
          lines: lines,
          cart: cart,
          companyName: '',
          useRegularPaymentForLastPart: useRegularPaymentForLastPart,
        );
        return;
      }

      // ── Online path ────────────────────────────────────────────────────────
      try {
        final odooOrderId = cart.editingPendingOdooOrderId;
        final bool isServerSyncedDraft = odooOrderId != null && odooOrderId > 0;
        http.Response response;

        if (useRegularPaymentForLastPart) {
          // PATH: Final part of a restored order — update and pay the original Odoo order
          if (isServerSyncedDraft) {
            // Pay existing Odoo draft in-place
            final payPayload = {
              'device_code': deviceCode,
              'session_id': sessionId,
              'lines': lines,
              'payments': [
                {'method': _paymentMethod, 'amount': _personTotal}
              ],
              'split_group_id': _splitGroupId,
              'split_person_index': _currentPersonIndex,
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
            // Create/Update order using external_id matching (upsert)
            final regularPayload = {
              ...payload,
              if (odooOrderId != null && odooOrderId > 0)
                'odoo_order_id': odooOrderId,
            };
            response = await http
                .post(
                  Uri.parse('$baseUrl/api/order'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer $token',
                  },
                  body: jsonEncode(regularPayload),
                )
                .timeout(const Duration(seconds: 20));
          }
        } else {
          // PATH: Normal split order (sub-order creation)
          response = await http
              .post(
                Uri.parse('$baseUrl/api/order/split'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 20));
        }

        final data = jsonDecode(response.body);

        if (data['status'] == 'success') {
          // Store paid amount for the success screen
          _lastPersonAmount = _personTotal;

          // Without this, when orderPlacedNotifier fires and the Orders screen
          // refreshes via GET /api/orders, Odoo's pos.payment record may not
          // be committed yet → payment_methods returns [] → local fromJson
          // falls back to 'Cash' even if cashier chose 'Bank'.
          try {
            final odooOrderId = data['data']?['order_id'] as int? ?? 0;
            final orderName = data['data']?['order_name'] as String?;
            if (odooOrderId > 0) {
              final orderRepo = OrderRepository();

              if (useRegularPaymentForLastPart &&
                  cart.editingPendingLocalId != null) {
                // Final part of restored order — update the local row to 'done'
                await orderRepo.markOrderAsSynced(
                  cart.editingPendingLocalId!,
                  paymentMethod: _paymentMethod,
                  odooOrderId: odooOrderId,
                );
              } else {
                // Normal split part — insert fresh synced record
                await orderRepo.insertSyncedOrder(
                  name: orderName,
                  odooId: odooOrderId,
                  externalId: externalId,
                  customerName:
                      _selectedCustomer?['name'] as String? ?? 'Walk-in',
                  customerNote:
                      'Split order — person $_currentPersonIndex (group: $_splitGroupId)',
                  total: _personTotal,
                  paymentMethod: _paymentMethod,
                  sessionId: sessionId,
                  lines: lines,
                );
              }
            }
          } catch (saveErr) {
            // Non-fatal — the order is already confirmed on Odoo.
            // Just log; do not block the UI flow.
            debugPrint('⚠️ Could not save split order locally: $saveErr');
          }

          // Deduct this person's claimed items from the shared remaining pool
          for (final item in _activeItems) {
            final qty = _selectedQty[item.key] ?? 0;
            item.remainingQty -= qty;
          }

          final allPaid = _activeItems.isEmpty;
          if (!allPaid) _deductPaidItemsFromCart();

          if (allPaid) {
            cart.clearCart();
            orderPlacedNotifier.value++;
            if (mounted) {
              setState(() {
                _step = SplitStep.allDone;
                _loading = false;
              });
            }
          } else {
            if (mounted) {
              setState(() {
                _step = SplitStep.personDone;
                _loading = false;
              });
            }
          }
        } else {
          // ❌ Server returned a business error — do NOT save offline,
          // show message so cashier can fix the issue (e.g. wrong session).
          if (mounted) {
            setState(() {
              _error = data['message'] ?? 'Payment failed. Please try again.';
              _loading = false;
            });
          }
        }
      } catch (networkError) {
        // ❌ Network dropped mid-request — fall back to offline save
        debugPrint(
            '⚠️ Split order network error: $networkError — saving offline');
        await _savePersonOffline(
          externalId: externalId,
          deviceCode: deviceCode,
          sessionId: sessionId,
          lines: lines,
          companyName:
              await AppConfig.getCompanyName(), // Fetch and pass company name
          cart: cart,
          useRegularPaymentForLastPart: useRegularPaymentForLastPart,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Unexpected error: $e';
          _loading = false;
        });
      }
    }
  }

  // ── Helper: save this person's split sub-order to local SQLite ───────────
  // Called both when device is offline at start and when network drops mid-call.
  Future<void> _savePersonOffline({
    required String externalId,
    required String deviceCode,
    required int sessionId,
    required List<Map<String, dynamic>> lines,
    required String? companyName,
    required CartService cart,
    required bool useRegularPaymentForLastPart,
  }) async {
    debugPrint(
        '📱 Saving split order offline (person $_currentPersonIndex)...');
    try {
      final orderRepo = OrderRepository();
      final customerId = _selectedCustomer?['id'] as int? ?? 0;
      final customerName = _selectedCustomer?['name'] as String? ?? 'Walk-in';
      final splitNote =
          'Split order — person $_currentPersonIndex (group: $_splitGroupId)';

      int orderId;
      if (useRegularPaymentForLastPart && cart.editingPendingLocalId != null) {
        // Final part of a restored order — update the original SQLite row instead of creating new
        final db = await DatabaseHelper().database;
        final now = DateTime.now().millisecondsSinceEpoch;

        await db.update(
          'orders',
          {
            'status': 'pending', // paid, waiting sync
            'payment_method': _paymentMethod,
            'device_code': deviceCode,
            'customer_id': customerId,
            'customer_name': customerName,
            'customer_note': splitNote,
            'total': _personTotal,
            'tax_amount': cart.taxAmount,
            'synced': 0,
            'company_name': companyName ?? '',
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [cart.editingPendingLocalId],
        );

        // Replace old lines with the items that were actually selected for this last split payment
        await db.delete('order_lines',
            where: 'order_id = ?', whereArgs: [cart.editingPendingLocalId!]);
        await orderRepo.saveOrderLines(cart.editingPendingLocalId!, lines,
            sessionId: sessionId);

        orderId = cart.editingPendingLocalId!;
        debugPrint(
            '✅ Updated existing restored order (local id=$orderId) with final split payment');
      } else {
        // Normal split part — create new offline order
        orderId = await orderRepo.createOfflineOrder(
          externalId: externalId,
          deviceCode: deviceCode,
          customerId: customerId,
          customerName: customerName,
          customerNote: splitNote,
          sessionId: sessionId,
          lines: lines,
          total: _personTotal,
          taxAmount: cart.taxAmount,
          status: 'pending',
          companyName: companyName ?? '',
          paymentMethod: _paymentMethod,
        );
      }

      if (orderId > 0) {
        debugPrint('✅ Split order saved offline with ID: $orderId');

        _lastPersonAmount = _personTotal;

        // Deduct this person's items from the remaining pool
        for (final item in _activeItems) {
          final qty = _selectedQty[item.key] ?? 0;
          item.remainingQty -= qty;
        }

        final allPaid = _activeItems.isEmpty;

        // Sync paid qtys back into CartService so the live cart reflects
        // only the remaining unpaid items (same fix as the online path above).
        if (!allPaid) _deductPaidItemsFromCart();

        if (allPaid) {
          cart.clearCart();
          orderPlacedNotifier.value++;
        }

        if (mounted) {
          setState(() {
            _step = allPaid ? SplitStep.allDone : SplitStep.personDone;
            _loading = false;
          });

          // Inform cashier the order was saved offline
          showTopNotification(
            context,
            '📱 Split order saved offline. Will sync when server is online.',
            color: Colors.blue.shade700,
            icon: Icons.cloud_off_rounded,
            duration: const Duration(seconds: 4),
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
      debugPrint('❌ Split offline save failed: $offlineError');
      if (mounted) {
        setState(() {
          _error = 'No connection. Could not save order. Please try again.';
          _loading = false;
        });
      }
    }
  }

  // Move to the next person — resets step, customer, payment method, and qty selections.
  void _nextPerson() {
    setState(() {
      _currentPersonIndex++;
      _selectedCustomer = null;
      _paymentMethod = 'Cash';
      _error = '';
      _step = SplitStep.selectItems;
      _initPersonQty(); // reset qty selections for the new person
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) {
        return Container(
          decoration: const BoxDecoration(
            color: CartTheme.card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // ── Drag handle ───────────────────────────────────────────────
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: CartTheme.cardBorder,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),

              // ── Header row ────────────────────────────────────────────────
              _buildHeader(),
              const Divider(color: CartTheme.cardBorder, height: 1),

              // ── Scrollable body — changes per step ────────────────────────
              Expanded(child: _buildBody(scrollCtrl)),

              // ── Fixed bottom action bar ───────────────────────────────────
              _buildBottomBar(),
            ],
          ),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Header — shows title + optional back arrow + person badge
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    // Title changes per step
    final String title;
    switch (_step) {
      case SplitStep.selectItems:
        title = 'Select Items';
        break;
      case SplitStep.payment:
        title = 'Payment';
        break;
      case SplitStep.personDone:
        title = 'Paid ✓';
        break;
      case SplitStep.allDone:
        title = 'Split Complete ✓';
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Row(
        children: [
          // Back arrow is only shown on the payment step
          if (_step == SplitStep.payment)
            GestureDetector(
              onTap: () => setState(() {
                _step = SplitStep.selectItems;
                _error = '';
              }),
              child: const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(Icons.arrow_back_ios_new_rounded,
                    color: CartTheme.textSecondary, size: 18),
              ),
            ),

          const Icon(Icons.call_split_rounded,
              color: CartTheme.purple, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                  color: CartTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700),
            ),
          ),

          // Split number badge — shows which split number this is
          if (_step == SplitStep.selectItems || _step == SplitStep.payment)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: CartTheme.purple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Split #$_currentPersonIndex',
                style: const TextStyle(
                    color: CartTheme.purple,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Body router — delegates to the correct step widget
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildBody(ScrollController scrollCtrl) {
    switch (_step) {
      case SplitStep.selectItems:
        return _buildItemSelectBody(scrollCtrl);
      case SplitStep.payment:
        return _buildPaymentBody(scrollCtrl);
      case SplitStep.personDone:
        return _buildPersonDoneBody();
      case SplitStep.allDone:
        return _buildAllDoneBody();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Step 1: Item Selection
  //
  // Shows:
  //   - Instruction hint card
  //   - "Select All" shortcut button
  //   - Optional customer picker row
  //   - One card per remaining item with [−] qty [+] controls
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildItemSelectBody(ScrollController scrollCtrl) {
    final items = _activeItems; // only items with remainingQty > 0
    final totalRemaining = items.fold(0, (s, i) => s + i.remainingQty);

    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        // ── Instruction hint ─────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: CartTheme.purple.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CartTheme.purple.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded,
                color: CartTheme.purple, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Tap an item to select it for this person. Tap again to deselect.',
                style: const TextStyle(
                    color: CartTheme.textSecondary, fontSize: 12),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),

        // ── Select All shortcut — only shown when not everything is selected ─
        if (_selectedCount < totalRemaining)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _selectAll,
              icon: const Icon(Icons.select_all_rounded,
                  color: CartTheme.purple, size: 16),
              label: const Text('Select All',
                  style: TextStyle(color: CartTheme.purple, fontSize: 13)),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
            ),
          ),

        // ── Customer card — styled like main cart customer card ───────────
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: CartTheme.inputBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _selectedCustomer != null
                  ? CartTheme.purple.withValues(alpha: 0.4)
                  : CartTheme.cardBorder,
            ),
          ),
          child: Row(children: [
            // Avatar circle — initials when customer selected, icon when not
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _selectedCustomer != null
                    ? CartTheme.purple.withValues(alpha: 0.18)
                    : CartTheme.cardBorder,
                shape: BoxShape.circle,
              ),
              child: _selectedCustomer != null
                  ? Center(
                      child: Text(
                        // First letter of customer name as avatar
                        ((_selectedCustomer!['name'] as String?) ?? 'C')
                                .isNotEmpty
                            ? ((_selectedCustomer!['name'] as String)[0])
                                .toUpperCase()
                            : 'C',
                        style: const TextStyle(
                            color: CartTheme.purple,
                            fontSize: 18,
                            fontWeight: FontWeight.w700),
                      ),
                    )
                  : const Icon(Icons.person_outline_rounded,
                      color: CartTheme.textSecondary, size: 22),
            ),
            const SizedBox(width: 12),

            // Name + phone (or placeholder)
            Expanded(
              child: _selectedCustomer != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedCustomer!['name'] as String? ?? '',
                          style: const TextStyle(
                              color: CartTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                        if ((_selectedCustomer!['phone'] as String? ?? '')
                            .isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            _selectedCustomer!['phone'] as String,
                            style: const TextStyle(
                                color: CartTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                      ],
                    )
                  : const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('No customer selected',
                            style: TextStyle(
                                color: CartTheme.textSecondary, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('Walk-in order',
                            style: TextStyle(
                                color: CartTheme.textSecondary, fontSize: 11)),
                      ],
                    ),
            ),

            // Select / Change button
            GestureDetector(
              onTap: () => _pickCustomer(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: CartTheme.purple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: CartTheme.purple.withValues(alpha: 0.3)),
                ),
                child: Text(
                  _selectedCustomer != null ? 'Change' : 'Select',
                  style: const TextStyle(
                      color: CartTheme.purple,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),

            // Remove customer X button — only shown when customer selected
            if (_selectedCustomer != null) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _selectedCustomer = null),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: CartTheme.red.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: CartTheme.red, size: 14),
                ),
              ),
            ],
          ]),
        ),

        // ── Item cards ───────────────────────────────────────────────────
        ...items.map((item) {
          final qty = _selectedQty[item.key] ?? 0;
          final isSelected = qty > 0;

          return GestureDetector(
            // Tap the whole card to toggle: unselected → full remainingQty, selected → 0
            onTap: () {
              setState(() {
                _selectedQty[item.key] = isSelected ? 0 : item.remainingQty;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // Highlight card when selected
                color: isSelected
                    ? CartTheme.purple.withValues(alpha: 0.08)
                    : CartTheme.inputBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? CartTheme.purple.withValues(alpha: 0.5)
                      : CartTheme.cardBorder,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Row(children: [
                // ── Left: item name + details ─────────────────────────
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        // COMBO badge for combo items
                        if (item.isCombo) ...[
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: CartTheme.orange,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'COMBO',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            item.name,
                            style: const TextStyle(
                                color: CartTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        '${AppConfig.currencySymbol}${item.unitPrice.toStringAsFixed(2)} each  •  ${item.remainingQty} remaining',
                        style: const TextStyle(
                            color: CartTheme.textSecondary, fontSize: 12),
                      ),
                      // Show line total when selected
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Subtotal: ${AppConfig.currencySymbol}${(item.unitPrice * qty).toStringAsFixed(2)}',
                            style: const TextStyle(
                                color: CartTheme.purpleLight,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // ── Right: checkmark icon when selected, empty circle when not ──
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isSelected ? CartTheme.purple : CartTheme.cardBorder,
                    shape: BoxShape.circle,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check_rounded,
                          color: Colors.white, size: 16)
                      : null,
                ),
              ]),
            ),
          );
        }),

        const SizedBox(height: 80), // space for fixed bottom bar
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Step 2: Payment
  //
  // Shows:
  //   - Customer name (if selected)
  //   - Summary of THIS person's selected items
  //   - Subtotal / Tax / Total breakdown
  //   - Cash / Bank payment method toggle
  //   - Error message if API call failed
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildPaymentBody(ScrollController scrollCtrl) {
    final cart = CartService.instance;
    final taxRate = cart.taxRate;

    // Only the items this person actually selected (qty > 0)
    final myItems =
        _activeItems.where((i) => (_selectedQty[i.key] ?? 0) > 0).toList();

    // Compute subtotal (before tax) from the selected items
    double subtotalBeforeTax = 0;
    for (final item in myItems) {
      subtotalBeforeTax += item.unitPrice * (_selectedQty[item.key] ?? 0);
    }
    final taxAmount = subtotalBeforeTax * taxRate / 100;

    return SingleChildScrollView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Customer info (read-only on payment screen) ──────────────
          if (_selectedCustomer != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: CartTheme.purple.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: CartTheme.purple.withValues(alpha: 0.2)),
              ),
              child: Row(children: [
                const Icon(Icons.person_rounded,
                    color: CartTheme.purple, size: 16),
                const SizedBox(width: 8),
                Text(
                  _selectedCustomer!['name'] as String? ?? 'Customer',
                  style: const TextStyle(
                      color: CartTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ]),
            ),

          // ── Items summary ────────────────────────────────────────────
          const Text(
            'ITEMS',
            style: TextStyle(
                color: CartTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8),
          ),
          const SizedBox(height: 10),
          ...myItems.map((item) {
            final qty = _selectedQty[item.key] ?? 0;
            final lineTotal = item.unitPrice * qty;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    qty > 1 ? '${item.name}  ×$qty' : item.name,
                    style: const TextStyle(
                        color: CartTheme.textPrimary, fontSize: 14),
                  ),
                ),
                Text(
                  '${AppConfig.currencySymbol}${lineTotal.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: CartTheme.textSecondary, fontSize: 13),
                ),
              ]),
            );
          }),

          const Divider(color: CartTheme.cardBorder, height: 24),

          // ── Subtotal / Tax / Total breakdown ─────────────────────────
          Row(children: [
            const Text('Subtotal',
                style: TextStyle(color: CartTheme.textSecondary, fontSize: 13)),
            const Spacer(),
            Text(
                '${AppConfig.currencySymbol}${subtotalBeforeTax.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: CartTheme.textSecondary, fontSize: 13)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Text(
              'Tax (${taxRate.toStringAsFixed(0)}%)',
              style:
                  const TextStyle(color: CartTheme.textSecondary, fontSize: 13),
            ),
            const Spacer(),
            Text('${AppConfig.currencySymbol}${taxAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: CartTheme.textSecondary, fontSize: 13)),
          ]),
          const Divider(color: CartTheme.cardBorder, height: 16),
          Row(children: [
            const Text('Total',
                style: TextStyle(
                    color: CartTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            Text(
              '${AppConfig.currencySymbol}${_personTotal.toStringAsFixed(2)}',
              style: const TextStyle(
                color: CartTheme.purpleLight,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ]),

          const SizedBox(height: 24),

          // ── Payment method selector ───────────────────────────────────
          const Text(
            'PAYMENT METHOD',
            style: TextStyle(
                color: CartTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8),
          ),
          const SizedBox(height: 10),
          _paymentMethodOption('Cash', Icons.payments_outlined),
          const SizedBox(height: 10),
          _paymentMethodOption('Bank', Icons.credit_card_outlined),

          // ── Error message ─────────────────────────────────────────────
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: CartTheme.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CartTheme.red.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline, color: CartTheme.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error,
                      style:
                          const TextStyle(color: CartTheme.red, fontSize: 12)),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 80), // space for bottom bar
        ],
      ),
    );
  }

  // Animated payment method selection card (Cash / Bank)
  Widget _paymentMethodOption(String label, IconData icon) {
    final selected = _paymentMethod == label;
    return GestureDetector(
      onTap: () => setState(() => _paymentMethod = label),
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
        child: Row(children: [
          Icon(icon,
              color: selected ? CartTheme.purpleLight : CartTheme.textSecondary,
              size: 22),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              color: selected ? CartTheme.textPrimary : CartTheme.textSecondary,
              fontSize: 15,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const Spacer(),
          // Checkmark circle when selected
          if (selected)
            Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                  color: CartTheme.purple, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded,
                  color: Colors.white, size: 12),
            ),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Person Done screen — shown briefly after a person pays
  // Displays amount paid + how many items remain for the next person
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildPersonDoneBody() {
    final remainingUnits = _activeItems.fold(0, (s, i) => s + i.remainingQty);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Green check circle
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

            Text(
              'Payment Done!',
              style: const TextStyle(
                  color: CartTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),

            // Amount paid in large green text
            Text(
              '${AppConfig.currencySymbol}${_lastPersonAmount.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: CartTheme.green,
                  fontSize: 30,
                  fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),

            // Remaining items badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: CartTheme.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: CartTheme.orange.withValues(alpha: 0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.inventory_2_outlined,
                    color: CartTheme.orange, size: 16),
                const SizedBox(width: 8),
                Text(
                  '$remainingUnits item unit${remainingUnits != 1 ? 's' : ''} remaining for next person',
                  style: const TextStyle(
                      color: CartTheme.orange,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // All Done screen — shown after the last person pays
  // Cart has already been cleared at this point (in _paySplit).
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildAllDoneBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Large filled green check circle
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: CartTheme.green.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: CartTheme.green, size: 48),
            ),
            const SizedBox(height: 20),

            const Text(
              'Split Complete!',
              style: TextStyle(
                  color: CartTheme.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),

            Text(
              'All $_currentPersonIndex person${_currentPersonIndex != 1 ? 's' : ''} paid successfully.\nCart has been cleared.',
              style:
                  const TextStyle(color: CartTheme.textSecondary, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Fixed bottom action bar
  // Button label, color, and action all change based on the current step.
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      decoration: BoxDecoration(
        color: CartTheme.card,
        border: Border(top: BorderSide(color: CartTheme.cardBorder)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: _bottomAction(),
          style: ElevatedButton.styleFrom(
            backgroundColor: _bottomColor(),
            // Grey-out when disabled
            disabledBackgroundColor: CartTheme.purple.withValues(alpha: 0.35),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: _bottomChild(),
        ),
      ),
    );
  }

  // The callback attached to the bottom button (null = disabled)
  VoidCallback? _bottomAction() {
    switch (_step) {
      case SplitStep.selectItems:
        // Disabled until at least 1 unit is selected
        return _selectedCount > 0 ? _goToPayment : null;
      case SplitStep.payment:
        // Disabled while API call is in flight
        return _loading ? null : _paySplit;
      case SplitStep.personDone:
        return _nextPerson;
      case SplitStep.allDone:
        return () => Navigator.pop(context); // close the sheet
    }
  }

  // Button background color per step
  Color _bottomColor() {
    if (_step == SplitStep.allDone || _step == SplitStep.personDone) {
      return CartTheme.green;
    }
    return CartTheme.purple;
  }

  // Button label / content per step
  Widget _bottomChild() {
    switch (_step) {
      case SplitStep.selectItems:
        return Text(
          _selectedCount > 0
              ? 'Proceed to Payment  •  ${AppConfig.currencySymbol}${_personTotal.toStringAsFixed(2)}'
              : 'Select at least 1 item to continue',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        );

      case SplitStep.payment:
        // Show a spinner while the API call is running
        return _loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5))
            : Text(
                'Pay  ${AppConfig.currencySymbol}${_personTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15),
              );

      case SplitStep.personDone:
        return Text(
          'Next Person  →',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        );

      case SplitStep.allDone:
        return const Text(
          'Done  ✓',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // _deductPaidItemsFromCart
  //
  // After each person pays, remove their items from CartService so the live
  // cart reflects only the REMAINING unpaid items.
  //
  // WHY THIS IS NEEDED:
  // _remainingItems tracks remaining qty inside the split sheet, but
  // CartService (the source of truth for the cart UI) is NOT updated.
  // So if the cashier backs out of the split sheet after person 1 pays,
  // the cart still shows ALL original items. On re-opening split, those
  // already-paid items appear again.
  //
  // FIX: after each person's payment is confirmed, sync the paid qty back
  // to CartService — paid items are reduced/removed there too.
  // _remainingItems.remainingQty is already decremented by the caller
  // before this method runs, so we use it as the new cart qty directly.
  // ─────────────────────────────────────────────────────────────────────────
  void _deductPaidItemsFromCart() {
    final cart = CartService.instance;
    for (final item in _remainingItems) {
      final paidQty = _selectedQty[item.key] ?? 0;
      if (paidQty <= 0) continue; // this item wasn't selected — skip

      // item.remainingQty is already decremented by the caller (online or
      // offline payment block). Use it directly as the new cart qty.
      final newQty = item.remainingQty;

      if (item.isCombo) {
        // Combo items use cartKey as their identifier in CartService
        cart.setComboQty(item.key, newQty);
      } else {
        // Regular items use productId; setItemQty removes the entry if qty == 0
        cart.setItemQty(item.productId, newQty);
      }
    }
  }
}
// ═══════════════════════════════════════════════════════════════════════════
// END OF _SplitFlowSheet
// ═══════════════════════════════════════════════════════════════════════════
