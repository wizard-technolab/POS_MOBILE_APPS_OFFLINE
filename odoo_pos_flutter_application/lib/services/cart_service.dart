import 'package:flutter/foundation.dart';
import 'package:OdoCart/screens/product_screen.dart'; // for ProductModel
import 'package:OdoCart/models/combo_model.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'db_helper.dart';
import 'product_cache.dart';
import 'app_config.dart';

// ── Cart Item ──────────────────────────────────────────────
class CartItem {
  final int productId;
  final String name;
  final double price;
  final int qty;
  // Category field — used for filter chips on Cart screen
  final String category;
  final String note;
  final String customerNote;
  final String? image; // Product image base64 from Odoo

  // Tax rate for this specific product (from Odoo product taxes_id).
  // Defaults to 0.0 if no tax is configured on the product.
  final double taxRate;

  // Variant attribute pairs stored when a product with variants is added.
  // Each map has keys 'attribute' and 'value', e.g.:
  //   [{'attribute': 'Color', 'value': 'Red'}, {'attribute': 'Size', 'value': 'M'}]
  // Empty list for non-variant (simple) products.
  final List<Map<String, String>> variantAttributes;

  const CartItem({
    required this.productId,
    required this.name,
    required this.price,
    required this.qty,
    this.category = '',
    this.note = '',
    this.customerNote = '',
    this.image,
    this.taxRate = 0.0,
    this.variantAttributes = const [],
  });

  // Both note and customerNote are independent — updating one keeps the other.
  // variantAttributes is always carried forward unchanged on qty/note edits.
  CartItem copyWith({int? qty, String? note, String? customerNote}) => CartItem(
        productId: productId,
        name: name,
        price: price,
        qty: qty ?? this.qty,
        category: category,
        note: note ?? this.note,
        customerNote: customerNote ?? this.customerNote,
        image: image,
        taxRate: taxRate,
        variantAttributes: variantAttributes,
      );

  double get lineTotal => price * qty;

  // Tax amount for this line item based on product's own tax rate
  double get lineTaxAmount => lineTotal * taxRate / 100;

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'price': price,
        'qty': qty,
        'category': category,
        'note': note,
        'customer_note': customerNote,
        'tax_rate': taxRate,
        // Encode variant attributes as JSON string for SQLite persistence
        'variant_attributes': jsonEncode(variantAttributes),
      };

  factory CartItem.fromJson(Map<String, dynamic> json) {
    // Decode variant_attributes from JSON string stored in SQLite
    List<Map<String, String>> attrs = [];
    try {
      final raw = json['variant_attributes'];
      if (raw != null && raw is String && raw.isNotEmpty && raw != '[]') {
        final decoded = jsonDecode(raw) as List?;
        if (decoded != null) {
          attrs =
              decoded.map((e) => Map<String, String>.from(e as Map)).toList();
        }
      }
    } catch (_) {
      attrs = [];
    }
    return CartItem(
      productId: json['productId'] as int,
      name: json['name'] as String? ?? '',
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      qty: (json['qty'] as int?) ?? 1,
      category: json['category'] as String? ?? '',
      note: json['note'] as String? ?? '',
      customerNote: json['customer_note'] as String? ?? '',
      taxRate: (json['tax_rate'] as num?)?.toDouble() ?? 0.0,
      variantAttributes: attrs,
    );
  }
}

// ── Selected Customer ──────────────────────────────────────
class SelectedCustomer {
  final int id;
  final String name;
  final String phone;
  final String email;

  const SelectedCustomer({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'email': email,
      };

  factory SelectedCustomer.fromJson(Map<String, dynamic> json) =>
      SelectedCustomer(
        id: json['id'] as int,
        name: json['name'] as String,
        phone: json['phone'] as String,
        email: json['email'] as String,
      );
}

// ── Cart Service (Singleton) ───────────────────────────────
class CartService {
  CartService._();
  static final CartService instance = CartService._();

  // Reactive cart map: productId → CartItem
  final ValueNotifier<Map<int, CartItem>> cartNotifier = ValueNotifier({});

