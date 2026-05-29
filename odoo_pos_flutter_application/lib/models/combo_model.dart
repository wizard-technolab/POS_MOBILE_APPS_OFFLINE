// ─────────────────────────────────────────────────────────────
// combo_model.dart
// Data models for Odoo Combo Products.
// These mirror the Odoo pos.combo / pos.combo.line structure.
// ─────────────────────────────────────────────────────────────

import 'dart:convert';

import 'package:flutter/foundation.dart';

// One selectable choice inside a combo group (e.g. "Veg Sandwich +₹0")
class ComboChoice {
  final int productId;
  final String productName;

  // Extra charge on top of combo base price
  final double extraPrice;

  // Stock quantity of the product.product assigned in this combo choice
  final double qtyAvailable;

  // Inventory tracking flag of the product.product assigned in this combo choice.
  // Non-storable/service products must remain selectable even when qtyAvailable is 0.
  final bool isStorable;

  const ComboChoice({
    required this.productId,
    required this.productName,
    required this.extraPrice,
    this.qtyAvailable = 0.0,
    this.isStorable = true,
  });

  factory ComboChoice.fromJson(Map<String, dynamic> json) => ComboChoice(
        productId: json['product_id'] ?? 0,
        productName: json['product_name'] ?? '',
        extraPrice: (json['extra_price'] ?? 0).toDouble(),
        qtyAvailable: (json['qty_available'] ?? 0).toDouble(),
        isStorable: () {
          final raw = json['is_storable'] ?? json['track_inventory'];
          if (raw is bool) return raw;
          if (raw is num) return raw != 0;
          if (raw is String) {
            final value = raw.toLowerCase().trim();
            return value == 'true' || value == '1' || value == 'yes';
          }
          return true;
        }(),
      );

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'product_name': productName,
        'extra_price': extraPrice,
        'qty_available': qtyAvailable,
        'is_storable': isStorable,
      };

  // Whether this choice is available for selection.
  // Only storable child products need positive stock.
  // Service/non-storable child products are always available.
  bool get isAvailable => !isStorable || qtyAvailable > 0;
}

// One group/slot in a combo (e.g. "Main Dish", "Drink", "Add-on")
class ComboGroup {
  final int groupId;
  final String groupName;

  // minimum selections required
  // 1 = required
  // 0 = optional
  final int minQty;

  // maximum selections allowed
  final int maxQty;

  final List<ComboChoice> choices;

  const ComboGroup({
    required this.groupId,
    required this.groupName,
    required this.minQty,
    required this.maxQty,
    required this.choices,
  });

  bool get isRequired => minQty > 0;

  factory ComboGroup.fromJson(Map<String, dynamic> json) => ComboGroup(
        groupId: json['group_id'] ?? 0,
        groupName: json['group_name'] ?? '',
        minQty: json['min_qty'] ?? 1,
        maxQty: json['max_qty'] ?? 1,
        choices: (json['choices'] as List? ?? [])
            .map((c) => ComboChoice.fromJson(c))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'group_id': groupId,
        'group_name': groupName,
        'min_qty': minQty,
        'max_qty': maxQty,
        'choices': choices.map((c) => c.toJson()).toList(),
      };

  // Only choices currently in stock
  List<ComboChoice> get availableChoices =>
      choices.where((c) => c.isAvailable).toList();

  // Whether this group can still satisfy required minimum selections
  bool get canBeSatisfied => availableChoices.length >= minQty;
}

// Full combo product — extends the regular product concept
class ComboProduct {
  final int id;
  final String name;
  final double basePrice;
  final String category;
  final bool active;
  final List<ComboGroup> groups; // the combo slots
  // Tax list from Odoo — same format as ProductModel.taxIds
  final List<Map<String, dynamic>> taxIds;

  const ComboProduct({
    required this.id,
    required this.name,
    required this.basePrice,
    required this.category,
    required this.active,
    required this.groups,
    this.taxIds = const [],
  });

  factory ComboProduct.fromJson(Map<String, dynamic> json) => ComboProduct(
        id: json['id'] ?? 0,
        name: json['name'] ?? '',
        basePrice: (json['price'] ?? json['base_price'] ?? 0).toDouble(),
        category: json['category'] ?? 'Combos',
        active: json['active'] ?? true,
        groups: (json['combo_groups'] as List? ?? [])
            .map((g) => ComboGroup.fromJson(g))
            .toList(),
        // Load tax list — same field name as ProductModel
        taxIds: (json['tax_id'] as List? ?? [])
            .map((t) => Map<String, dynamic>.from(t as Map))
            .toList(),
      );

  // Combo is out of stock if ANY required group
  // cannot be satisfied with available items
  bool get isOutOfStock => groups.any((g) => !g.canBeSatisfied);
}

// Tracks the user's current selections for one combo instance
class ComboSelection {
  // groupId → list of chosen ComboChoice objects
  final Map<int, List<ComboChoice>> selectedChoices;

  const ComboSelection({required this.selectedChoices});

  factory ComboSelection.empty() => const ComboSelection(selectedChoices: {});

  // Convert to JSON-compatible format (String keys + Choices to Map)
  Map<String, dynamic> toJson() {
    return selectedChoices.map(
      (key, value) => MapEntry(
        key.toString(),
        value.map((c) => c.toJson()).toList(),
      ),
    );
  }

