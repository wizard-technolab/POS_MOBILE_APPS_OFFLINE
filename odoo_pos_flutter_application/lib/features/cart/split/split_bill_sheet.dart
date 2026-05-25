import 'package:flutter/material.dart';
import '../../../services/app_config.dart';
import '../../../services/cart_service.dart';
import '../cart_theme.dart';
import '../customer/customer_search_sheet.dart';
import '../payment/payment_sheet.dart';
import 'split_models.dart';

class SplitBillSheet extends StatefulWidget {
  const SplitBillSheet({super.key});

  @override
  State<SplitBillSheet> createState() => SplitBillSheetState();
}

class SplitBillSheetState extends State<SplitBillSheet> {
  // Persons list — starts with 2 default persons
  // Persons list — filled from Odoo customer search (empty at start)
  final List<SplitPerson> _persons = [];

  // All cart items flattened for display
  late List<SplitItem> _items;

  @override
  void initState() {
    super.initState();
    _buildItemList();
  }

  // Build flat list from CartService — regular items + combo items
  void _buildItemList() {
    final cart = CartService.instance;
    _items = [
      // Regular cart items
      ...cart.cart.values.map((item) => SplitItem(
            key: item.productId.toString(),
            name: item.name,
            unitPrice: item.price,
            qty: item.qty,
            isCombo: false,
          )),
      // Combo cart items
      ...cart.comboCart.values.map((combo) => SplitItem(
            key: combo.cartKey,
            name: combo.comboName,
            unitPrice: combo.lineTotal,
            qty: 1,
            isCombo: true,
          )),
    ];
  }