  // Combo products: unique cartKey → ComboCartItem
  final ValueNotifier<Map<String, ComboCartItem>> comboCartNotifier =
      ValueNotifier({});

  // Fires when "Add back to cart" restores a pending order.
  // MainShell listens and switches directly to the Cart tab (index 1).
  // Increment the value to trigger navigation — any change fires the listener.
  final ValueNotifier<int> navigateToCartNotifier = ValueNotifier(0);

  // Structural version notifier — increments ONLY when items are added or
  // removed from cart. Qty changes do NOT increment this.
  final ValueNotifier<int> cartVersionNotifier = ValueNotifier(0);

  final ValueNotifier<SelectedCustomer?> customerNotifier = ValueNotifier(null);

  // Order-level customer note (e.g. "Extra spicy, no onions")
  final ValueNotifier<String> customerNoteNotifier = ValueNotifier('');

  final DatabaseHelper _db = DatabaseHelper();

  // Track if we are editing an existing pending order (draft)
  int? editingPendingLocalId;
  String? editingPendingExternalId;

  // Odoo server order ID for pending orders that already exist on the server.
  // When this is > 0, payment_sheet will call POST /api/order/<id>/pay
  // instead of POST /api/order, to update the existing draft rather than
  // creating a new one. This prevents duplicate orders in the backend and
  // the orders screen.
  //
  // This is 0 for local-only drafts (odoo_order_id = 0 in SQLite) because
  // those are not yet on the server — they go through the normal /api/order flow.
  int? editingPendingOdooOrderId;

  void clearEditingPendingState() {
    editingPendingLocalId = null;
    editingPendingExternalId = null;
    editingPendingOdooOrderId = null; // Always clear server id on reset
  }

  // ── Initialize Cart from Persistence ──────────
  // Called at app startup. On a normal same-session launch it just loads
  // the saved cart. On a session mismatch (e.g. app killed mid-switch) it
  // clears leftover active rows and restores any pending items for the
  // current session — the same restore path used by restoreCartForSession().
  Future<void> initCart() async {
    try {
      final currentSessionId = await AppConfig.getPosSessionId();
      final savedSessionId = await _getSavedCartSessionId();

      if (savedSessionId != 0 && savedSessionId != currentSessionId) {
        // Session mismatch — wipe old cart from DB and clear in-memory state.
        // Both steps are required: DB clear prevents reload on next launch,
        // in-memory clear prevents stale items showing in the current session.
        debugPrint(
            '🔄 Cart session mismatch (saved=$savedSessionId, current=$currentSessionId) → clearing old cart');
        await _clearCartPersistence();
        await _clearCustomerPersistence();
        // Clear in-memory notifiers so UI reflects empty cart immediately
        cartNotifier.value = {};
        comboCartNotifier.value = {};
        customerNotifier.value = null;
        customerNoteNotifier.value = '';
        cartVersionNotifier.value++;

        // Restore any previously parked items for the new session
        await restoreCartForSession(currentSessionId);
        return;
      }

      // Same session — load normally from active cart_items table
      final savedCart = await _loadCartFromPersistence();
      if (savedCart.isNotEmpty) {
        cartNotifier.value = savedCart;
        debugPrint('✅ Loaded ${savedCart.length} regular items');
      }

      // Load combo cart items
      final savedComboCart = await _loadComboCartFromPersistence();
      if (savedComboCart.isNotEmpty) {
        comboCartNotifier.value = savedComboCart;
        debugPrint('✅ Loaded ${savedComboCart.length} combo items');
      }

      // Load customer
      final savedCustomer = await _loadCustomerFromPersistence();
      if (savedCustomer != null) {
        customerNotifier.value = savedCustomer;
        debugPrint('✅ Loaded customer: ${savedCustomer.name}');
      }
    } catch (e) {
      debugPrint('⚠️ Error loading cart: $e');
    }
  }

  // ── Cart Operations ────────────────────────────────────
  Map<int, CartItem> get cart => cartNotifier.value;

