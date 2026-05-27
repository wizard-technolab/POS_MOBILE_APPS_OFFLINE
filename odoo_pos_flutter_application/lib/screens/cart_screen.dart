import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/product_image.dart';
import '../widgets/top_notification.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart'; // add uuid to pubspec.yaml
import '../services/cart_service.dart';
import '../services/app_config.dart';
import '../data/repositories/order_repository.dart';
import '../models/combo_model.dart';
import '../widgets/combo_selection_sheet.dart';
import '../services/product_cache.dart';
import '../features/cart/actions/cart_actions_sheet.dart';
import '../features/cart/customer/customer_search_sheet.dart';
import '../features/cart/notes/combo_note_sheet.dart';
import '../features/cart/notes/product_note_sheet.dart';
import '../features/cart/payment/payment_sheet.dart';
import '../features/cart/split/split_flow_sheet.dart';

// ─────────────────────────────────────────────────
// COLORS  (same as rest of app)
// ─────────────────────────────────────────────────
const _kBg = Color(0xFF0D0F1C);
const _kCard = Color(0xFF151828);
const _kCardBorder = Color(0xFF1E2235);
const _kPurple = Color(0xFF6C63FF);
const _kPurpleLight = Color(0xFF8B83FF);
const _kGreen = Color(0xFF1DB954);
const _kOrange = Color(0xFFE8A020);
const _kRed = Color(0xFFE53935);
const _kTextPrimary = Color(0xFFFFFFFF);
const _kTextSecondary = Color(0xFF8B90A7);
const _kInputBg = Color(0xFF1A1D2E);