  // Open Odoo customer search — selected customer becomes a split person
  Future<void> _addPerson(BuildContext context) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CartTheme.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      // returnMode=true → sheet returns the customer map instead of
      // setting the cart customer
      builder: (_) => const CustomerSearchSheet(returnMode: true),
    );

    if (result == null) return; // user cancelled

    final customerId = result['id'] as int;

    // Prevent adding the same customer twice
    if (_persons.any((p) => p.customerId == customerId)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This customer is already added'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }

    setState(() {
      _persons.add(SplitPerson(
        id: 'p_${customerId}_${DateTime.now().millisecondsSinceEpoch}',
        customerId: customerId,
        name: result['name'] as String? ?? 'Customer',
        phone: result['phone'] as String? ?? '',
      ));
    });
  }

  // Remove a person — unassign their items
  void _removePerson(String personId) {
    setState(() {
      _persons.removeWhere((p) => p.id == personId);
      // Unassign items that were assigned to removed person
      for (final item in _items) {
        if (item.assignedPersonId == personId) {
          item.assignedPersonId = null;
        }
      }
    });
  }

  // Assign an item to a person (tap chip to toggle)
  void _assignItem(String itemKey, String personId) {
    setState(() {
      final item = _items.firstWhere((i) => i.key == itemKey);
      // If already assigned to this person → unassign (toggle off)
      if (item.assignedPersonId == personId) {
        item.assignedPersonId = null;
      } else {
        item.assignedPersonId = personId;
      }
    });
  }

  // Get total for a person (sum of their assigned items, with tax)
  double _personTotal(String personId) {
    final taxRate = CartService.instance.taxRate;
    final subtotal = _items
        .where((i) => i.assignedPersonId == personId)
        .fold(0.0, (s, i) => s + i.lineTotal);
    return double.parse(
        (subtotal + subtotal * taxRate / 100).toStringAsFixed(2));
  }

  // Unassigned items total (with tax)
  double get _unassignedTotal {
    final taxRate = CartService.instance.taxRate;
    final subtotal = _items
        .where((i) => i.assignedPersonId == null)
        .fold(0.0, (s, i) => s + i.lineTotal);
    return double.parse(
        (subtotal + subtotal * taxRate / 100).toStringAsFixed(2));
  }

  bool get _allAssigned => _items.every((i) => i.assignedPersonId != null);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.90,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: CartTheme.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // ── Drag handle ────────────────────────────────
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

            // ── Header ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(children: [
                    Icon(Icons.call_split_rounded,
                        color: CartTheme.purple, size: 22),
                    SizedBox(width: 10),
                    Text('Split Bill',
                        style: TextStyle(
                            color: CartTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                  ]),
                  // Add person button
                  TextButton.icon(
                    onPressed:
                        _persons.length < 8 ? () => _addPerson(context) : null,
                    icon: const Icon(Icons.person_add_rounded,
                        color: CartTheme.purple, size: 16),
                    label: const Text('Add Person',
                        style: TextStyle(
                            color: CartTheme.purple,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Divider(color: CartTheme.cardBorder, height: 1),

            // ── Scrollable body ────────────────────────────
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // ── Persons row or empty hint ─────────────
                  if (_persons.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: CartTheme.inputBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: CartTheme.cardBorder),
                      ),
                      child: const Row(children: [
                        Icon(Icons.person_add_rounded,
                            color: CartTheme.textSecondary, size: 18),
                        SizedBox(width: 10),
                        Text(
                          'Tap "Add Person" to select customers from Odoo',
                          style: TextStyle(
                              color: CartTheme.textSecondary, fontSize: 13),
                        ),
                      ]),
                    )
                  else
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _persons.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final p = _persons[i];
                          final total = _personTotal(p.id);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: CartTheme.purple.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                  color:
                                      CartTheme.purple.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                Text(p.name,
                                    style: const TextStyle(
                                        color: CartTheme.purple,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                if (total > 0) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                      '${AppConfig.currencySymbol}${total.toStringAsFixed(0)}',
                                      style: const TextStyle(
                                          color: CartTheme.textPrimary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700)),
                                ],
                                // Remove person button (keep min 2)
                                if (true) ...[
                                  // always show remove button
                                  const SizedBox(width: 4),
                                  GestureDetector(
                                    onTap: () => _removePerson(p.id),
                                    child: const Icon(Icons.close_rounded,
                                        color: CartTheme.textSecondary,
                                        size: 14),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),

                  // ── Instruction text ──────────────────────
                  const Text(
                    'Tap a person chip on each item to assign who pays for it',
                    style:
                        TextStyle(color: CartTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 12),

                  // ── Item rows ─────────────────────────────
                  ..._items.map((item) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: CartTheme.inputBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: item.assignedPersonId != null
                              ? CartTheme.purple.withValues(alpha: 0.4)
                              : CartTheme.cardBorder,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Item name + price
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  item.qty > 1
                                      ? '${item.name}  ×${item.qty}'
                                      : item.name,
                                  style: const TextStyle(
                                      color: CartTheme.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              Text(
                                '${AppConfig.currencySymbol}${item.lineTotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                    color: CartTheme.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),

                          // Person chips — tap to assign
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: _persons.map((p) {
                              final isSelected = item.assignedPersonId == p.id;
                              return GestureDetector(
                                onTap: () => _assignItem(item.key, p.id),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? CartTheme.purple
                                        : CartTheme.cardBorder,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isSelected)
                                        const Padding(
                                          padding: EdgeInsets.only(right: 4),
                                          child: Icon(Icons.check_rounded,
                                              color: Colors.white, size: 12),
                                        ),
                                      Text(
                                        p.name,
                                        style: TextStyle(
                                          color: isSelected
                                              ? Colors.white
                                              : CartTheme.textSecondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    );
                  }),

                  // ── Summary per person ────────────────────
                  if (_items.any((i) => i.assignedPersonId != null)) ...[
                    const SizedBox(height: 8),
                    const Divider(color: CartTheme.cardBorder),
                    const SizedBox(height: 8),
                    const Text('Summary',
                        style: TextStyle(
                            color: CartTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    ..._persons.map((p) {
                      final pTotal = _personTotal(p.id);
                      final pItems = _items
                          .where((i) => i.assignedPersonId == p.id)
                          .toList();
                      if (pItems.isEmpty) return const SizedBox.shrink();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CartTheme.purple.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: CartTheme.purple.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(p.name,
                                    style: const TextStyle(
                                        color: CartTheme.textPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)),
                                Text(
                                    '${AppConfig.currencySymbol}${pTotal.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        color: CartTheme.purple,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // List of assigned items
                            ...pItems.map((i) => Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '• ${i.name}  ${AppConfig.currencySymbol}${i.lineTotal.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        color: CartTheme.textSecondary,
                                        fontSize: 12),
                                  ),
                                )),
                          ],
                        ),
                      );
                    }),

                    // Unassigned amount warning
                    if (_unassignedTotal > 0)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CartTheme.orange.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: CartTheme.orange.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: CartTheme.orange, size: 16),
                              SizedBox(width: 6),
                              Text('Unassigned',
                                  style: TextStyle(
                                      color: CartTheme.orange, fontSize: 13)),
                            ]),
                            Text(
                                '${AppConfig.currencySymbol}${_unassignedTotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                    color: CartTheme.orange,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 80), // space for bottom button
                ],
              ),
            ),

            // ── Bottom: Proceed to Payment ─────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              decoration: BoxDecoration(
                color: CartTheme.card,
                border: Border(top: BorderSide(color: CartTheme.cardBorder)),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context); // close split sheet
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: CartTheme.card,
                      shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(24))),
                      builder: (_) => const PaymentSheet(),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CartTheme.purple,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: Text(
                    _allAssigned
                        ? 'Proceed to Payment'
                        : 'Proceed to Payment  •  ${AppConfig.currencySymbol}${_unassignedTotal.toStringAsFixed(2)} unassigned',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
} // ═══════════════════════════════════════════════════════════════════════════
// SPLIT FLOW — Sequential Item-wise Split
//
// User flow:
//   Cart → Split Button (3-dot menu)
//   ↓
//   [Full product list shown — all remaining items from main cart]
//   Person 1 selects their items with +/− qty buttons
//   Person 1 optionally picks a customer (Walk-in if skipped)
//   ↓
//   Payment screen → Cash or Bank → Pay ${AppConfig.currencySymbol}X → Done ✓
//   ↓
//   Remaining items automatically shown for Person 2
//   Person 2 selects/adjusts → Customer → Payment → Done ✓
//   ↓
//   Continue until all items are paid → final success → cart cleared
//
// API used: POST /api/order/split  (split_order_api.py)
// Each person creates one sub-order with the same split_group_id.
// ═══════════════════════════════════════════════════════════════════════════
