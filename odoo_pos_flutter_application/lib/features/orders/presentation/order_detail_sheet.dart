import 'dart:convert';

import 'package:OdoCart/screens/product_screen.dart';
import 'package:flutter/material.dart';
import '../../../data/repositories/customer_repository.dart';
import '../../../services/cart_service.dart';
import '../../../services/product_cache.dart';
import '../../../widgets/top_notification.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/receipt/receipt_screen.dart';
import '../../../data/repositories/order_repository.dart';
import '../../../services/app_config.dart';
import '../../../services/odoo_service.dart';
import '../../../widgets/product_image.dart';
import '../data/order_line_repository.dart';
import '../domain/order.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ORDER DETAIL BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────
class OrderDetailSheet extends StatefulWidget {
  final OrderModel order;
  const OrderDetailSheet({super.key, required this.order});

  @override
  State<OrderDetailSheet> createState() => OrderDetailSheetState();
}

class OrderDetailSheetState extends State<OrderDetailSheet> {
  // State for items expand/collapse
  bool _itemsExpanded = false;

  // State for loading lines from API
  bool _linesLoading = false;
  String _linesError = '';
  List<Map<String, dynamic>> _lines = [];
  Future<void> _toggleItems() async {
    if (_itemsExpanded) {
      // Collapse — just hide
      setState(() => _itemsExpanded = false);
      return;
    }

    // If lines already loaded, just expand
    if (_lines.isNotEmpty) {
      setState(() => _itemsExpanded = true);
      return;
    }

    // Load lines from API
    setState(() {
      _linesLoading = true;
      _linesError = '';
      _itemsExpanded = true;
    });

    try {
      // 🔒 SESSION ISOLATION: Always use local SQLite ID, never server ID
      // widget.order.id is the LOCAL SQLite ID (after fix in orders_screen.dart)
      // This ensures we only load lines for THIS specific order, not cross-session
      final localOrderId = widget.order.id;
      final serverId = widget.order.odooOrderId;

      final lineRepo = OrderLineRepository();

      // 1️⃣ CHECK CONNECTIVITY FIRST — Prefer fresh data from API if online
      bool isOnline = false;
      try {
        isOnline = await OdooService.checkConnection()
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        isOnline = false;
      }

      List<Map<String, dynamic>> lines = [];

      // 2️⃣ ONLINE: Try API FIRST to get fresh product names (avoid "Unknown")
      if (isOnline && serverId > 0) {
        try {
          final currentSessionId = await AppConfig.getPosSessionId();
          lines = await OdooService.fetchOrderLines(serverId,
              sessionId: currentSessionId);

          // ✅ Cache fresh data for offline use
          if (lines.isNotEmpty) {
            await lineRepo.saveOrderLines(localOrderId, lines);
          }
        } catch (e) {
          debugPrint('⚠️ Failed fetching from API: $e');
          lines = []; // Fall through to local
        }
      }

      // 3️⃣ OFFLINE or API FAILED: Fall back to local cache
      if (lines.isEmpty) {
        final localLines = await lineRepo.getOrderLines(localOrderId);

        if (localLines.isNotEmpty) {
          lines = localLines;
        } else if (!isOnline) {
          throw Exception('Device is offline. Items not found in local cache.');
        } else if (serverId <= 0) {
          throw Exception(
              'Cannot fetch items for an order not yet synced to Odoo.');
        } else {
          throw Exception(
              'Failed to load order items. Please check your connection.');
        }
      }

      setState(() {
        _lines = lines;
        _linesLoading = false;
      });
    } catch (e) {
      setState(() {
        _linesError = e.toString().replaceFirst('Exception: ', '');
        _linesLoading = false;
      });
    }
  }