  // Adds a variant product to cart, storing its attribute pairs so the
  // cart tile and order history detail sheet can show "Color: Red | Size: M".
  // Called from product_screen._addVariantToCart instead of plain addItem.
  void addVariantItem(
    ProductModel product,
    List<VariantAttribute> attributes,
  ) {
    final map = Map<int, CartItem>.from(cart);
    final isNewItem = !map.containsKey(product.id);

    // Calculate effective tax rate — same logic as addItem
    final effectiveTaxRate = product.taxIds.fold<double>(
      0.0,
      (sum, t) {
        final raw = t['amount'];
        final amt = raw is num
            ? raw.toDouble()
            : double.tryParse(raw?.toString() ?? '0') ?? 0.0;
        return sum + amt;
      },
    );

    if (map.containsKey(product.id)) {
      // Increase qty only — keep existing variantAttributes from first add
      map[product.id] = map[product.id]!.copyWith(
        qty: map[product.id]!.qty + 1,
      );
    } else {
      // Convert VariantAttribute list to simple Map<String,String> pairs for storage:
      // {'attribute': 'Color', 'value': 'Red'}
      final attrMaps = attributes
          .map((a) => {'attribute': a.attributeName, 'value': a.valueName})
          .toList();

      map[product.id] = CartItem(
        productId: product.id,
        name: product.name,
        price: product.price,
        qty: 1,
        category: product.category,
        image: product.image,
        taxRate: effectiveTaxRate,
        variantAttributes:
            attrMaps, // Store for display in cart + order history
      );
    }
    cartNotifier.value = map;
    if (isNewItem) cartVersionNotifier.value++;
  }

  void addItem(ProductModel product) {
    final map = Map<int, CartItem>.from(cart);
    final isNewItem = !map.containsKey(product.id);

    // Calculate the effective tax rate for this product.
    // Odoo can assign multiple taxes — we sum all their amounts.
    // SAFETY: t['amount'] can be int, double, or String from Odoo API.
    final effectiveTaxRate = product.taxIds.fold<double>(
      0.0,
      (sum, t) {
        final raw = t['amount'];
        final amt = raw is num
            ? raw.toDouble()
            : double.tryParse(raw?.toString() ?? '0') ?? 0.0;
        return sum + amt;
      },
    );

    if (map.containsKey(product.id)) {
      map[product.id] = map[product.id]!.copyWith(
        qty: map[product.id]!.qty + 1,
      );
    } else {
      map[product.id] = CartItem(
        productId: product.id,
        name: product.name,
        price: product.price,
        qty: 1,
        category: product.category,
        image: product.image,
        taxRate: effectiveTaxRate,
      );
    }
    cartNotifier.value = map;
    if (isNewItem) cartVersionNotifier.value++;
  }

  void increaseItemQty(int productId) {
    final map = Map<int, CartItem>.from(cart);
    if (!map.containsKey(productId)) return;
    map[productId] = map[productId]!.copyWith(qty: map[productId]!.qty + 1);
    cartNotifier.value = map;
  }

  void setItemQty(int productId, int qty) {
    final map = Map<int, CartItem>.from(cart);
    if (!map.containsKey(productId)) return;
    bool wasRemoved = false;
    if (qty <= 0) {
      map.remove(productId);
      wasRemoved = true;
    } else {
      map[productId] = map[productId]!.copyWith(qty: qty);
    }
    cartNotifier.value = map;
    if (wasRemoved) cartVersionNotifier.value++;
  }

  void removeItem(int productId) {
    final map = Map<int, CartItem>.from(cart);
    if (!map.containsKey(productId)) return;
    final current = map[productId]!;
    bool wasRemoved = false;
    if (current.qty > 1) {
      map[productId] = current.copyWith(qty: current.qty - 1);
    } else {
      map.remove(productId);
      wasRemoved = true;
    }
    cartNotifier.value = map;
    if (wasRemoved) cartVersionNotifier.value++;
  }

  // Called after payment is confirmed.
  // Clears active cart AND pending items for this session so the completed
  // order does not get accidentally restored on the next session entry.
  void clearCart() {
    cartNotifier.value = {};
    comboCartNotifier.value = {};
    customerNotifier.value = null;
    customerNoteNotifier.value = '';
    cartVersionNotifier.value++;
    clearEditingPendingState();

    _clearCartPersistence();
    // Also wipe pending rows for this session — payment is done, no restore needed.
    _clearPendingCartForCurrentSession();
  }