// ─────────────────────────────────────────────────
// CART SCREEN
// ─────────────────────────────────────────────────
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _cart = CartService.instance;
  String _selectedCategory = 'All';
  Timer? _autoSyncTimer;

  @override
  void initState() {
    super.initState();
    // Reset UI state (category filter) when session changes.
    // Cart clearing itself is handled in main.dart via sessionChangeNotifier.
    sessionChangeNotifier.addListener(_onSessionChanged);
    // Listen to structural changes only (items added/removed).
    // Qty changes fire cartNotifier — handled inside each item card's own
    // ValueListenableBuilder, NOT here. This prevents full-screen rebuild on + tap.
    _cart.cartVersionNotifier.addListener(_onCartStructureChanged);

    // ── Auto-sync listeners for editing pending orders ──
    _cart.cartNotifier.addListener(_triggerAutoSync);
    _cart.comboCartNotifier.addListener(_triggerAutoSync);
    _cart.customerNotifier.addListener(_triggerAutoSync);
    _cart.customerNoteNotifier.addListener(_triggerAutoSync);
  }

  void _onSessionChanged() {
    if (mounted) {
      setState(() {
        _selectedCategory = 'All'; // reset category filter chip
      });
    }
  }

  // Called only when items are added or removed — NOT on qty change.
  // Rebuilds category chips, empty state, header item count.
  void _onCartStructureChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sessionChangeNotifier.removeListener(_onSessionChanged);
    _cart.cartVersionNotifier.removeListener(_onCartStructureChanged);
    _cart.cartNotifier.removeListener(_triggerAutoSync);
    _cart.comboCartNotifier.removeListener(_triggerAutoSync);
    _cart.customerNotifier.removeListener(_triggerAutoSync);
    _cart.customerNoteNotifier.removeListener(_triggerAutoSync);
    _autoSyncTimer?.cancel();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Read cart data directly from notifier values.
    // Structural changes (add/remove items) trigger setState via
    // cartVersionNotifier listener in initState.
    // Qty changes (+ / -) are handled reactively inside each item card's
    // own ValueListenableBuilder — so no full-screen rebuild on qty tap.
    final regularItems = _cart.cart.values.toList();
    final comboItems = _cart.comboCart.values.toList();
    final totalCount = regularItems.length + comboItems.length;

    // Build category list from all items in cart
    final catSet = <String>{};
    for (final item in regularItems) {
      if (item.category.isNotEmpty) catSet.add(item.category);
    }
    if (comboItems.isNotEmpty) catSet.add('Combos');

    final categories = <String>[
      'All',
      // Combos always first, rest alphabetical
      ...catSet.toList()
        ..sort((a, b) => a == 'Combos'
            ? -1
            : b == 'Combos'
                ? 1
                : a.compareTo(b)),
    ];

    // Reset filter if that category no longer exists
    if (!categories.contains(_selectedCategory)) {
      _selectedCategory = 'All';
    }

    // Apply filter
    final filteredRegular =
        _selectedCategory == 'All' || _selectedCategory != 'Combos'
            ? (_selectedCategory == 'All'
                ? regularItems
                : regularItems
                    .where((i) => i.category == _selectedCategory)
                    .toList())
            : <CartItem>[];

    final filteredCombos =
        _selectedCategory == 'All' || _selectedCategory == 'Combos'
            ? comboItems
            : <ComboCartItem>[];

    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: _kPurple,
          backgroundColor: _kCard,
          onRefresh: () async {
            // Force a rebuild to re-read cart state
            setState(() {});
          },
          child: Column(
            children: [
              _buildHeader(totalCount),
              _buildCustomerCard(),
              // Show customer note below customer card — reactive, no refresh needed
              _buildCustomerNoteCard(),
              const SizedBox(height: 8),
              // Show filter chips only when 2+ categories exist
              if (totalCount > 0 && categories.length > 2)
                _buildCategoryChips(categories, regularItems, comboItems),
              totalCount == 0
                  ? _buildEmptyState()
                  : Expanded(
                      child: _buildItemList(filteredRegular, filteredCombos),
                    ),
              if (totalCount > 0) _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(int itemCount) {
    final isEditing = _cart.editingPendingLocalId != null;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // Highlight background when editing a restored draft
        color:
            isEditing ? _kPurple.withValues(alpha: 0.12) : Colors.transparent,
        border: isEditing
            ? const Border(bottom: BorderSide(color: _kPurple, width: 0.5))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── TOP ROW ─────────────────────────
            Row(
              children: [
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Current Order',
                      style: TextStyle(
                        color: _kTextPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isEditing)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            const Icon(Icons.edit_note_rounded,
                                color: _kPurpleLight, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'Editing Pending Order',
                              style: TextStyle(
                                color: _kPurpleLight,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                if (itemCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _kPurple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: _kPurple.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '$itemCount item${itemCount > 1 ? 's' : ''}',
                      style: const TextStyle(
                        color: _kPurpleLight,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 4),

            // ── POS SESSION DISPLAY (same style as product screen) ───
            FutureBuilder<String>(
              future: AppConfig.getPosSessionName(),
              builder: (_, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const SizedBox.shrink();
                }

                if (snap.data?.isNotEmpty ?? false) {
                  // Session active — show green icon + name
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.point_of_sale_rounded,
                          color: _kGreen,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          snap.data!,
                          style: const TextStyle(
                            color: _kGreen,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                // No session — show orange warning (same as product screen)
                return const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No POS session selected',
                    style: TextStyle(
                      color: _kOrange,
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Category Filter Chips ─────────────────────────────────
  Widget _buildCategoryChips(
    List<String> categories,
    List<CartItem> regularItems,
    List<ComboCartItem> comboItems,
  ) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final cat = categories[i];
          final selected = _selectedCategory == cat;

          // Count items per category for the badge number
          int count;
          if (cat == 'All') {
            count = regularItems.length + comboItems.length;
          } else if (cat == 'Combos') {
            count = comboItems.length;
          } else {
            count = regularItems.where((item) => item.category == cat).length;
          }

          return GestureDetector(
            onTap: () => setState(() => _selectedCategory = cat),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? _kPurple : _kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: selected ? _kPurple : _kCardBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    cat,
                    style: TextStyle(
                      color: selected ? _kTextPrimary : _kTextSecondary,
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.25)
                          : _kCardBorder,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: selected ? _kTextPrimary : _kTextSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Customer Card ─────────────────────────────────
  Widget _buildCustomerCard() {
    return ValueListenableBuilder(
      valueListenable: _cart.customerNotifier,
      builder: (_, customer, __) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kCardBorder),
            ),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _kPurple,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  child: customer != null
                      ? Center(
                          child: Text(
                            customer.name.isNotEmpty
                                ? customer.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : const Icon(Icons.person_outline_rounded,
                          color: _kTextPrimary, size: 20),
                ),
                const SizedBox(width: 12),
                // Name / Phone
                Expanded(
                  child: customer != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              customer.name,
                              style: const TextStyle(
                                color: _kTextPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            if (customer.phone.isNotEmpty)
                              Text(
                                customer.phone,
                                style: const TextStyle(
                                  color: _kTextSecondary,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        )
                      : const Text(
                          'No customer selected',
                          style:
                              TextStyle(color: _kTextSecondary, fontSize: 14),
                        ),
                ),
                // Change button
                GestureDetector(
                  onTap: () => _showCustomerSheet(),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _kPurple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      customer != null ? 'Change' : 'Select',
                      style: const TextStyle(
                        color: _kPurpleLight,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Customer Note Card ────────────────────────────
  // Shows saved customer note below customer card — updates instantly via
  // ValueListenableBuilder without any refresh needed.
  Widget _buildCustomerNoteCard() {
    return ValueListenableBuilder<String>(
      valueListenable: _cart.customerNoteNotifier,
      builder: (_, note, __) {
        // Hide widget completely when no note is saved
        if (note.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              // Warm yellow-orange tint — same as product note style
              color: _kOrange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kOrange.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.sticky_note_2_outlined,
                    color: _kOrange, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    note,
                    style: const TextStyle(
                      color: _kOrange,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Tap X to clear note quickly without opening dialog
                GestureDetector(
                  onTap: () => _cart.setCustomerNote(''),
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.close_rounded, color: _kOrange, size: 16),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Empty State ──────────────────────────────────
  Widget _buildEmptyState() {
    // FIX: Wrap in Expanded + ListView (physics: AlwaysScrollableScrollPhysics)
    // so the RefreshIndicator can detect pull gesture even when cart is empty.
    // Without a scrollable child, RefreshIndicator never fires on an empty cart.
    return Expanded(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 300, // enough height to allow pull gesture
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shopping_cart_outlined,
                      color: _kTextSecondary.withValues(alpha: 0.4), size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'Your cart is empty',
                    style: TextStyle(color: _kTextSecondary, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add products from the Products tab',
                    style: TextStyle(color: _kTextSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Item List ────────────────────────────────────
  Widget _buildItemList(
      List<CartItem> regularItems, List<ComboCartItem> comboItems) {
    if (regularItems.isEmpty && comboItems.isEmpty) {
      return Expanded(
        child: Center(
          child: Text(
            'No items in "$_selectedCategory"',
            style: const TextStyle(color: _kTextSecondary, fontSize: 14),
          ),
        ),
      );
    }

    final colors = [
      const Color(0xFF2D4A3E),
      const Color(0xFF2A2D4E),
      const Color(0xFF4A2D2D),
      const Color(0xFF3E3A2D),
      const Color(0xFF2D3A4A),
    ];
    final icons = [
      Icons.fastfood_rounded,
      Icons.local_cafe_rounded,
      Icons.restaurant_rounded,
      Icons.lunch_dining_rounded,
      Icons.local_pizza_rounded,
    ];

    // NOTE: RefreshIndicator is now at the top level (wrapping the full screen
    // Column), so no inner RefreshIndicator needed here. The ListView just
    // needs AlwaysScrollableScrollPhysics so the pull gesture always works.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      children: [
        // Combo items first (orange border)
        ...comboItems.map((item) => _buildComboCard(item)),
        // Regular items below
        ...regularItems.map((item) {
          final color = colors[item.productId % colors.length];
          final icon = icons[item.productId % icons.length];
          return _buildRegularCard(item, color, icon);
        }),
      ],
    );
  }

  Widget _buildComboCard(ComboCartItem item) {
    // Flatten all selected choices into one list for display
    final selectedChoices = item.selection.selectedChoices.values
        .expand((choices) => choices)
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        // Orange border distinguishes combo from regular items
        border: Border.all(color: _kOrange.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: icon + name + qty controls
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Color(0xFF3E2A0A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.fastfood_rounded,
                    color: _kOrange, size: 24),
              ),
              const SizedBox(width: 12),
              // Name, note, qty all inside one ValueListenableBuilder so
              // note updates (and qty changes) both trigger reactive rebuild.
              Expanded(
                child: ValueListenableBuilder<Map<String, ComboCartItem>>(
                  valueListenable: _cart.comboCartNotifier,
                  builder: (_, comboMap, __) {
                    final currentCombo = comboMap[item.cartKey];
                    final currentQty = currentCombo?.qty ?? 0;
                    // Read kitchen note from live comboMap — not from stale item param
                    final currentNote = currentCombo?.note ?? '';
                    // Read customer note separately — shown in blue below kitchen note
                    final currentCustomerNote =
                        currentCombo?.customerNote ?? '';

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Name + price + note column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _kOrange,
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Text('COMBO',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.5)),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(item.comboName,
                                        style: const TextStyle(
                                            color: _kTextPrimary,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              // Combo price + GST badge (if combo has tax from Odoo)
                              Row(
                                children: [
                                  Text(
                                    '${AppConfig.currencySymbol}${item.unitPrice.toStringAsFixed(0)} × $currentQty',
                                    style: const TextStyle(
                                        color: _kTextSecondary, fontSize: 12),
                                  ),
                                  // Show GST badge using combo's own taxRate from Odoo
                                  if (item.taxRate > 0) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: _kOrange.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color:
                                              _kOrange.withValues(alpha: 0.4),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        'GST ${item.taxRate.toStringAsFixed(0)}%',
                                        style: const TextStyle(
                                          color: _kOrange,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              // Kitchen note reads from live comboMap — updates instantly
                              if (currentNote.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  '📝 $currentNote',
                                  style: const TextStyle(
                                    color: _kOrange,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              // Customer note — shown in blue, separate from kitchen note
                              // Tap to edit directly from the cart tile
                              if (currentCustomerNote.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                GestureDetector(
                                  onTap: () => _showComboCustomerNoteSheet(
                                      context,
                                      CartService.instance
                                              .comboCart[item.cartKey] ??
                                          item),
                                  child: Text(
                                    '👤 $currentCustomerNote',
                                    style: const TextStyle(
                                      color: Colors.lightBlueAccent,
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      decoration: TextDecoration.underline,
                                      decorationColor: Colors.lightBlueAccent,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        // Qty controls
                        _qtyBtn(
                          icon: Icons.remove_rounded,
                          bg: _kInputBg,
                          border: true,
                          onTap: () => _cart.decreaseComboQty(item.cartKey),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text('$currentQty',
                              style: const TextStyle(
                                  color: _kTextPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ),
                        _qtyBtn(
                          icon: Icons.add_rounded,
                          bg: _kPurple,
                          border: false,
                          onTap: () => _cart.increaseComboQty(item.cartKey),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),

          // Selected items breakdown
          if (selectedChoices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(width: double.infinity, height: 1, color: _kCardBorder),
            const SizedBox(height: 8),
            const Text('INCLUDED ITEMS',
                style: TextStyle(
                    color: _kTextSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8)),
            const SizedBox(height: 6),
            ...selectedChoices.map(
              (choice) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: choice.extraPrice > 0 ? _kOrange : _kGreen,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(choice.productName,
                          style: const TextStyle(
                              color: _kTextSecondary, fontSize: 12)),
                    ),
                    if (choice.extraPrice > 0)
                      Text(
                          '+${AppConfig.currencySymbol}${choice.extraPrice.toStringAsFixed(0)}',
                          style: const TextStyle(
                              color: _kOrange,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Edit button — re-opens combo selection sheet
                GestureDetector(
                  onTap: () => _editComboItem(item),
                  child: const Text('Edit',
                      style: TextStyle(
                          color: _kOrange,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                Text(
                  'Total: ${AppConfig.currencySymbol}${item.lineTotal.toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRegularCard(CartItem item, Color color, IconData icon) {
    // Long press on cart item tile → opens note sheet directly for that product
    // No extra product selector step — tap the product you want to note
    return GestureDetector(
      onLongPress: () => _showProductNoteSheet(context, item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kCardBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon — tap to add/edit note for this product
            GestureDetector(
              onTap: () => _showProductNoteSheet(
                  context, CartService.instance.cart[item.productId] ?? item),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: item.image != null && item.image!.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: ProductImage(
                              imageBase64: item.image,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(icon, color: Colors.white70, size: 20),
                  ),
                  ...(item.image != null && item.image!.isNotEmpty
                      ? [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: ProductImage(
                              imageBase64: item.image,
                              width: 40,
                              height: 40,
                              fit: BoxFit
                                  .cover, // contain: full image visible, no crop
                            ),
                          ),
                        ]
                      : [])
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Name, note, qty all inside one ValueListenableBuilder so
            // note updates (and qty changes) both trigger reactive rebuild
            // without needing a full screen setState.
            Expanded(
              child: ValueListenableBuilder<Map<int, CartItem>>(
                valueListenable: CartService.instance.cartNotifier,
                builder: (_, cartMap, __) {
                  final currentItem = cartMap[item.productId];
                  final currentQty = currentItem?.qty ?? 0;
                  final currentLineTotal = currentItem?.lineTotal ?? 0.0;
                  // Read kitchen note from live cartMap — not from stale item param
                  final currentNote = currentItem?.note ?? '';
                  // Read customer note separately — shown in blue below kitchen note
                  final currentCustomerNote = currentItem?.customerNote ?? '';

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Name + price + note column
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize
                              .min, // Prevent overflow from GST badge row
                          children: [
                            Text(
                              item.name,
                              style: const TextStyle(
                                color: _kTextPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Show variant attribute chips (e.g. Color: Red | Size: M)
                            // Only rendered when this cart item has variant attributes stored
                            if (item.variantAttributes.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                runSpacing: 3,
                                children: item.variantAttributes.map((attr) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _kPurple.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: _kPurple.withValues(alpha: 0.35),
                                        width: 0.5,
                                      ),
                                    ),
                                    child: Text(
                                      '${attr['attribute']}: ${attr['value']}',
                                      style: const TextStyle(
                                        color: _kPurple,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                            const SizedBox(height: 3),
                            // GST badge on its own line — only when product has tax from Odoo
                            if (item.taxRate > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: _kPurpleLight.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: _kPurpleLight.withValues(alpha: 0.4),
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  'GST ${item.taxRate.toStringAsFixed(0)}%',
                                  style: const TextStyle(
                                    color: _kPurpleLight,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 2),
                            // Price per unit — shown below the GST badge
                            Text(
                              '${AppConfig.currencySymbol}${item.price.toStringAsFixed(0)} each',
                              style: const TextStyle(
                                color: _kTextSecondary,
                                fontSize: 11,
                              ),
                            ),
                            // Kitchen note updates instantly — tap text to edit directly
                            if (currentNote.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              GestureDetector(
                                onTap: () => _showProductNoteSheet(
                                    context,
                                    CartService.instance.cart[item.productId] ??
                                        item),
                                child: Text(
                                  '📝 $currentNote',
                                  style: const TextStyle(
                                    color: _kOrange,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    decoration: TextDecoration.underline,
                                    decorationColor: _kOrange,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            // Customer note — shown in blue, separate from kitchen note
                            // Tap to edit directly from the cart tile
                            if (currentCustomerNote.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              GestureDetector(
                                onTap: () => _showProductCustomerNoteSheet(
                                    context,
                                    CartService.instance.cart[item.productId] ??
                                        item),
                                child: Text(
                                  '👤 $currentCustomerNote',
                                  style: const TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.lightBlueAccent,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Qty controls
                      _qtyBtn(
                        icon: Icons.remove_rounded,
                        onTap: () =>
                            CartService.instance.removeItem(item.productId),
                        bg: _kInputBg,
                        border: true,
                      ),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '$currentQty',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _kTextPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _qtyBtn(
                        icon: Icons.add_rounded,
                        onTap: () => CartService.instance
                            .increaseItemQty(item.productId),
                        bg: _kPurple,
                        border: false,
                      ),
                      const SizedBox(width: 10),
                      // Line total
                      SizedBox(
                        width: 60,
                        child: Text(
                          '${AppConfig.currencySymbol}${currentLineTotal.toStringAsFixed(0)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: _kPurpleLight,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ), // closes GestureDetector.child Container
    );
  }

  Future<void> _editComboItem(ComboCartItem item) async {
    final product = ProductCache.instance.get(item.comboProductId);
    if (product == null || !product.isCombo || product.comboGroups.isEmpty) {
      _cart.removeComboItem(item.cartKey);
      setState(() {});
      if (mounted) {
        showTopNotification(
          context,
          'Please re-add the combo from Products screen.',
          color: _kOrange,
          icon: Icons.warning_amber_rounded,
        );
      }
      return;
    }

    // Save the original item before removing it from the cart.
    // This allows us to restore it if the user cancels the edit sheet.
    final originalItem = item;

    // Temporarily remove the item so the edit sheet starts with a clean state
    _cart.removeComboItem(item.cartKey);
    setState(() {});
    final newKey =
        await showComboSelectionSheet(context, product.toComboProduct());
    if (newKey != null && mounted) {
      setState(() {});
      showTopNotification(
        context,
        '${item.comboName} updated',
        color: _kGreen,
        icon: Icons.check_circle_rounded,
      );
    } else {
      // User cancelled (back button / dismissed sheet without saving).
      // Restore the original item back into the cart exactly as it was.
      _cart.addComboItem(originalItem);
      setState(() {});
    }
  }

  Widget _qtyBtn({
    required IconData icon,
    required VoidCallback onTap,
    required Color bg,
    required bool border,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: border ? Border.all(color: _kCardBorder) : null,
        ),
        child: Icon(icon, color: _kTextPrimary, size: 16),
      ),
    );
  }

  // ── Auto-sync logic for editing existing pending orders ─────────────────
  void _triggerAutoSync() {
    // Only sync if we are editing an existing order
    if (_cart.editingPendingExternalId == null) return;

    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;

      // Check if order should be cancelled (empty cart)
      if (_cart.totalItemCount == 0) {
        _cancelOrder();
      } else {
        _performAutoSync();
      }
    });
  }

  Future<void> _performAutoSync() async {
    final externalId = _cart.editingPendingExternalId;
    if (externalId == null) return;

    try {
      final baseUrl = await AppConfig.getServerUrl();
      final token = await AppConfig.getApiToken();
      final deviceCode = await AppConfig.getDeviceCode();
      final sessionId = await AppConfig.getPosSessionId();

      final companyName = await AppConfig.getCompanyName();
      if (deviceCode.isEmpty) return;

      // Build lines payload
      final lines = [
        ..._cart.cart.values.map((item) => {
              'product_id': item.productId,
              'qty': item.qty,
              'price': item.price,
              'tax_rate': item.taxRate,
              if (item.note.isNotEmpty) 'note': item.note,
              if (item.customerNote.isNotEmpty)
                'customer_note': item.customerNote,
              'product_name': item.name,
              'image': item.image,
            }),
        ..._cart.comboCart.values
            .expand((combo) => combo.toOrderLines(taxRate: _cart.taxRate)),
      ];

      // Check connectivity
      bool isOnline = false;
      if (baseUrl.isNotEmpty) {
        try {
          final healthCheck = await http
              .get(Uri.parse('$baseUrl/web/health'))
              .timeout(const Duration(seconds: 5));
          isOnline = healthCheck.statusCode == 200;
        } catch (_) {}
      }

      if (!isOnline) {
        final orderRepo = OrderRepository();
        final customerId = _cart.customerNotifier.value?.id ?? 0;
        final customerName = _cart.customerNotifier.value?.name ?? 'Walk-in';

        final localLines = [
          ..._cart.cart.values.map((item) => {
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
          ..._cart.comboCart.values
              .expand((combo) => combo.toOrderLines(taxRate: _cart.taxRate)),
        ];

        // OFFLINE AUTO-SYNC FIX:
        // When a pending/held order is restored with "Add back to cart", every
        // cart change schedules this auto-sync. The old code always created a
        // NEW offline draft here, which consumed the next sequence number
        // (00005, 00006, ...) and left the restored order visible as pending.
        // In edit mode we must update the selected SQLite row in place.
        if (_cart.editingPendingLocalId != null) {
          await orderRepo.updateOfflineOrder(
            orderId: _cart.editingPendingLocalId!,
            lines: localLines,
            total: _cart.total,
            taxAmount: _cart.taxAmount,
            customerId: customerId,
            customerName: customerName,
            customerNote: _cart.customerNoteNotifier.value,
            status: 'draft',
            synced: 0,
          );
          debugPrint(
            '✅ Offline auto-sync updated existing restored order '
            '${_cart.editingPendingLocalId} without creating a new sequence',
          );
        } else {
          await orderRepo.createOfflineOrder(
            externalId: externalId,
            deviceCode: deviceCode,
            customerId: customerId,
            customerName: customerName,
            customerNote: _cart.customerNoteNotifier.value,
            sessionId: sessionId,
            lines: localLines,
            total: _cart.total,
            taxAmount: _cart.taxAmount,
            status: 'draft',
            companyName: companyName,
          );
        }
      } else {
        final payload = {
          'external_id': externalId,
          'session_id': sessionId,
          'device_code': deviceCode,
          if (_cart.customerNotifier.value != null)
            'customer_id': _cart.customerNotifier.value!.id,
          if (_cart.customerNoteNotifier.value.isNotEmpty)
            'customer_note': _cart.customerNoteNotifier.value,
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
            .timeout(const Duration(seconds: 15));

        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.contains('application/json')) {
          throw Exception(
              'Server returned an unexpected response (HTTP ${response.statusCode}).');
        }

        final data = jsonDecode(response.body);
        if (data['status'] != 'success') {
          throw Exception(
              data['message'] ?? 'Failed to update draft order on server.');
        }
        debugPrint('✅ Draft order auto-synced to Odoo: ${data['data']}');
      }
    } catch (e) {
      debugPrint('⚠️ Auto-sync draft failed: $e');
    }
  }

  // ── Bottom Bar ───────────────────────────────────
  Widget _buildBottomBar() {
    // Wrap in ValueListenableBuilder so subtotal / tax / total update
    // reactively when qty changes — without triggering a full-screen setState.
    return ValueListenableBuilder<Map<int, CartItem>>(
      valueListenable: _cart.cartNotifier,
      builder: (_, __, ___) =>
          ValueListenableBuilder<Map<String, ComboCartItem>>(
        valueListenable: _cart.comboCartNotifier,
        builder: (_, __, ___) => Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: _kCard,
            border: Border(top: BorderSide(color: _kCardBorder)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Subtotal
              _summaryRow(
                label: 'Subtotal (${_cart.totalItemCount} items)',
                value:
                    '${AppConfig.currencySymbol}${_cart.subtotal.toStringAsFixed(2)}',
                valueColor: _kTextPrimary,
              ),
              const SizedBox(height: 6),
              // Tax — label shows blended rate only when all items share same rate,
              // otherwise shows "GST" to avoid showing misleading single percentage.
              // Actual taxAmount is always calculated per-product from Odoo tax rates.
              _summaryRow(
                label: () {
                  final rates = CartService.instance.cart.values
                      .map((i) => i.taxRate)
                      .toSet();
                  // If all products have same rate → show it (e.g. "Tax (18% GST)")
                  // If mixed rates → show just "Tax (GST)" to avoid confusion
                  if (rates.length == 1 && rates.first > 0) {
                    return 'Tax (${rates.first.toStringAsFixed(0)}% GST)';
                  }
                  return 'Tax (GST)';
                }(),
                value:
                    '${AppConfig.currencySymbol}${_cart.taxAmount.toStringAsFixed(2)}',
                valueColor: _kTextSecondary,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(color: _kCardBorder, height: 1),
              ),
              // Total
              Row(
                children: [
                  const Text(
                    'Total',
                    style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${AppConfig.currencySymbol}${_cart.total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: _kPurpleLight,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Payment row: "Proceed to Payment" button + 3-dot actions menu
              Row(
                children: [
                  // Main payment button — takes most of the width
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _proceedToPayment(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kPurple,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Proceed to Payment',
                        style: TextStyle(
                          color: _kTextPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 3-dot actions menu button
                  GestureDetector(
                    onTap: () => _showActionsSheet(context),
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: _kCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _kCardBorder),
                      ),
                      child: const Icon(
                        Icons.more_vert_rounded,
                        color: _kTextPrimary,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ), // end inner Container
      ), // end comboCartNotifier builder
    ); // end cartNotifier builder
  }

  Widget _summaryRow({
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(label,
              style: const TextStyle(color: _kTextSecondary, fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Text(value,
            style: TextStyle(
                color: valueColor, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ── Actions Sheet (3-dot menu) ──────────────────────
  // Shows: Note (per product), Customer Note, Cancel Order
  void _showActionsSheet(BuildContext context) {
    CartActionsSheet.show(
      context,
      CartActionsHandlers(
        onProductNote: () => _showProductNoteSelector(context),
        onCustomerNotePerProduct: () =>
            _showProductCustomerNoteSelector(context),
        onSplitBill: () => _showSplitSheet(context),
        onCancelOrder: () => _confirmCancelOrder(context),
      ),
    );
  }

  // ── Split Bill Sheet ──────────────────────────────────
  // Opens the split bill bottom sheet with the current cart total.
  void _showSplitSheet(BuildContext context) {
    final totalItems = _cart.totalItemCount;

    // Split makes no sense with a single item — show a friendly message instead
    if (totalItems <= 1) {
      showTopNotification(
        context,
        'Add at least 2 items to use Split Bill.',
        color: _kOrange,
        icon: Icons.info_outline_rounded,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const SplitFlowSheet(),
    );
  }

  // ── Product Note Selector ─────────────────────────────
  // Step 1: Show list of ALL cart items (regular + combo) — user taps one to add a note
  // title param: used by Customer Note button to show "Add Customer Note" heading
  void _showProductNoteSelector(BuildContext context,
      {String title = 'Select Product', String noteLabel = 'Add Note'}) {
    final regularItems = _cart.cart.values.toList();
    final comboItems = _cart.comboCart.values.toList();
    final totalItems = regularItems.length + comboItems.length;

    if (totalItems == 0) return;

    // If only one item total, skip selector and go straight to note sheet
    if (totalItems == 1) {
      if (regularItems.isNotEmpty) {
        _showProductNoteSheet(context, regularItems.first,
            noteLabel: noteLabel);
      } else {
        _showComboNoteSheet(context, comboItems.first, noteLabel: noteLabel);
      }
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                      color: _kCardBorder,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title, // 'Select Product' or 'Add Customer Note'
                    style: TextStyle(
                        color: _kTextPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const Divider(color: _kCardBorder, height: 1),
              // Combined list: combo items first, then regular items
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: totalItems,
                separatorBuilder: (_, __) =>
                    const Divider(color: _kCardBorder, height: 1),
                itemBuilder: (_, i) {
                  // Combo items shown first in list
                  if (i < comboItems.length) {
                    final combo = comboItems[i];
                    return ListTile(
                      leading: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _kOrange,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text('COMBO',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800)),
                      ),
                      title: Text(
                        combo.comboName,
                        style: const TextStyle(
                            color: _kTextPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                      ),
                      subtitle: combo.note.isNotEmpty
                          ? Text(
                              combo.note,
                              style: const TextStyle(
                                  color: _kTextSecondary, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: _kTextSecondary),
                      onTap: () {
                        Navigator.pop(context); // close selector
                        _showComboNoteSheet(context, combo,
                            noteLabel: noteLabel);
                      },
                    );
                  }
                  // Regular items below combos
                  final item = regularItems[i - comboItems.length];
                  return ListTile(
                    title: Text(
                      item.name,
                      style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                    subtitle: item.note.isNotEmpty
                        ? Text(
                            item.note,
                            style: const TextStyle(
                                color: _kTextSecondary, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: const Icon(Icons.chevron_right_rounded,
                        color: _kTextSecondary),
                    onTap: () {
                      Navigator.pop(context); // close product selector
                      _showProductNoteSheet(context, item,
                          noteLabel: noteLabel);
                    },
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── Combo Note Sheet ──────────────────────────────────
  // Opens Odoo-style note sheet for a combo item (uses cartKey to update)
  void _showComboNoteSheet(BuildContext context, ComboCartItem combo,
      {String noteLabel = 'Add Note'}) {
    const presetTags = ['Wait', 'To Serve', 'Emergency', 'No Dressing'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => ComboNoteSheet(
        combo: combo,
        presetTags: presetTags,
        noteLabel: noteLabel, // 'Add Note' or 'Add Customer Note'
        onApply: (note) {
          // Save note to combo cart — uses cartKey (uuid) for exact match
          _cart.updateComboNote(combo.cartKey, note);
        },
      ),
    );
  }

  // ── Product Note Sheet ────────────────────────────────
  // Step 2: Odoo-style note sheet with preset tags + free text input
  void _showProductNoteSheet(BuildContext context, CartItem item,
      {String noteLabel = 'Add Note'}) {
    // Preset note tags — same style as Odoo POS
    const presetTags = ['Wait', 'To Serve', 'Emergency', 'No Dressing'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => ProductNoteSheet(
        item: item,
        presetTags: presetTags,
        noteLabel: noteLabel, // 'Add Note' or 'Add Customer Note'
        onApply: (note) {
          // Save note to cart — updates cartNotifier reactively
          _cart.updateItemNote(item.productId, note);
        },
      ),
    );
  }

  // ── Product Customer Note Selector ──────────────────────────────────────
  // Shows list of all cart items — user taps one to add a customer note
  // Separate from kitchen note selector (_showProductNoteSelector)
  void _showProductCustomerNoteSelector(BuildContext context) {
    final regularItems = _cart.cart.values.toList();
    final comboItems = _cart.comboCart.values.toList();

    // If only one item total, skip selector and go straight to note sheet
    if (regularItems.length + comboItems.length == 1) {
      if (regularItems.isNotEmpty) {
        _showProductCustomerNoteSheet(context, regularItems.first);
      } else {
        _showComboCustomerNoteSheet(context, comboItems.first);
      }
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select Product',
                  style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Choose which product to add customer note to',
                  style: TextStyle(color: _kTextSecondary, fontSize: 12)),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  children: [
                    // Combo items listed first
                    ...comboItems.map((combo) => ListTile(
                          title: Text(combo.comboName,
                              style: const TextStyle(color: _kTextPrimary)),
                          // Show existing customer note as subtitle preview
                          subtitle: combo.customerNote.isNotEmpty
                              ? Text('👤 ${combo.customerNote}',
                                  style: const TextStyle(
                                      color: Colors.lightBlueAccent,
                                      fontSize: 11))
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            _showComboCustomerNoteSheet(context, combo);
                          },
                        )),
                    // Regular items listed after combos
                    ...regularItems.map((item) => ListTile(
                          title: Text(item.name,
                              style: const TextStyle(color: _kTextPrimary)),
                          // Show existing customer note as subtitle preview
                          subtitle: item.customerNote.isNotEmpty
                              ? Text('👤 ${item.customerNote}',
                                  style: const TextStyle(
                                      color: Colors.lightBlueAccent,
                                      fontSize: 11))
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            _showProductCustomerNoteSheet(context, item);
                          },
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Product Customer Note Sheet ──────────────────────────────────────────
  // Opens note sheet for a regular CartItem — saves as customerNote (not note)
  void _showProductCustomerNoteSheet(BuildContext context, CartItem item) {
    // Preset tags suited for customer-facing notes
    const presetTags = ['Gift wrap', 'Urgent', 'No receipt', 'Call before'];

    // Always fetch the latest live item from CartService so we get the
    // most up-to-date customerNote (and NOT the stale snapshot passed in).
    // This prevents the product/kitchen note from leaking into the customer
    // note field when the user opens this sheet after adding a kitchen note.
    final liveItem = CartService.instance.cart[item.productId] ?? item;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => ProductNoteSheet(
        item: liveItem,
        presetTags: presetTags,
        noteLabel: 'Customer Note',
        // Pre-fill with the live customerNote — empty string keeps field blank
        // when no customer note exists yet (avoids showing kitchen note by mistake)
        initialNote: liveItem.customerNote,
        onApply: (note) {
          // Saves to customerNote field — independent of kitchen note
          _cart.updateItemCustomerNote(liveItem.productId, note);
        },
      ),
    );
  }

  // ── Combo Customer Note Sheet ────────────────────────────────────────────
  // Opens note sheet for a ComboCartItem — saves as customerNote (not note)
  void _showComboCustomerNoteSheet(BuildContext context, ComboCartItem combo) {
    // Preset tags suited for customer-facing notes
    const presetTags = ['Gift wrap', 'Urgent', 'No receipt', 'Call before'];

    // Always fetch the latest live combo from CartService so we get the
    // most up-to-date customerNote (and NOT the stale snapshot passed in).
    final liveCombo = CartService.instance.comboCart[combo.cartKey] ?? combo;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => ComboNoteSheet(
        combo: liveCombo,
        presetTags: presetTags,
        noteLabel: 'Customer Note',
        // Pre-fill with the live customerNote — empty string keeps field blank
        // when no customer note exists yet (avoids showing kitchen note by mistake)
        initialNote: liveCombo.customerNote,
        onApply: (note) {
          // Saves to customerNote field — independent of kitchen note
          _cart.updateComboCustomerNote(liveCombo.cartKey, note);
        },
      ),
    );
  }

  // ── Cancel Order Confirmation ──────────────────────────
  void _confirmCancelOrder(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Cancel Order?',
          style: TextStyle(
              color: _kTextPrimary, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'All items in the cart will be removed. This cannot be undone.',
          style: TextStyle(color: _kTextSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), // Dismiss dialog, keep order
            child: const Text('Keep Order',
                style: TextStyle(color: _kTextSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx); // Close dialog first
              _cancelOrder(); // Then call cancel (handles Odoo + offline)
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _kRed,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: const Text('Cancel Order',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Cancel Order: Sync to Odoo + Clear Cart ────────────────────────────
  // 1. If cart is empty → just clear and return.
  // 2. Try calling POST /api/order/cancel online → Odoo gets cancelled record.
  // 3. If offline → save cancelled order to local SQLite (status='cancel').
  // 4. Always clear the cart at the end.
  //
  // Why record in Odoo?
  //   Native POS does the same — cancelled orders appear in order list
  //   with state='cancel'. This keeps cashier reports accurate.
  Future<void> _cancelOrder() async {
    final cart = CartService.instance;

    // Stop any delayed draft auto-sync from firing while we are cancelling.
    // This avoids a race where a restored order could be re-saved as draft
    // immediately after the cashier chose Cancel.
    _autoSyncTimer?.cancel();

    // If cart is empty, nothing to record — just clear and return
    if (cart.cart.isEmpty && cart.comboCart.isEmpty) {
      cart.clearCart();
      return;
    }

    final baseUrl = await AppConfig.getServerUrl();
    final token = await AppConfig.getApiToken();
    final deviceCode = await AppConfig.getDeviceCode();
    final sessionId = await AppConfig.getPosSessionId();

    // ── EDITING PENDING ORDER: Update existing record instead of creating new ──
    // When the user restored a pending order via "Add back to cart" and then
    // cancels it, we must mark the ORIGINAL order as cancelled rather than
    // creating a brand-new cancel record (which would leave two rows in the DB).
    //
    // editingExternalId may be null for orders created from the Odoo backend
    // ("New" state) — those have no external_pos_id. In that case we fall back
    // to editingPendingOdooOrderId to cancel the Odoo record directly by ID.
    final editingLocalId = cart.editingPendingLocalId;
    final editingExternalId = cart.editingPendingExternalId;
    final editingOdooId = cart.editingPendingOdooOrderId;

    // Only require editingLocalId — external_id and odoo_id are optional fallbacks
    if (editingLocalId != null) {
      final orderRepo = OrderRepository();

      // 1. Update the existing order row to 'cancel' in local SQLite
      await orderRepo.updateOrderStatus(editingLocalId, 'cancel', synced: 0);
      debugPrint('✅ Marked pending order $editingLocalId as cancelled (local)');

      // 2. Try to cancel on Odoo so the server record matches.
      // Strategy A: Use external_id (Flutter-created orders — draft/held state).
      // Strategy B: Use odoo_order_id directly (Odoo-backend orders — "new" state,
      //             which have no external_pos_id set on the server).
      try {
        bool cancelledOnOdoo = false;

        // Strategy B first: if we have the Odoo order ID, cancel directly by ID.
        // This is more reliable than external_id matching (works for "new" orders).
        if (editingOdooId != null && editingOdooId > 0) {
          final response = await http
              .post(
                Uri.parse('$baseUrl/api/order/$editingOdooId/cancel'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode({'device_code': deviceCode}),
              )
              .timeout(const Duration(seconds: 10));
          final data = jsonDecode(response.body);
          cancelledOnOdoo = data['status'] == 'success';
          debugPrint(
              '✅ Cancelled Odoo order $editingOdooId by ID: $cancelledOnOdoo');
        }

        // Strategy A fallback: cancel by external_id (Flutter-created drafts).
        if (!cancelledOnOdoo &&
            editingExternalId != null &&
            editingExternalId.isNotEmpty) {
          final cancelPayload = {
            'external_id': editingExternalId,
            'device_code': deviceCode,
            'session_id': sessionId,
            'total': cart.total,
            if (cart.customerNotifier.value != null)
              'customer_id': cart.customerNotifier.value!.id,
            'lines': [
              ...cart.cart.values.map((item) => {
                    'product_id': item.productId,
                    'qty': item.qty,
                    'price': item.price,
                    'tax_rate': cart.taxRate,
                  }),
              ...cart.comboCart.values
                  .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
            ],
          };

          await http
              .post(
                Uri.parse('$baseUrl/api/order/cancel'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode(cancelPayload),
              )
              .timeout(const Duration(seconds: 10));
          cancelledOnOdoo = true;
          debugPrint(
              '✅ Cancelled Odoo order by external_id: $editingExternalId');
        }

        // Mark as synced so sync_manager does not retry
        if (cancelledOnOdoo) {
          await orderRepo.updateOrderStatus(editingLocalId, 'cancel',
              synced: 1);
        }
      } catch (e) {
        // Offline or error — local row already marked cancel with synced=0,
        // so sync_manager will retry when the device comes back online.
        debugPrint('⚠️ Could not cancel on Odoo (will retry when online): $e');
      }

      // 3. Clear cart and reset editing state
      cart.clearCart();
      orderPlacedNotifier.value++; // Refresh orders screen

      if (mounted) {
        showTopNotification(
          context,
          '🚫 Order cancelled.',
          color: Colors.red.shade700,
          icon: Icons.cancel_rounded,
          duration: const Duration(seconds: 2),
        );
      }
      return; // Done — skip the normal "create new cancel record" flow below
    }
    // ── END EDITING PENDING ORDER ─────────────────────────────────────────────

    // Generate a unique ID for this cancelled order record
    final externalId = const Uuid().v4();

    // Build cancel payload — same structure as a normal order
    final payload = {
      'external_id': externalId,
      'device_code': deviceCode,
      'session_id': sessionId,
      'total': cart.total,

      // Include customer if one was selected
      if (cart.customerNotifier.value != null)
        'customer_id': cart.customerNotifier.value!.id,

      // Include cart lines so Odoo shows what was in the cancelled order
      'lines': [
        // Regular items
        ...cart.cart.values.map((item) => {
              'product_id': item.productId,
              'qty': item.qty,
              'price': item.price,
              'tax_rate': cart.taxRate,
            }),
        // Combo items — each combo expands to multiple product lines
        ...cart.comboCart.values
            .expand((combo) => combo.toOrderLines(taxRate: cart.taxRate)),
      ],
    };

    // ── Try online cancel ─────────────────────────────────────────────
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/order/cancel'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (data['status'] == 'success') {
        debugPrint('✅ Cancelled order recorded in Odoo: ${data['data']}');
      } else {
        // Server returned error — save locally so no data is lost
        debugPrint('⚠️ Odoo cancel returned error: ${data['message']}');
        await _saveCancelledOrderOffline(
            externalId, deviceCode, sessionId, cart);
      }
    } catch (e) {
      // ── Offline fallback ──────────────────────────────────────────
      // Server unreachable — save cancelled order locally.
      // It will appear in orders screen as cancelled.
      debugPrint('⚠️ Cancel API unreachable, saving locally: $e');
      await _saveCancelledOrderOffline(externalId, deviceCode, sessionId, cart);
    }

    // Always clear the cart regardless of online/offline result
    cart.clearCart();
    orderPlacedNotifier.value++; // Refresh orders screen

    // Show snackbar feedback to cashier
    if (mounted) {
      showTopNotification(
        context,
        '🚫 Order cancelled.',
        color: Colors.red.shade700,
        icon: Icons.cancel_rounded,
        duration: const Duration(seconds: 2),
      );
    }
  }

  // ── Save Cancelled Order to Local SQLite ──────────────────────────────
  // Used when offline so the cancelled order is not silently lost.
  // Status is saved as 'cancel' — orders screen already maps this state.
  Future<void> _saveCancelledOrderOffline(
    String externalId,
    String deviceCode,
    int sessionId,
    CartService cart,
  ) async {
    try {
      final orderRepo = OrderRepository();
      final customerId = cart.customerNotifier.value?.id ?? 0;
      final customerName = cart.customerNotifier.value?.name ?? 'Walk-in';

      // Build lines for local DB from current cart
      final lines = [
        ...cart.cart.values.map((item) => {
              'product_id': item.productId,
              'quantity': item.qty,
              'price': item.price,
              // Use each item's own taxRate — not the cart-level average.
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

      // Save directly as cancelled so the sequence generator is not called.
      // Creating it as draft first consumed the next offline order number even
      // though the row was immediately renamed to '/'.
      final orderId = await orderRepo.createOfflineOrder(
        externalId: externalId,
        deviceCode: deviceCode,
        customerId: customerId,
        customerName: customerName,
        customerNote: cart.customerNoteNotifier.value,
        sessionId: sessionId,
        lines: lines,
        total: cart.total,
        taxAmount: cart.taxAmount,
        status: 'cancel',
        // companyName: companyName,
      );

      if (orderId > 0) {
        debugPrint('✅ Cancelled order saved locally with ID: $orderId');
      }
    } catch (e) {
      debugPrint('❌ Failed to save cancelled order locally: $e');
    }
  }

  // ── Customer Search Bottom Sheet ──────────────────
  void _showCustomerSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const CustomerSearchSheet(),
    );
  }

  // ── Proceed to Payment ────────────────────────────
  void _proceedToPayment(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const PaymentSheet(),
    );
  }
}