  // Reconstruct from JSON map or JSON string
  factory ComboSelection.fromJson(dynamic json) {
    final Map<String, dynamic> data =
        (json is String) ? jsonDecode(json) : json;
    final result = data.map((key, value) {
      final choices = (value as List)
          .map((c) => ComboChoice.fromJson(c as Map<String, dynamic>))
          .toList();
      return MapEntry(int.parse(key), choices);
    });
    return ComboSelection(selectedChoices: result);
  }

  // Toggle/add/remove selection
  ComboSelection withChoice(
    ComboGroup group,
    ComboChoice choice,
  ) {
    final map = Map<int, List<ComboChoice>>.from(
      selectedChoices.map(
        (k, v) => MapEntry(k, List<ComboChoice>.from(v)),
      ),
    );

    final existing = map[group.groupId] ?? [];

    if (group.maxQty == 1) {
      // Single-select: replace whatever was chosen before
      map[group.groupId] = [choice];
    } else {
      // Multi-select toggle
      final idx = existing.indexWhere(
        (c) => c.productId == choice.productId,
      );

      if (idx >= 0) {
        existing.removeAt(idx);
      } else if (existing.length < group.maxQty) {
        existing.add(choice);
      }
      map[group.groupId] = existing;
    }

    return ComboSelection(selectedChoices: map);
  }

  // True when a specific choice is currently selected in a group
  bool isSelected(int groupId, int productId) {
    return (selectedChoices[groupId] ?? [])
        .any((c) => c.productId == productId);
  }

  // True when all required groups have the minimum number of selections
  bool isComplete(List<ComboGroup> groups) {
    for (final g in groups) {
      if (g.isRequired) {
        final chosen = selectedChoices[g.groupId]?.length ?? 0;

        if (chosen < g.minQty) {
          return false;
        }
      }
    }
    return true;
  }

  // Extra price added on top of base combo price based on selections
  double get extraTotal {
    double total = 0;
    for (final choices in selectedChoices.values) {
      for (final c in choices) {
        total += c.extraPrice;
      }
    }
    return total;
  }
}

// A combo item stored in the cart — one configured combo instance
class ComboCartItem {
  final String cartKey; // unique key per cart entry (uuid)
  final int comboProductId;
  final String comboName;
  final double basePrice;
  final ComboSelection selection;
  final int qty;
  final String note; // internal kitchen note (staff only)
  final String customerNote; // customer-facing note (shown on receipt)
  // Tax rate for this combo product from Odoo (sum of all taxes).
  // Used to show GST badge on combo cart card and for tax calculation.
  final double taxRate;

  const ComboCartItem({
    required this.cartKey,
    required this.comboProductId,
    required this.comboName,
    required this.basePrice,
    required this.selection,
    required this.qty,
    this.note = '',
    this.customerNote = '',
    this.taxRate = 0.0, // default 0 — no tax unless Odoo sends one
  });

  double get unitPrice => basePrice + selection.extraTotal;
  double get lineTotal => unitPrice * qty;

  ComboCartItem copyWith({
    int? qty,
    String? note,
    String? customerNote,
  }) {
    return ComboCartItem(
      cartKey: cartKey,
      comboProductId: comboProductId,
      comboName: comboName,
      basePrice: basePrice,
      selection: selection,
      qty: qty ?? this.qty,
      note: note ?? this.note,
      customerNote: customerNote ?? this.customerNote,
      taxRate: taxRate,
    );
  }

  Map<String, dynamic> toJson() => {
        'cart_key': cartKey,
        'combo_product_id': comboProductId,
        'combo_name': comboName,
        'base_price': basePrice,
        'selection': selection.toJson(),
        'qty': qty,
        'note': note,
        'customer_note': customerNote,
      };

  factory ComboCartItem.fromJson(Map<String, dynamic> json) => ComboCartItem(
        cartKey: json['cart_key'] ?? '',
        comboProductId: json['combo_product_id'] ?? 0,
        comboName: json['combo_name'] ?? '',
        basePrice: (json['base_price'] ?? 0).toDouble(),
        selection: ComboSelection.fromJson(json['selection']),
        qty: json['qty'] ?? 1,
        note: json['note'] as String? ?? '',
        customerNote: json['customer_note'] as String? ?? '',
        taxRate: (json['tax_rate'] as num?)?.toDouble() ??
            0.0, // load combo tax rate
      );

  // Builds the flat list of order lines the Odoo API expects.
  // The combo parent itself becomes the first line; each selected
  // choice becomes a child line with combo_parent_id set.
  List<Map<String, dynamic>> toOrderLines({required double taxRate}) {
    final lines = <Map<String, dynamic>>[];

    // Parent combo line
    lines.add({
      'product_id': comboProductId,
      'product_name': comboName,
      'qty': qty,
      'price': unitPrice,
      'is_combo': true,
      'combo_parent_id': null,
      'combo_name': comboName,
      'image': null,
      'variant_attributes': '[]',
      if (note.isNotEmpty) 'note': note,
      if (customerNote.isNotEmpty) 'customer_note': customerNote,
    });

    // Child combo selections
    for (final groupChoices in selection.selectedChoices.values) {
      for (final choice in groupChoices) {
        // ✅ Validation added from patch
        if (choice.productId <= 0) {
          if (kDebugMode) {
            print(
              '⚠️ Combo choice has invalid productId: ${choice.productId}',
            );
          }
          continue;
        }

        lines.add({
          'product_id': choice.productId,
          'product_name': choice.productName,
          'qty': qty,
          'price': choice.extraPrice,
          'is_combo': true,
          'combo_parent_id': comboProductId,
          'combo_name': comboName,
          'image': null,
          'variant_attributes': '[]',
          'note': '',
          'customer_note': '',
        });
      }
    }

    return lines;
  }
}