  // ── Clear cart for session switch (safe — does NOT delete pending rows) ──
  // Use this instead of clearCart() when switching sessions.
  //
  // WHY: clearCart() internally calls _clearPendingCartForCurrentSession() which
  // reads the session ID async. By the time it runs, the new session ID may already
  // be saved in AppConfig → race condition deletes WRONG session's pending rows.
  //
  // This method only clears active cart_items table and in-memory state.
  // pending_cart_items rows are NOT touched — they stay safe for future restore.
  void clearCartForSessionSwitch() {
    cartNotifier.value = {};
    comboCartNotifier.value = {};
    customerNotifier.value = null;
    customerNoteNotifier.value = '';
    cartVersionNotifier.value++;
    clearEditingPendingState();

    // Only wipe active rows — pending_cart_items untouched
    _clearCartPersistence();
    _clearCustomerPersistence();
  }

  // ── PUBLIC: Park cart before session switch ────────────  // Call this BEFORE saving the new session ID to AppConfig.
  // Saves current cart to pending_cart_items under the given (old) sessionId,
  // then clears active DB rows and in-memory state.
  // This is NOT the same as clearCart() — pending data is preserved, not deleted.
  Future<void> parkCartForSession(int sessionId) async {
    // Copy current in-memory items into pending tables under the old session id
    await _parkCartAsPending(sessionId);

    // Delete from active tables — they are now safely in pending
    await _clearCartPersistence();
    await _clearCustomerPersistence();

    // Clear in-memory state so the UI immediately shows an empty cart
    cartNotifier.value = {};
    comboCartNotifier.value = {};
    customerNotifier.value = null;
    customerNoteNotifier.value = '';
    cartVersionNotifier.value++;

    debugPrint('🅿️ Cart parked for session $sessionId');
  }

  // ── PUBLIC: Restore pending cart for a session ─────────
  // Call this AFTER saving the new session ID to AppConfig.
  // Loads any previously parked items for the new session back into the active cart.
  Future<void> restoreCartForSession(int sessionId) async {
    final restoredCart = await _restorePendingCart(sessionId);
    if (restoredCart.isNotEmpty) {
      debugPrint(
          '✅ Restored ${restoredCart.length} pending items for session $sessionId');
      cartNotifier.value = restoredCart;
      cartVersionNotifier.value++;
    }

    final restoredCombos = await _restorePendingComboCart(sessionId);
    if (restoredCombos.isNotEmpty) {
      comboCartNotifier.value = restoredCombos;
      await _saveComboCartToPersistence(restoredCombos);
    }
  }

  // ── Note Methods ───────────────────────────────────────

  void updateItemNote(int productId, String note) {
    final map = Map<int, CartItem>.from(cart);
    if (!map.containsKey(productId)) return;
    map[productId] = map[productId]!.copyWith(note: note);
    cartNotifier.value = map;
  }

  void updateComboNote(String cartKey, String note) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    if (!map.containsKey(cartKey)) return;
    map[cartKey] = map[cartKey]!.copyWith(note: note);
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
  }

  void updateItemCustomerNote(int productId, String customerNote) {
    final map = Map<int, CartItem>.from(cartNotifier.value);
    if (!map.containsKey(productId)) return;
    map[productId] = map[productId]!.copyWith(customerNote: customerNote);
    cartNotifier.value = map;
  }

  void updateComboCustomerNote(String cartKey, String customerNote) {
    final map = Map<String, ComboCartItem>.from(comboCartNotifier.value);
    if (!map.containsKey(cartKey)) return;
    map[cartKey] = map[cartKey]!.copyWith(customerNote: customerNote);
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
  }

  void setCustomerNote(String note) {
    customerNoteNotifier.value = note;
  }

  // ── Combo Operations ───────────────────────────────────

  Map<String, ComboCartItem> get comboCart => comboCartNotifier.value;

