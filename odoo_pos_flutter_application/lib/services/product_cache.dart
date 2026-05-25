// ─────────────────────────────────────────────────────────────
// product_cache.dart  (NEW FILE)
// Singleton cache that stores all loaded ProductModel objects.
// This lets the cart screen look up a product's full combo groups
// without making another API call.
//
// Usage:
//   1. product_screen.dart calls ProductCache.instance.setAll(products)
//      after loading products from the API.
//   2. cart_screen.dart calls ProductCache.instance.get(productId)
//      inside _editComboItem() to re-open the combo selection sheet.
// ─────────────────────────────────────────────────────────────

import '../screens/product_screen.dart'; // ProductModel lives here

class ProductCache {
  // Private constructor — prevents external instantiation
  ProductCache._();

  // Global singleton instance
  static final ProductCache instance = ProductCache._();

  // Internal map: productId → ProductModel
  final Map<int, ProductModel> _map = {};

  // ── Store all products (called from product_screen.dart) ──
  // Replaces any previously cached products.
  void setAll(List<ProductModel> products) {
    _map.clear();
    for (final p in products) {
      _map[p.id] = p;
      // Also index by variant IDs so restoration from order lines works
      for (final v in p.variants) {
        _map[v.variantId] = p;
      }
    }
  }

  // ── Get a single product by id ─────────────────────────
  // Returns null if product not found or cache is empty.
  ProductModel? get(int id) => _map[id];

  // ── Fallback: find product by exact name match ─────────
  // Used when product_id is missing (e.g. older API responses that do not
  // include product_id in /api/order/<id>/lines). Matches against the
  // template name as well as variant names ("Base (Color: Red)").
  // Returns the first matching ProductModel or null if not found.
  ProductModel? getByName(String name) {
    if (name.isEmpty) return null;
    final lowerName = name.toLowerCase().trim();
    // First try exact match on template name
    for (final p in _map.values.toSet()) {
      if (p.name.toLowerCase().trim() == lowerName) return p;
    }
    // Then try partial match — handles variant labels like "Product (Size: M)"
    for (final p in _map.values.toSet()) {
      if (lowerName.startsWith(p.name.toLowerCase().trim())) return p;
    }
    return null;
  }

  // ── Check if cache has data ────────────────────────────
  bool get isEmpty => _map.isEmpty;

  // ── Get all combo products only ────────────────────────
  List<ProductModel> get combos => _map.values.where((p) => p.isCombo).toList();

  // ── Clear cache (e.g. on logout) ──────────────────────
  void clear() => _map.clear();
}
