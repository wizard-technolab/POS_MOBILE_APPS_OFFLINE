import '../../../models/combo_model.dart';
import '../../../services/cart_service.dart';

class SplitPerson {
  final String id; // unique local key
  final int customerId; // Odoo res.partner id
  String name;
  String phone;

  SplitPerson({
    required this.id,
    required this.customerId,
    required this.name,
    this.phone = '',
  });
}

// Helper model — one item row for display in split sheet
class SplitItem {
  final String key; // cart key (productId.toString() or comboCartKey)
  final String name;
  final double unitPrice;
  final int qty;
  final bool isCombo;
  String? assignedPersonId; // null = unassigned

  SplitItem({
    required this.key,
    required this.name,
    required this.unitPrice,
    required this.qty,
    required this.isCombo,
    this.assignedPersonId,
  });

  double get lineTotal => unitPrice * qty;
}

enum SplitStep {
  selectItems, // Person picks their items + optional customer
  payment, // Payment method selection + Pay button + API call
  personDone, // Short green-tick success screen shown between persons
  allDone, // Everything paid — final green-tick, cart cleared
}

// ─────────────────────────────────────────────────────────────────────────────
// SplitRemainingItem
//
// Tracks one item (regular or combo) across the entire split session.
// remainingQty starts at the full cart qty and is decremented each time
// a person claims some units of this item.
// ─────────────────────────────────────────────────────────────────────────────
class SplitRemainingItem {
  final String key; // productId.toString() for regular, cartKey for combo
  final int productId; // used in the API line payload
  final String name; // display name
  final double unitPrice; // price per unit BEFORE tax
  final bool isCombo;

  // Keep references to originals so we can call their helper methods
  final CartItem? cartItem; // non-null when isCombo == false
  final ComboCartItem? comboItem; // non-null when isCombo == true

  int remainingQty; // mutable — reduced after each person pays

  // Extra fields saved to order_lines so Order History detail shows
  // image, variants, notes correctly for split orders too
  final String note;
  final String customerNote;
  final String? image;
  final List<Map<String, String>> variantAttributes;

  SplitRemainingItem({
    required this.key,
    required this.productId,
    required this.name,
    required this.unitPrice,
    required this.isCombo,
    this.cartItem,
    this.comboItem,
    required this.remainingQty,
    this.note = '',
    this.customerNote = '',
    this.image,
    this.variantAttributes = const [],
  });
}