  String addComboItem(ComboCartItem item) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    map[item.cartKey] = item;
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
    cartVersionNotifier.value++;
    return item.cartKey;
  }

  String addConfiguredCombo({
    required ComboProduct combo,
    required ComboSelection selection,
    int qty = 1,
  }) {
    final key = const Uuid().v4();
    final comboTaxRate = combo.taxIds.fold<double>(
      0.0,
      (sum, t) {
        final raw = t['amount'];
        final amt = raw is num
            ? raw.toDouble()
            : double.tryParse(raw?.toString() ?? '0') ?? 0.0;
        return sum + amt;
      },
    );

    final item = ComboCartItem(
      cartKey: key,
      comboProductId: combo.id,
      comboName: combo.name,
      basePrice: combo.basePrice,
      selection: selection,
      qty: qty,
      taxRate: comboTaxRate,
    );
    return addComboItem(item);
  }

  void increaseComboQty(String cartKey) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    if (!map.containsKey(cartKey)) return;
    map[cartKey] = map[cartKey]!.copyWith(qty: map[cartKey]!.qty + 1);
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
  }

  void decreaseComboQty(String cartKey) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    if (!map.containsKey(cartKey)) return;
    if (map[cartKey]!.qty > 1) {
      map[cartKey] = map[cartKey]!.copyWith(qty: map[cartKey]!.qty - 1);
    } else {
      map.remove(cartKey);
    }
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
  }

  void removeComboItem(String cartKey) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    map.remove(cartKey);
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
    cartVersionNotifier.value++;
  }

  // Sets a combo item's qty directly by cartKey.
  // If qty <= 0 the combo is removed from the cart entirely.
  // Used by the split-bill flow to deduct paid items from CartService
  // so the live cart only shows the remaining unpaid items.
  void setComboQty(String cartKey, int qty) {
    final map = Map<String, ComboCartItem>.from(comboCart);
    if (!map.containsKey(cartKey)) return;
    final bool removing = qty <= 0;
    if (removing) {
      map.remove(cartKey);
    } else {
      map[cartKey] = map[cartKey]!.copyWith(qty: qty);
    }
    comboCartNotifier.value = map;
    _saveComboCartToPersistence(map);
    // Fire cartVersionNotifier so cart screen header / item count rebuilds
    // immediately when a combo is fully deducted by the split-bill flow.
    if (removing) cartVersionNotifier.value++;
  }

  int getComboQtyForProduct(int comboProductId) {
    return comboCart.values
        .where((c) => c.comboProductId == comboProductId)
        .fold(0, (s, c) => s + c.qty);
  }

  int getTotalVariantQtyForTemplate(List<int> variantIds) {
    return variantIds.fold(
      0,
      (sum, vid) => sum + (cart[vid]?.qty ?? 0),
    );
  }

  int getQty(int id) => cart[id]?.qty ?? 0;

  // ── Totals ─────────────────────────────────────────────
  int get totalItemCount {
    final regular = cart.values.fold(0, (s, i) => s + (i.qty));
    final combos = comboCart.values.fold(0, (s, c) => s + (c.qty));
    return regular + combos;
  }

  double get subtotal {
    final regular = cart.values.fold(0.0, (s, i) => s + i.lineTotal);
    final combos = comboCart.values.fold(0.0, (s, c) => s + c.lineTotal);
    return regular + combos;
  }

  double get comboSaving {
    // Savings are already baked into the combo base price vs individual items.
    // If the backend returns a discount field, sum it here.
    // For now this returns 0 — extend when backend provides discount data.
    return 0.0;
  }

  double get taxRate {
    final totalQty = cart.values.fold(0, (s, i) => s + i.qty);
    if (totalQty == 0) return 0.0;
    final weightedSum = cart.values.fold<double>(
      0.0,
      (s, i) => s + i.taxRate * i.qty,
    );
    return double.parse((weightedSum / totalQty).toStringAsFixed(2));
  }

  double get taxAmount {
    final regularTax = cart.values.fold<double>(
      0.0,
      (s, i) => s + i.lineTaxAmount,
    );
    final comboTax = comboCart.values.fold<double>(
      0.0,
      (s, c) => s + c.lineTotal * c.taxRate / 100,
    );
    return double.parse((regularTax + comboTax).toStringAsFixed(2));
  }

  double get total => double.parse((subtotal + taxAmount).toStringAsFixed(2));

  // ── Customer ───────────────────────────────────────────
  void setCustomer(SelectedCustomer c) {
    customerNotifier.value = c;
    _saveCustomerToPersistence(c);
  }

  void clearCustomer() {
    customerNotifier.value = null;
    _clearCustomerPersistence();
  }

  // ── PERSISTENCE METHODS ────────────────────────────────

  Future<Map<int, CartItem>> _loadCartFromPersistence() async {
    try {
      final db = await _db.database;
      final currentSessionId = await AppConfig.getPosSessionId();
      final items = await db.query(
        'cart_items',
        where: 'session_id = ?',
        whereArgs: [currentSessionId],
      );

      Map<int, CartItem> cart = {};
      for (final item in items) {
        final product = ProductCache.instance.get(item['product_id'] as int);

        // Decode variant_attributes JSON string saved in SQLite
        List<Map<String, String>> attrs = [];
        try {
          final rawAttrs = item['variant_attributes'];
          if (rawAttrs != null &&
              rawAttrs is String &&
              rawAttrs.isNotEmpty &&
              rawAttrs != '[]') {
            final decoded = jsonDecode(rawAttrs) as List?;
            if (decoded != null) {
              attrs = decoded
                  .map((e) => Map<String, String>.from(e as Map))
                  .toList();
            }
          }
        } catch (_) {}

        final cartItem = CartItem(
          productId: item['product_id'] as int,
          name: item['name'] as String? ?? '',
          price: (item['price'] as num?)?.toDouble() ?? 0.0,
          qty: (item['quantity'] as int?) ?? 1,
          category: product?.category ?? '',
          note: item['note'] as String? ?? '',
          customerNote: item['customer_note'] as String? ?? '',
          image: item['image'] as String?,
          taxRate: (item['tax_rate'] as num?)?.toDouble() ?? 0.0,
          variantAttributes: attrs, // Restore saved variant attribute pairs
        );
        cart[cartItem.productId] = cartItem;
      }
      return cart;
    } catch (e) {
      debugPrint('Error loading cart from DB: $e');
      return {};
    }
  }

  // Returns the session_id stored with the last saved active cart items.
  Future<int> _getSavedCartSessionId() async {
    try {
      final db = await _db.database;

      final regular = await db.query('cart_items', limit: 1);
      if (regular.isNotEmpty) {
        final id = (regular.first['session_id'] as int?) ?? 0;
        if (id != 0) return id;
      }

      final combo = await db.query('combo_cart_items', limit: 1);
      if (combo.isNotEmpty) {
        return (combo.first['session_id'] as int?) ?? 0;
      }

      return 0;
    } catch (e) {
      return 0;
    }
  }

  Future<Map<String, ComboCartItem>> _loadComboCartFromPersistence() async {
    try {
      final db = await _db.database;
      final currentSessionId = await AppConfig.getPosSessionId();
      final items = await db.query(
        'combo_cart_items',
        where: 'session_id = ?',
        whereArgs: [currentSessionId],
      );

      Map<String, ComboCartItem> comboCart = {};
      for (final item in items) {
        try {
          final selectionJson = jsonDecode(
            item['selection'] as String? ?? '{}',
          );
          final selection = ComboSelection(
            selectedChoices: _deserializeComboSelection(selectionJson),
          );

          final comboItem = ComboCartItem(
            cartKey: item['cart_key'] as String,
            comboProductId: item['combo_product_id'] as int,
            comboName: item['combo_name'] as String,
            basePrice: (item['base_price'] as num?)?.toDouble() ?? 0.0,
            selection: selection,
            qty: (item['qty'] as int?) ?? 1,
            note: item['note'] as String? ?? '',
            customerNote: item['customer_note'] as String? ?? '',
            taxRate: (item['tax_rate'] as num?)?.toDouble() ?? 0.0,
          );
          comboCart[comboItem.cartKey] = comboItem;
        } catch (e) {
          debugPrint('⚠️ Error deserializing combo item: $e');
          continue;
        }
      }
      return comboCart;
    } catch (e) {
      debugPrint('⚠️ Error loading combo cart from DB: $e');
      return {};
    }
  }

  Future<void> _saveComboCartToPersistence(
    Map<String, ComboCartItem> comboMap,
  ) async {
    try {
      final db = await _db.database;
      await db.delete('combo_cart_items');

      final currentSessionId = await AppConfig.getPosSessionId();

      for (final item in comboMap.values) {
        final selectionJson = jsonEncode(
          item.selection.selectedChoices.map((groupId, choices) {
            return MapEntry(groupId, choices.map((c) => c.toJson()).toList());
          }),
        );

        await db.insert(
            'combo_cart_items',
            {
              'cart_key': item.cartKey,
              'combo_product_id': item.comboProductId,
              'combo_name': item.comboName,
              'base_price': item.basePrice,
              'selection': selectionJson,
              'qty': item.qty,
              'note': item.note,
              'customer_note': item.customerNote,
              'session_id': currentSessionId,
              'tax_rate': item.taxRate,
              'created_at': DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (e) {
      debugPrint('⚠️ Error saving combo cart to DB: $e');
    }
  }

  Map<int, List<ComboChoice>> _deserializeComboSelection(
    Map<String, dynamic> json,
  ) {
    final result = <int, List<ComboChoice>>{};
    json.forEach((groupIdStr, choices) {
      final groupId = int.tryParse(groupIdStr) ?? 0;
      final choiceList =
          (choices as List? ?? []).map((c) => ComboChoice.fromJson(c)).toList();
      result[groupId] = choiceList;
    });
    return result;
  }

  Future<void> _clearCartPersistence() async {
    try {
      final db = await _db.database;
      await db.delete('cart_items');
      await db.delete('combo_cart_items');
    } catch (e) {
      debugPrint('Error clearing cart from DB: $e');
    }
  }

  // ── Pending Cart Methods ───────────────────────────────────────────────────
  // "Parking" = saving cart items for an inactive session so they survive
  // session switches and can be restored when the user returns to that session.

  // Copies current in-memory cart into pending_cart_items and
  // pending_combo_cart_items under the given sessionId.
  Future<void> _parkCartAsPending(int sessionId) async {
    try {
      final db = await _db.database;

      // Remove any stale pending rows for this session to avoid duplicates
      await db.delete(
        'pending_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      // Insert current regular cart items into pending table
      final currentItems = cartNotifier.value;
      for (final item in currentItems.values) {
        await db.insert('pending_cart_items', {
          'product_id': item.productId,
          'name': item.name,
          'price': item.price,
          'quantity': item.qty,
          'note': item.note,
          'customer_note': item.customerNote,
          'session_id': sessionId,
          'tax_rate': item.taxRate,
          'image': item.image,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Remove any stale pending combo rows for this session
      await db.delete(
        'pending_combo_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      // Insert current combo cart items into pending table
      final currentCombos = comboCartNotifier.value;
      for (final item in currentCombos.values) {
        final selectionJson = jsonEncode(
          item.selection.selectedChoices.map((groupId, choices) {
            return MapEntry(groupId, choices.map((c) => c.toJson()).toList());
          }),
        );
        await db.insert('pending_combo_cart_items', {
          'cart_key': item.cartKey,
          'combo_product_id': item.comboProductId,
          'combo_name': item.comboName,
          'base_price': item.basePrice,
          'selection': selectionJson,
          'qty': item.qty,
          'note': item.note,
          'customer_note': item.customerNote,
          'session_id': sessionId,
          'tax_rate': item.taxRate,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      debugPrint(
          '📦 Parked ${currentItems.length} items + ${currentCombos.length} combos for session $sessionId');
    } catch (e) {
      debugPrint('⚠️ Error parking cart: $e');
    }
  }

  // Reads pending regular cart items for the given sessionId and returns them.
  // Deletes from pending table after reading — items become active again.
  Future<Map<int, CartItem>> _restorePendingCart(int sessionId) async {
    try {
      final db = await _db.database;
      final rows = await db.query(
        'pending_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      if (rows.isEmpty) return {};

      final Map<int, CartItem> result = {};
      for (final row in rows) {
        final item = CartItem(
          productId: row['product_id'] as int,
          name: row['name'] as String? ?? '',
          price: (row['price'] as num?)?.toDouble() ?? 0.0,
          qty: (row['quantity'] as int?) ?? 1,
          note: row['note'] as String? ?? '',
          customerNote: row['customer_note'] as String? ?? '',
          taxRate: (row['tax_rate'] as num?)?.toDouble() ?? 0.0,
          image: row['image'] as String?,
        );
        result[item.productId] = item;
      }

      // Remove from pending — these rows are now active
      await db.delete(
        'pending_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      return result;
    } catch (e) {
      debugPrint('⚠️ Error restoring pending cart: $e');
      return {};
    }
  }

  // Reads pending combo cart items for the given sessionId and returns them.
  // Deletes from pending table after reading — items become active again.
  Future<Map<String, ComboCartItem>> _restorePendingComboCart(
      int sessionId) async {
    try {
      final db = await _db.database;
      final rows = await db.query(
        'pending_combo_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      if (rows.isEmpty) return {};

      final Map<String, ComboCartItem> result = {};
      for (final row in rows) {
        try {
          final selectionJson = jsonDecode(row['selection'] as String? ?? '{}');
          final selection = ComboSelection(
            selectedChoices: _deserializeComboSelection(selectionJson),
          );
          final item = ComboCartItem(
            cartKey: row['cart_key'] as String,
            comboProductId: row['combo_product_id'] as int,
            comboName: row['combo_name'] as String,
            basePrice: (row['base_price'] as num?)?.toDouble() ?? 0.0,
            selection: selection,
            qty: (row['qty'] as int?) ?? 1,
            note: row['note'] as String? ?? '',
            customerNote: row['customer_note'] as String? ?? '',
            taxRate: (row['tax_rate'] as num?)?.toDouble() ?? 0.0,
          );
          result[item.cartKey] = item;
        } catch (e) {
          debugPrint('⚠️ Error deserializing pending combo: $e');
        }
      }

      // Remove from pending — these rows are now active
      await db.delete(
        'pending_combo_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );

      return result;
    } catch (e) {
      debugPrint('⚠️ Error restoring pending combo cart: $e');
      return {};
    }
  }

  // Clears pending rows for the current session.
  // Called inside clearCart() after payment so completed order items
  // do not get restored next time the user enters this session.
  Future<void> _clearPendingCartForCurrentSession() async {
    try {
      final sessionId = await AppConfig.getPosSessionId();
      if (sessionId == 0) return;
      final db = await _db.database;
      await db.delete(
        'pending_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      await db.delete(
        'pending_combo_cart_items',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
    } catch (e) {
      debugPrint('⚠️ Error clearing pending cart for current session: $e');
    }
  }

  // ── Customer Persistence ───────────────────────────────

  Future<SelectedCustomer?> _loadCustomerFromPersistence() async {
    try {
      final db = await _db.database;
      final result = await db.query('cart_customer', limit: 1);

      if (result.isEmpty) return null;

      final row = result.first;
      return SelectedCustomer(
        id: row['customer_id'] as int,
        name: row['customer_name'] as String,
        phone: row['customer_phone'] as String? ?? '',
        email: row['customer_email'] as String? ?? '',
      );
    } catch (e) {
      debugPrint('Error loading customer from DB: $e');
      return null;
    }
  }

  Future<void> _saveCustomerToPersistence(SelectedCustomer customer) async {
    try {
      final db = await _db.database;

      await db.delete('cart_customer');

      await db.insert(
          'cart_customer',
          {
            'customer_id': customer.id,
            'customer_name': customer.name,
            'customer_phone': customer.phone,
            'customer_email': customer.email,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('Error saving customer to DB: $e');
    }
  }

  Future<void> _clearCustomerPersistence() async {
    try {
      final db = await _db.database;
      await db.delete('cart_customer');
    } catch (e) {
      debugPrint('Error clearing customer from DB: $e');
    }
  }
}
