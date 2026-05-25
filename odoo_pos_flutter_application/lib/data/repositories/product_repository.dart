import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../../services/db_helper.dart';

// ─────────────────────────────────────────────────────
// PRODUCT REPOSITORY
// ─────────────────────────────────────────────────────
class ProductRepository {
  final dbHelper = DatabaseHelper();

  // ── INSERT/UPDATE Products ──────────────────
  Future<int> insertOrUpdateProducts(List<Map<String, dynamic>> products,
      {int sessionId = 0}) async {
    try {
      final db = await dbHelper.database;
      final batch = db.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      int count = 0;

      if (sessionId > 0) {
        batch.delete('session_products',
            where: 'session_id = ?', whereArgs: [sessionId]);
      }

      for (final product in products) {
        // Handle combo groups serialization
        String? comboGroupsJson;
        if (product['combo_groups'] != null) {
          if (product['combo_groups'] is String) {
            comboGroupsJson = product['combo_groups'];
          } else if (product['combo_groups'] is List) {
            comboGroupsJson = jsonEncode(product['combo_groups']);
          }
        }

        // Check if this is a combo product
        bool isCombo = product['is_combo'] == true || product['is_combo'] == 1;
        if (!isCombo && comboGroupsJson != null && comboGroupsJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(comboGroupsJson);
            if (decoded is List && decoded.isNotEmpty) {
              isCombo = true;
            }
          } catch (_) {
            // ignore invalid JSON; leave isCombo false
          }
        }

        final publicDescription =
            product['public_description'] as String? ?? '';
        final optionalProductIds = product['optional_product_ids'] is List
            ? jsonEncode(product['optional_product_ids'])
            : (product['optional_product_ids'] as String? ?? '[]');

        if (!isCombo) {
          comboGroupsJson = null;
        }

        final qtyAvailableRaw = product['qty_available'];
        final qtyAvailable =
            qtyAvailableRaw != null ? (qtyAvailableRaw as num).toDouble() : 0.0;

        final storableRaw = product['is_storable'];
        final storable = storableRaw != false && storableRaw != 0;

        batch.insert(
          'products',
          {
            'id': product['id'],
            'name': product['name'],
            'price': product['price'],
            'category': product['category'] ?? 'Other',
            'active':
                (product['active'] == true || product['active'] == 1) ? 1 : 0,
            'is_combo': isCombo ? 1 : 0,
            'combo_groups': comboGroupsJson,
            // Save base64 image string from API response to local DB
            // This allows showing product images even in offline mode
            'image': product['image'],
            // Save tax data as JSON string so it survives offline reload.
            // tax_id from API is [{id, name, amount}], stored as JSON text.
            'tax_id': product['tax_id'] is List
                ? jsonEncode(product['tax_id'])
                : (product['tax_id'] as String? ?? '[]'),
            // Save variant flag and variant list for offline variant selection
            'has_variants': (product['has_variants'] == true ||
                    product['has_variants'] == 1)
                ? 1
                : 0,
            'variants': product['variants'] is List
                ? jsonEncode(product['variants'])
                : (product['variants'] as String? ?? '[]'),
            'qty_available': qtyAvailable,
            'is_storable': storable ? 1 : 0,
            'public_description': publicDescription,
            'optional_product_ids': optionalProductIds,
            'synced': 1,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        if (sessionId > 0) {
          batch.insert(
            'session_products',
            {
              'session_id': sessionId,
              'product_id': product['id'],
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        count++;
      }

      await batch.commit(noResult: true);
      return count;
    } catch (e) {
      debugPrint('❌ Error inserting products: $e');
      return 0;
    }
  }

  // 🔥 NEW: Incremental update (only update changed products)
  Future<int> incrementalUpdateProducts(List<Map<String, dynamic>> products,
      {int sessionId = 0}) async {
    try {
      final db = await dbHelper.database;
      int updateCount = 0;
      int insertCount = 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final product in products) {
        // Handle combo groups
        String? comboGroupsJson;
        if (product['combo_groups'] != null) {
          if (product['combo_groups'] is String) {
            comboGroupsJson = product['combo_groups'];
          } else if (product['combo_groups'] is List) {
            comboGroupsJson = jsonEncode(product['combo_groups']);
          }
        }

        bool isCombo = product['is_combo'] == true || product['is_combo'] == 1;
        if (!isCombo && comboGroupsJson != null && comboGroupsJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(comboGroupsJson);
            if (decoded is List && decoded.isNotEmpty) {
              isCombo = true;
            }
          } catch (_) {}
        }

        if (!isCombo) {
          comboGroupsJson = null;
        }

        final qtyAvailableRaw = product['qty_available'];
        final qtyAvailable =
            qtyAvailableRaw != null ? (qtyAvailableRaw as num).toDouble() : 0.0;

        final storableRaw = product['is_storable'];
        final storable = storableRaw != false && storableRaw != 0;
        final publicDescription =
            product['public_description'] as String? ?? '';
        final optionalProductIdsJson = product['optional_product_ids'] is List
            ? jsonEncode(product['optional_product_ids'])
            : (product['optional_product_ids'] as String? ?? '[]');

        // Check if product exists
        // 🔒 Optimization: Select specific columns excluding 'image' to avoid
        // CursorWindow 'Row too big' exception during existence check.
        final existing = await db.rawQuery('''
          SELECT id, name, price, active, qty_available 
          FROM products 
          WHERE id = ? 
          LIMIT 1
        ''', [product['id']]);

        if (existing.isEmpty) {
          // 🆕 New product — insert it
          await db.insert(
            'products',
            {
              'id': product['id'],
              'name': product['name'],
              'price': product['price'],
              'category': product['category'] ?? 'Other',
              'active':
                  (product['active'] == true || product['active'] == 1) ? 1 : 0,
              'is_combo': isCombo ? 1 : 0,
              'combo_groups': comboGroupsJson,
              'image': product['image'],
              // Save tax data for offline tax calculation
              'tax_id': product['tax_id'] is List
                  ? jsonEncode(product['tax_id'])
                  : (product['tax_id'] as String? ?? '[]'),
              // Save variant data for offline variant selection in popup
              'has_variants': (product['has_variants'] == true ||
                      product['has_variants'] == 1)
                  ? 1
                  : 0,
              'variants': product['variants'] is List
                  ? jsonEncode(product['variants'])
                  : (product['variants'] as String? ?? '[]'),
              'qty_available': qtyAvailable,
              'is_storable': storable ? 1 : 0,
              'public_description': publicDescription,
              'optional_product_ids': optionalProductIdsJson,
              'synced': 1,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          insertCount++;
          debugPrint('  ✨ Inserted new product: ${product['name']}');
        } else {
          // ✏️ Existing product — check if changed
          final old = existing.first;
          final oldPrice = old['price'] as num;
          final oldName = old['name'] as String;
          final oldActive = old['active'] as int;
          final oldQty = (old['qty_available'] as num?)?.toDouble() ?? 0.0;

          final priceChanged =
              oldPrice.toDouble() != (product['price'] ?? 0).toDouble();
          final nameChanged = oldName != (product['name'] ?? '');
          final activeChanged = oldActive !=
              ((product['active'] == true || product['active'] == 1) ? 1 : 0);
          final qtyChanged = oldQty != qtyAvailable;
          if (priceChanged || nameChanged || activeChanged || qtyChanged) {
            // ⚡ Only update if something actually changed
            await db.update(
              'products',
              {
                'name': product['name'],
                'price': product['price'],
                'category': product['category'] ?? 'Other',
                'active': (product['active'] == true || product['active'] == 1)
                    ? 1
                    : 0,
                'is_combo': isCombo ? 1 : 0,
                'combo_groups': comboGroupsJson,
                'image': product['image'],
                // Always update tax and variant data on change sync
                // so offline users get latest Odoo tax configuration.
                'tax_id': product['tax_id'] is List
                    ? jsonEncode(product['tax_id'])
                    : (product['tax_id'] as String? ?? '[]'),
                'has_variants': (product['has_variants'] == true ||
                        product['has_variants'] == 1)
                    ? 1
                    : 0,
                'variants': product['variants'] is List
                    ? jsonEncode(product['variants'])
                    : (product['variants'] as String? ?? '[]'),
                'qty_available': qtyAvailable, // Add qty_available to update
                'public_description': publicDescription,
                'optional_product_ids': optionalProductIdsJson,
                'synced': 1,
                'updated_at': now,
              },
              where: 'id = ?',
              whereArgs: [product['id']],
            );
            updateCount++;
            debugPrint('  ✏️ Updated product: ${product['name']} '
                '(price: ${priceChanged ? '✓' : '—'}, '
                'name: ${nameChanged ? '✓' : '—'}, '
                'active: ${activeChanged ? '✓' : '—'}, '
                'qty: ${qtyChanged ? '✓' : '—'})');
          }
        }

        // Add/update session mapping
        if (sessionId > 0) {
          await db.insert(
            'session_products',
            {
              'session_id': sessionId,
              'product_id': product['id'],
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      debugPrint(
          '📊 Incremental sync: Inserted $insertCount, Updated $updateCount / Total ${products.length}');
      return insertCount + updateCount;
    } catch (e) {
      debugPrint('❌ Error in incremental update: $e');
      return 0;
    }
  }

  // ── Helpers ───────────────────────────────
  List<Map<String, dynamic>> _normalizeRows(List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      final normalized = Map<String, dynamic>.from(row);
      // combo_groups: default to empty JSON array if null
      if (normalized['combo_groups'] == null) {
        normalized['combo_groups'] = '[]';
      }
      // tax_id: default to empty JSON array if null (no tax on product)
      if (normalized['tax_id'] == null) {
        normalized['tax_id'] = '[]';
      }
      // variants: default to empty JSON array if null (no variants)
      if (normalized['variants'] == null) {
        normalized['variants'] = '[]';
      }
      // has_variants: default 0 if null (older DB rows before migration)
      normalized['has_variants'] ??= 0;
      normalized['public_description'] ??= '';
      normalized['optional_product_ids'] ??= '[]';
      normalized['is_storable'] ??= 1;
      return normalized;
    }).toList();
  }

  Future<bool> _hasSessionMappings(int sessionId) async {
    if (sessionId <= 0) return false;
    final db = await dbHelper.database;
    final result = await db.query(
      'session_products',
      columns: ['product_id'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  // ── GET All Products ────────────────────────
  Future<List<Map<String, dynamic>>> getAllProducts({
    int sessionId = 0,
  }) async {
    try {
      final db = await dbHelper.database;

      if (sessionId > 0) {
        final result = await db.rawQuery('''
        SELECT p.*
        FROM products p
        INNER JOIN session_products sp
        ON p.id = sp.product_id
        WHERE p.active = 1 AND sp.session_id = ?
        ORDER BY p.category ASC, p.name ASC
      ''', [sessionId]);

        // 🔥 STRICT: never fallback
        return _normalizeRows(result);
      }

      // Only global (no session)
      final result = await db.query(
        'products',
        where: 'active = ?',
        whereArgs: [1],
        orderBy: 'category ASC, name ASC',
      );

      return _normalizeRows(result);
    } catch (e) {
      debugPrint('❌ Error loading products: $e');
      return [];
    }
  }

  // ── SEARCH Products ────────────────────────
  Future<List<Map<String, dynamic>>> searchProducts(
    String query, {
    int sessionId = 0,
  }) async {
    try {
      final db = await dbHelper.database;
      if (sessionId > 0) {
        final result = await db.rawQuery(
          'SELECT p.* FROM products p JOIN session_products sp ON p.id = sp.product_id WHERE p.active = ? AND sp.session_id = ? AND (p.name LIKE ? OR p.category LIKE ?) ORDER BY p.name ASC',
          [1, sessionId, '%$query%', '%$query%'],
        );
        if (result.isNotEmpty || await _hasSessionMappings(sessionId)) {
          return _normalizeRows(result);
        }
        final fallback = await db.query(
          'products',
          where: 'active = ? AND (name LIKE ? OR category LIKE ?)',
          whereArgs: [1, '%$query%', '%$query%'],
          orderBy: 'name ASC',
        );
        return _normalizeRows(fallback);
      }

      final result = await db.query(
        'products',
        where: 'active = ? AND (name LIKE ? OR category LIKE ?)',
        whereArgs: [1, '%$query%', '%$query%'],
        orderBy: 'name ASC',
      );
      return result;
    } catch (e) {
      return [];
    }
  }

  // ── GET Products by Category ────────────────
  Future<List<Map<String, dynamic>>> getProductsByCategory(
    String category, {
    int sessionId = 0,
  }) async {
    try {
      final db = await dbHelper.database;
      if (sessionId > 0) {
        final result = await db.rawQuery(
          'SELECT p.* FROM products p JOIN session_products sp ON p.id = sp.product_id WHERE p.active = ? AND sp.session_id = ? AND p.category = ? ORDER BY p.name ASC',
          [1, sessionId, category],
        );
        if (result.isNotEmpty || await _hasSessionMappings(sessionId)) {
          return _normalizeRows(result);
        }
        final fallback = await db.query(
          'products',
          where: 'active = ? AND category = ?',
          whereArgs: [1, category],
          orderBy: 'name ASC',
        );
        return _normalizeRows(fallback);
      }

      final result = await db.query(
        'products',
        where: 'active = ? AND category = ?',
        whereArgs: [1, category],
        orderBy: 'name ASC',
      );

      return _normalizeRows(result);
    } catch (e) {
      debugPrint('❌ Error loading products by category: $e');
      return [];
    }
  }

  // ── GET Unique Categories ──────────────────
  Future<List<String>> getCategories({int sessionId = 0}) async {
    try {
      final db = await dbHelper.database;
      if (sessionId > 0) {
        final result = await db.rawQuery(
          'SELECT DISTINCT p.category FROM products p JOIN session_products sp ON p.id = sp.product_id WHERE p.active = ? AND sp.session_id = ? ORDER BY p.category ASC',
          [1, sessionId],
        );
        if (result.isNotEmpty || await _hasSessionMappings(sessionId)) {
          final categories = result
              .map((r) => r['category']?.toString() ?? 'Other')
              .where((c) => c.isNotEmpty)
              .toList();
          return ['All', ...categories];
        }
        final fallback = await db.query(
          'products',
          distinct: true,
          columns: ['category'],
          where: 'active = ?',
          whereArgs: [1],
          orderBy: 'category ASC',
        );
        final categories = fallback
            .map((r) => r['category']?.toString() ?? 'Other')
            .where((c) => c.isNotEmpty)
            .toList();
        return ['All', ...categories];
      }

      final result = await db.query(
        'products',
        distinct: true,
        columns: ['category'],
        where: 'active = ?',
        whereArgs: [1],
        orderBy: 'category ASC',
      );
      final categories = result
          .map((r) => r['category']?.toString() ?? 'Other')
          .where((c) => c.isNotEmpty)
          .toList();
      return ['All', ...categories];
    } catch (e) {
      debugPrint('❌ Error loading categories: $e');
      return ['All'];
    }
  }

  // ── GET Product by ID ──────────────────────
  Future<Map<String, dynamic>?> getProductById(int productId) async {
    try {
      final db = await dbHelper.database;
      final result = await db.query(
        'products',
        where: 'id = ?',
        whereArgs: [productId],
      );

      if (result.isNotEmpty) {
        final row = result.first;
        if (row['combo_groups'] == null) {
          row['combo_groups'] = '[]';
        }
        return row;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error loading product by ID: $e');
      return null;
    }
  }

  // ── GET Product Count ──────────────────────
  Future<int> getProductCount() async {
    try {
      final db = await dbHelper.database;
      final result =
          await db.rawQuery('SELECT COUNT(*) as count FROM products');
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      debugPrint('❌ Error getting product count: $e');
      return 0;
    }
  }

  // ── CLEAR Products (for refresh) ────────────
  Future<void> clearProducts() async {
    try {
      final db = await dbHelper.database;
      await db.delete('products');
    } catch (e) {
      debugPrint('❌ Error clearing products: $e');
    }
  }

  // ── DELETE Product ─────────────────────────
  Future<int> deleteProduct(int productId) async {
    try {
      final db = await dbHelper.database;
      return await db.delete(
        'products',
        where: 'id = ?',
        whereArgs: [productId],
      );
    } catch (e) {
      debugPrint('❌ Error deleting product: $e');
      return 0;
    }
  }

  // ── GET Unsynced Products ──────────────────
  Future<List<Map<String, dynamic>>> getUnsyncedProducts() async {
    try {
      final db = await dbHelper.database;
      final result = await db.query(
        'products',
        where: 'synced = ?',
        whereArgs: [0],
      );

      return result.map((row) {
        if (row['combo_groups'] == null) {
          row['combo_groups'] = '[]';
        }
        return row;
      }).toList();
    } catch (e) {
      debugPrint('❌ Error loading unsynced products: $e');
      return [];
    }
  }

  // ── GET Combo Products Only ────────────────
  Future<List<Map<String, dynamic>>> getComboProducts() async {
    try {
      final db = await dbHelper.database;
      final result = await db.query(
        'products',
        where: 'active = ? AND is_combo = ?',
        whereArgs: [1, 1],
        orderBy: 'name ASC',
      );

      return result.map((row) {
        if (row['combo_groups'] == null) {
          row['combo_groups'] = '[]';
        }
        return row;
      }).toList();
    } catch (e) {
      debugPrint('❌ Error loading combo products: $e');
      return [];
    }
  }
}
