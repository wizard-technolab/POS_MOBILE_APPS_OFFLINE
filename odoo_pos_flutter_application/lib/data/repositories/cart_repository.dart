import 'package:sqflite/sqflite.dart';
import '../../services/db_helper.dart';

// ─────────────────────────────────────────────────────
// CART REPOSITORY
// ─────────────────────────────────────────────────────
class CartRepository {
  final dbHelper = DatabaseHelper();

  // ── ADD/UPDATE Item to Cart ─────────────────
  Future<int> addOrUpdateCartItem({
    required int productId,
    required String name,
    required double price,
    required int quantity,
  }) async {
    try {
      final db = await dbHelper.database;

      final result = await db.insert(
        'cart_items',
        {
          'product_id': productId,
          'name': name,
          'price': price,
          'quantity': quantity,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return result;
    } catch (e) {
      return 0;
    }
  }

  // ── GET All Cart Items ──────────────────────
  Future<List<Map<String, dynamic>>> getAllCartItems() async {
    try {
      final db = await dbHelper.database;
      return await db.query(
        'cart_items',
        orderBy: 'created_at ASC',
      );
    } catch (e) {
      return [];
    }
  }

  // ── GET Cart Item by Product ID ─────────────
  Future<Map<String, dynamic>?> getCartItem(int productId) async {
    try {
      final db = await dbHelper.database;
      final result = await db.query(
        'cart_items',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      return result.isNotEmpty ? result.first : null;
    } catch (e) {
      return null;
    }
  }

  // ── UPDATE Cart Item Quantity ───────────────
  Future<int> updateCartItemQuantity(int productId, int quantity) async {
    try {
      final db = await dbHelper.database;

      if (quantity <= 0) {
        return await removeCartItem(productId);
      }

      return await db.update(
        'cart_items',
        {
          'quantity': quantity,
          'updated_at': DateTime.now().millisecondsSinceEpoch
        },
        where: 'product_id = ?',
        whereArgs: [productId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── REMOVE Item from Cart ───────────────────
  Future<int> removeCartItem(int productId) async {
    try {
      final db = await dbHelper.database;
      return await db.delete(
        'cart_items',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
    } catch (e) {
      return 0;
    }
  }

  // ── CLEAR All Cart Items ────────────────────
  Future<int> clearCart() async {
    try {
      final db = await dbHelper.database;
      final count = await db.delete('cart_items');
      return count;
    } catch (e) {
      return 0;
    }
  }

  // ── GET Cart Item Count ─────────────────────
  Future<int> getCartItemCount() async {
    try {
      final db = await dbHelper.database;
      final result =
          await db.rawQuery('SELECT COUNT(*) as count FROM cart_items');
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  // ── GET Total Quantity ─────────────────────
  Future<int> getTotalQuantity() async {
    try {
      final db = await dbHelper.database;
      final result =
          await db.rawQuery('SELECT SUM(quantity) as total FROM cart_items');
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  // ── GET Cart Subtotal ─────────────────────
  Future<double> getSubtotal() async {
    try {
      final db = await dbHelper.database;
      final result = await db
          .rawQuery('SELECT SUM(price * quantity) as total FROM cart_items');
      final total = Sqflite.firstIntValue(result);
      return (total ?? 0).toDouble();
    } catch (e) {
      return 0.0;
    }
  }

  // ── GET Cart Summary ────────────────────────
  Future<CartSummary> getCartSummary() async {
    try {
      final db = await dbHelper.database;

      final countResult =
          await db.rawQuery('SELECT COUNT(*) as count FROM cart_items');
      final count = Sqflite.firstIntValue(countResult) ?? 0;

      final qtyResult =
          await db.rawQuery('SELECT SUM(quantity) as total FROM cart_items');
      final quantity = Sqflite.firstIntValue(qtyResult) ?? 0;

      final subtotalResult = await db
          .rawQuery('SELECT SUM(price * quantity) as total FROM cart_items');
      final subtotal = (Sqflite.firstIntValue(subtotalResult) ?? 0).toDouble();

      const taxRate = 18.0;
      final taxAmount =
          double.parse((subtotal * taxRate / 100).toStringAsFixed(2));
      final total = subtotal + taxAmount;

      return CartSummary(
        itemCount: count,
        totalQuantity: quantity,
        subtotal: subtotal,
        taxRate: taxRate,
        taxAmount: taxAmount,
        total: total,
      );
    } catch (e) {
      return CartSummary.empty();
    }
  }
}

// ─────────────────────────────────────────────────────
// CART SUMMARY MODEL
// ─────────────────────────────────────────────────────
class CartSummary {
  final int itemCount;
  final int totalQuantity;
  final double subtotal;
  final double taxRate;
  final double taxAmount;
  final double total;

  CartSummary({
    required this.itemCount,
    required this.totalQuantity,
    required this.subtotal,
    required this.taxRate,
    required this.taxAmount,
    required this.total,
  });

  factory CartSummary.empty() => CartSummary(
        itemCount: 0,
        totalQuantity: 0,
        subtotal: 0.0,
        taxRate: 18.0,
        taxAmount: 0.0,
        total: 0.0,
      );
}