  // ── Add pending order back to cart for editing ───────────────────────────
  Future<void> _addBackToCart() async {
    setState(() => _linesLoading = true);
    try {
      final cart = CartService.instance;

      // ── GUARD: Check if another pending order is already restored ───────
      // We check editingPendingLocalId to see if the current cart session
      // originated from a previous "Add back to cart" action.
      if (cart.editingPendingLocalId != null) {
        if (mounted) {
          showTopNotification(
            context,
            'A pending order is already being edited. Finish or clear it first.',
            color: AppColors.orangeAlt,
            icon: Icons.warning_amber_rounded,
          );
        }
        setState(() => _linesLoading = false);
        return;
      }

      // 1. Ensure lines are loaded
      if (_lines.isEmpty) {
        await _toggleItems();
        if (_lines.isEmpty) return;
      }

      // NEW: Ensure ProductCache is populated before trying to restore items.
      // This might happen if the user goes directly to Orders tab without first
      // loading products.
      if (ProductCache.instance.isEmpty) {
        final fetchResult = await ProductApiService.fetchProducts();
        if (!fetchResult.isSuccess) {
          throw Exception(
              'Could not load products to restore cart: ${fetchResult.errorMessage}');
        }
        // Populate the cache so the restoration loop below can find the items
        ProductCache.instance.setAll(fetchResult.products!);
      }

      final orderRepo = OrderRepository();

      // 2. Fetch full local data to get external_id and customer_id
      final localOrder = await orderRepo.getOrderById(widget.order.id);
      if (localOrder == null) throw Exception('Could not find order data.');

      // 3. Clear current cart and set editing state
      cart.clearCart();
      cart.editingPendingLocalId = widget.order.id;
      cart.editingPendingExternalId = localOrder['external_id'] as String?;

      // If this order is already synced to Odoo (odoo_order_id > 0), store the
      // server-side order ID. payment_sheet will use this to call
      // POST /api/order/<id>/pay instead of POST /api/order, so the existing
      // draft is paid in place — no new order is created on the server.
      // For local-only drafts (odoo_order_id = 0), this stays null and the
      // normal /api/order flow is used (which handles external_id matching).
      final odooId = (localOrder['odoo_order_id'] as num?)?.toInt() ?? 0;
      cart.editingPendingOdooOrderId = odooId > 0 ? odooId : null;

      // 4. Load Customer
      final customerId = (localOrder['customer_id'] as num?)?.toInt();
      if (customerId != null && customerId > 0) {
        final custRepo = CustomerRepository();
        final customerData = await custRepo.getCustomerById(customerId);
        if (customerData != null) {
          cart.setCustomer(SelectedCustomer.fromJson({
            'id': customerData['id'],
            'name': customerData['name'],
            'phone': customerData['phone'] ?? '',
            'email': customerData['email'] ?? '',
          }));
        }
      }

      // 5. Load Notes
      cart.setCustomerNote(widget.order.customerNote);

      // 6. Load Items into Cart
      for (final line in _lines) {
        final productId = (line['product_id'] as num?)?.toInt() ?? 0;
        final qty = ((line['qty'] ?? line['quantity']) as num?)?.toInt() ?? 1;

        // Look up product by ID first (preferred — works for both offline and
        // online orders when the API returns product_id in the line).
        // If product_id is 0 or missing (e.g. older API that did not include it),
        // fall back to searching by product_name so cart still restores correctly.
        ProductModel? template;
        if (productId > 0) {
          template = ProductCache.instance.get(productId);
        }
        if (template == null) {
          final productName = (line['product_name'] as String? ?? '').trim();
          if (productName.isNotEmpty) {
            template = ProductCache.instance.getByName(productName);
          }
        }

        // Skip this line if product still not found in cache
        if (template == null) continue;

        // Restoration logic must handle both simple products and specific variants
        if (template.hasVariants && template.variants.isNotEmpty) {
          // Search for the specific variant matching the line item's product_id.
          // If product_id was 0 (missing from API), fall back to first variant.
          final variant = template.variants.firstWhere(
            (v) => v.variantId == productId,
            orElse: () => template!.variants.first,
          );

          // Create a temporary ProductModel with variant-specific data
          final variantProduct = ProductModel(
            id: variant.variantId,
            name: '${template.name} (${variant.attributeLabel})',
            price: variant.price,
            category: template.category,
            active: template.active,
            image: variant.image ?? template.image,
            taxIds:
                variant.taxIds.isNotEmpty ? variant.taxIds : template.taxIds,
          );

          cart.addVariantItem(variantProduct, variant.attributes);
          cart.setItemQty(variant.variantId, qty);
          if (line['note'] != null) {
            cart.updateItemNote(variant.variantId, line['note']);
          }
          if (line['customer_note'] != null) {
            cart.updateItemCustomerNote(
                variant.variantId, line['customer_note']);
          }
        } else {
          // Standard non-variant product
          cart.addItem(template);
          // Use resolved productId from template in case it came via name fallback
          final resolvedId = productId > 0 ? productId : template.id;
          cart.setItemQty(resolvedId, qty);
          if (line['note'] != null) {
            cart.updateItemNote(resolvedId, line['note']);
          }
          if (line['customer_note'] != null) {
            cart.updateItemCustomerNote(resolvedId, line['customer_note']);
          }
        }
      }

      if (mounted) {
        // Capture what we need BEFORE pop — widget unmounts after Navigator.pop()
        final orderName = widget.order.name;
        final ctx = context;

        Navigator.pop(ctx); // Close detail sheet — widget unmounts here

        // Fire the CartService notifier so MainShell switches to Cart tab.
        // This is a direct singleton call — no callback chain required.
        // A short delay lets the sheet close animation finish first.
        await Future.delayed(const Duration(milliseconds: 300));
        CartService.instance.navigateToCartNotifier.value++;

        // Show confirmation notification (ctx belongs to the Orders tab overlay,
        // which stays mounted inside the IndexedStack even after tab switch).
        if (ctx.mounted) {
          showTopNotification(
            ctx,
            'Order #$orderName added back to cart.',
            color: AppColors.purple,
            icon: Icons.shopping_cart_checkout_rounded,
          );
        }
      }
    } catch (e) {
      setState(() => _linesError = 'Could not restore cart: $e');
    } finally {
      if (mounted) setState(() => _linesLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.order.name.toUpperCase(),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.order.timeLabel,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color:
                              widget.order.statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          widget.order.statusLabel,
                          style: TextStyle(
                            color: widget.order.statusColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 34,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.purple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ReceiptScreen(order: widget.order),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.receipt_long_rounded,
                            size: 16,
                          ),
                          label: const Text(
                            'Receipt',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(color: AppColors.cardBorder, height: 1),
            Expanded(
              child: ListView(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _sectionTitle('Order Info'),
                  const SizedBox(height: 10),

                  // Customer row
                  _infoRow(Icons.person_outline_rounded, 'Customer',
                      widget.order.customerName),

                  // Customer note row — only shown when note exists
                  if (widget.order.customerNote.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.orangeAlt.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: AppColors.orangeAlt.withValues(alpha: 0.30)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.sticky_note_2_outlined,
                              color: AppColors.orangeAlt, size: 16),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Customer Note',
                                  style: TextStyle(
                                      color: AppColors.orangeAlt,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.order.customerNote,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 13,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Payment row
                  _infoRow(Icons.payment_rounded, 'Payment',
                      widget.order.paymentMethod),

                  // ── Items row — tappable ──────────────────────────────────
                  GestureDetector(
                    onTap: _toggleItems,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      decoration: BoxDecoration(
                        color: AppColors.inputBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _itemsExpanded
                              ? AppColors.purple.withValues(alpha: 0.5)
                              : AppColors.cardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.receipt_outlined,
                              color: AppColors.textSecondary, size: 17),
                          const SizedBox(width: 10),
                          const Text(
                            'Items',
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 13),
                          ),
                          const Spacer(),
                          Text(
                            '${widget.order.lineCount} item${widget.order.lineCount != 1 ? "s" : ""}',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Arrow icon rotates when expanded
                          AnimatedRotation(
                            turns: _itemsExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: AppColors.purple,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Expanded items list ───────────────────────────────────
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _itemsExpanded
                        ? _buildItemsList()
                        : const SizedBox.shrink(),
                  ),

                  // Date row
                  _infoRow(Icons.calendar_today_outlined, 'Date',
                      widget.order.timeLabel),

                  const SizedBox(height: 20),
                  _sectionTitle('Amount'),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: AppColors.purple.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total Amount',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${AppConfig.currencySymbol}${widget.order.amountTotal.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: AppColors.purple,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── PENDING ORDER: Payment flow or success message ────────
                  // Show "Add back to cart" only for pending (draft/new) orders.
                  // Cancelled orders are final — they should NOT be re-added to cart.
                  if (widget.order.state == 'draft' ||
                      widget.order.state == 'new') ...[
                    // Replace "Proceed to Payment" flow with "Add back to cart"
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _linesLoading ? null : _addBackToCart,
                        icon: _linesLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.add_shopping_cart_rounded,
                                size: 18),
                        label: const Text(
                          'Add back to cart',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.purple,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // ── Close button — always visible ─────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.inputBg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: AppColors.cardBorder),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Close',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Items list widget — loading / error / data ────────────────────────────
  Widget _buildItemsList() {
    return Container(
      key: const ValueKey('items_list'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: _linesLoading
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      color: AppColors.purple, strokeWidth: 2),
                ),
              ),
            )
          : _linesError.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _linesError,
                    style: const TextStyle(color: AppColors.red, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                )
              : _lines.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No items found.',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Column(
                      children: _lines.asMap().entries.map((entry) {
                        final i = entry.key;
                        final line = entry.value;
                        final isLast = i == _lines.length - 1;

                        final productName =
                            line['product_name'] as String? ?? 'Unknown';
                        // Local SQLite uses 'quantity', Odoo API uses 'qty' — handle both
                        final qty = ((line['qty'] ?? line['quantity']) as num?)
                                ?.toDouble() ??
                            0;
                        // Local SQLite uses 'price', Odoo API uses 'price_unit' — handle both
                        final priceUnit =
                            ((line['price_unit'] ?? line['price']) as num?)
                                    ?.toDouble() ??
                                0;

                        // BUG FIX: Old SQLite rows have price_subtotal_incl = 0.0 (DEFAULT from
                        // migration) not null, so the ?? operator did NOT fall back to priceUnit*qty.
                        // Fix: explicitly check > 0 so the fallback fires for both null AND 0.0.
                        final rawSubIncl =
                            (line['price_subtotal_incl'] as num?)?.toDouble() ??
                                0;
                        final priceSubtotalIncl =
                            rawSubIncl > 0 ? rawSubIncl : (priceUnit * qty);

                        // Read customer note for this line item
                        // This is the per-item note the customer entered in cart
                        // (e.g. "No onions", "Extra cheese")
                        final lineCustomerNote =
                            line['customer_note'] as String? ?? '';

                        return Column(
                          children: [
                            // Each item row is tappable — opens full detail sheet
                            InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _showItemDetail(line),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Product name + unit price × qty + customer note preview
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            productName,
                                            style: const TextStyle(
                                              color: AppColors.textPrimary,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${AppConfig.currencySymbol}${priceUnit.toStringAsFixed(2)} × ${qty % 1 == 0 ? qty.toInt() : qty}',
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 11,
                                            ),
                                          ),

                                          // Customer note preview — shown below price
                                          // Only visible when the item has a customer note
                                          // Tap the row to see full note in detail sheet
                                          if (lineCustomerNote.isNotEmpty) ...[
                                            const SizedBox(height: 5),
                                            Row(
                                              children: [
                                                // Person icon to distinguish from kitchen note
                                                const Icon(
                                                  Icons.person_outline,
                                                  color: AppColors.orangeAlt,
                                                  size: 11,
                                                ),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                  child: Text(
                                                    lineCustomerNote,
                                                    style: const TextStyle(
                                                      color:
                                                          AppColors.orangeAlt,
                                                      fontSize: 11,
                                                      fontStyle:
                                                          FontStyle.italic,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    // Line total + right arrow hint
                                    Row(
                                      children: [
                                        Text(
                                          '${AppConfig.currencySymbol}${priceSubtotalIncl.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: AppColors.purple,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        // Chevron hints that the row is tappable
                                        const Icon(
                                          Icons.chevron_right_rounded,
                                          color: AppColors.textSecondary,
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (!isLast)
                              const Divider(
                                  color: AppColors.cardBorder,
                                  height: 1,
                                  indent: 14,
                                  endIndent: 14),
                          ],
                        );
                      }).toList(),
                    ),
    );
  }

  // ── Opens a bottom sheet with full details for the tapped order line ───────
  void _showItemDetail(Map<String, dynamic> line) {
    // Parse all available fields from the order line
    final productName = line['product_name'] as String? ?? 'Unknown';
    // Local SQLite uses 'quantity', Odoo API uses 'qty' — handle both
    final qty = ((line['qty'] ?? line['quantity']) as num?)?.toDouble() ?? 0;
    // Local SQLite uses 'price', Odoo API uses 'price_unit' — handle both
    final priceUnit =
        ((line['price_unit'] ?? line['price']) as num?)?.toDouble() ?? 0;
    final discount = (line['discount'] as num?)?.toDouble() ?? 0;

    // BUG FIX: Old SQLite rows have price_subtotal / price_subtotal_incl = 0.0
    // (DEFAULT from migration), not null. The ?? operator only fires on null,
    // so those rows always showed $0.00. Fix: check > 0 so fallback fires for
    // both null AND 0.0 — same fix as the items-list display above.
    final rawSub = (line['price_subtotal'] as num?)?.toDouble() ?? 0;
    final priceSubtotal = rawSub > 0 ? rawSub : (priceUnit * qty); // excl. tax

    final rawSubIncl = (line['price_subtotal_incl'] as num?)?.toDouble() ?? 0;
    // Local SQLite has no price_subtotal_incl — fall back to price × qty
    final priceSubtotalIncl = rawSubIncl > 0 ? rawSubIncl : (priceUnit * qty);
    final note = line['note'] as String? ?? '';
    final customerNote = line['customer_note'] as String? ?? '';

    // Parse variant attributes from both API and local SQLite sources.
    // API returns a List<Map>, SQLite stores a JSON string — handle both.
    List<Map<String, String>> variantAttrs = [];
    try {
      final rawAttrs = line['variant_attributes'];
      if (rawAttrs is List && rawAttrs.isNotEmpty) {
        // API response: already a List of maps
        variantAttrs =
            rawAttrs.map((e) => Map<String, String>.from(e as Map)).toList();
      } else if (rawAttrs is String &&
          rawAttrs.isNotEmpty &&
          rawAttrs != '[]') {
        // SQLite response: JSON-encoded string
        final decoded = jsonDecode(rawAttrs) as List?;
        if (decoded != null) {
          variantAttrs =
              decoded.map((e) => Map<String, String>.from(e as Map)).toList();
        }
      }
    } catch (_) {
      variantAttrs = [];
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).padding.bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Drag handle ────────────────────────────────────────────
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Product image banner ──────────────────────────────────────
            // Shows the real product image from Odoo if available.
            // 'image' field is returned by /api/order/<id>/lines as base64.
            // Falls back to a purple icon placeholder when image is absent
            // (same look as before — no layout shift for imageless products).
            Builder(builder: (_) {
              final imageBase64 = line['image'] as String?;
              final hasImage = imageBase64 != null && imageBase64.isNotEmpty;

              return Container(
                width: double.infinity,
                height: 160,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: AppColors.purple.withValues(alpha: 0.20)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // ── Real product image (when available) ──
                    if (hasImage)
                      Positioned.fill(
                        child: ProductImage(
                          imageBase64: imageBase64,
                          fit: BoxFit.contain, // full image visible, no crop
                        ),
                      ),

                    // ── Placeholder (when no image) ───────────
                    if (!hasImage)
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: AppColors.purple.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.inventory_2_outlined,
                                color: AppColors.purple, size: 30),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${AppConfig.currencySymbol}${priceUnit.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: AppColors.purple,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),

                    // ── Price badge overlay (always visible on top of image) ──
                    if (hasImage)
                      Positioned(
                        bottom: 10,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.bg.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: AppColors.purple.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            '${AppConfig.currencySymbol}${priceUnit.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: AppColors.purple,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 18),

            // ── Product name ───────────────────────────────────────────
            Text(
              productName,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Item Details',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),

            // ── Variant attribute chips ────────────────────────────────
            // Shown only for products that have variants (e.g. T-Shirt Red/M).
            // Each chip displays one attribute pair like "Color: Red" or "Size: M".
            if (variantAttrs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: variantAttrs.map((attr) {
                  final attrName =
                      attr['attribute'] ?? attr['attribute_name'] ?? '';
                  final attrValue = attr['value'] ?? attr['value_name'] ?? '';
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppColors.purple.withValues(alpha: 0.40),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          attrName,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Text(
                          ': ',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          attrValue,
                          style: const TextStyle(
                            color: AppColors.purple,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],

            const SizedBox(height: 20),

            // ── Price & quantity info rows ─────────────────────────────
            _itemDetailRow('Quantity', '${qty % 1 == 0 ? qty.toInt() : qty}'),
            _itemDetailRow('Unit Price',
                '${AppConfig.currencySymbol}${priceUnit.toStringAsFixed(2)}'),

            // Discount row — only shown when discount > 0
            if (discount > 0)
              _itemDetailRow(
                'Discount',
                '${discount.toStringAsFixed(2)}%',
                valueColor: AppColors.orangeAlt,
              ),

            _itemDetailRow(
              'Subtotal (excl. tax)',
              '${AppConfig.currencySymbol}${priceSubtotal.toStringAsFixed(2)}',
            ),

            // Total row highlighted in purple
            _itemDetailRow(
              'Total (incl. tax)',
              '${AppConfig.currencySymbol}${priceSubtotalIncl.toStringAsFixed(2)}',
              valueColor: AppColors.purple,
              bold: true,
            ),

            // ── Kitchen Note — only shown when note exists ─────────────
            if (note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.inputBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.sticky_note_2_outlined,
                            color: AppColors.textSecondary, size: 13),
                        SizedBox(width: 5),
                        Text(
                          'Note',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      note,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],

            // ── Customer Note — only shown when customer note exists ────
            if (customerNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.orangeAlt.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.orangeAlt.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.person_outline,
                            color: AppColors.orangeAlt, size: 13),
                        SizedBox(width: 5),
                        Text(
                          'Customer Note',
                          style: TextStyle(
                            color: AppColors.orangeAlt,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      customerNote,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ── Close button ───────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.inputBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppColors.cardBorder),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                ),
                child: const Text(
                  'Close',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── One labeled row inside the item detail sheet ───────────────────────────
  Widget _itemDetailRow(
    String label,
    String value, {
    Color valueColor = AppColors.textPrimary,
    bool bold = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.inputBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────────────
  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _infoRow(IconData icon, String label, String value) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textSecondary, size: 17),
            const SizedBox(width: 10),
            Text(
              label,
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(width: 8),
            // FIX: Removed Spacer(), replaced Flexible with Expanded.
            // Expanded takes all remaining space and constrains the text
            // so long names (e.g. "My Company (San Francisco)") never
            // overflow outside the row.
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}
