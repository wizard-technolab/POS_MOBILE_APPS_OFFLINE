import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../services/db_helper.dart';
import '../domain/order_line.dart';

/// SQLite access for `order_lines` table.
class OrderLineRepository {
  final dbHelper = DatabaseHelper();

  Future<List<Map<String, dynamic>>> getOrderLines(int orderId,
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;

      final rows = await db.rawQuery(
          '''
        SELECT ol.*
        FROM order_lines ol
        WHERE ol.order_id = ?
          ${sessionId != null && sessionId > 0 ? 'AND (ol.session_id = ? OR ol.session_id IS NULL OR ol.session_id = 0)' : ''}
        ORDER BY ol.created_at ASC
      ''',
          sessionId != null && sessionId > 0
              ? [orderId, sessionId]
              : [orderId]);

      return rows.map((row) {
        final map = Map<String, dynamic>.from(row);
        map['qty'] ??= map['quantity'] ?? 1;
        map['quantity'] ??= map['qty'] ?? 1;

        final qty = (map['qty'] as num?)?.toDouble() ?? 1.0;
        final price = (map['price_unit'] as num?)?.toDouble() ?? 0.0;
        final taxRate = (map['tax_rate'] as num?)?.toDouble() ?? 0.0;

        // Safety: Fix "Unknown" names for existing corrupted data
        if (map['product_name'] == 'Unknown' ||
            (map['product_name'] as String? ?? '').isEmpty) {
          map['product_name'] = 'Product ${map['product_id'] ?? '?'}';
        }

        final sub = qty * price;
        final taxAmt = sub * taxRate / 100;
        final subIncl = sub + taxAmt;

        if (((map['price_subtotal'] as num?)?.toDouble() ?? 0.0) == 0.0) {
          map['price_subtotal'] = double.parse(sub.toStringAsFixed(2));
        }
        if (((map['price_subtotal_incl'] as num?)?.toDouble() ?? 0.0) == 0.0) {
          map['price_subtotal_incl'] = double.parse(subIncl.toStringAsFixed(2));
        }

        return map;
      }).toList();
    } catch (e) {
      debugPrint('❌ getOrderLines error: $e');
      return [];
    }
  }

  Future<List<OrderLine>> getOrderLineModels(int orderId) async {
    final maps = await getOrderLines(orderId);
    return maps.map(OrderLine.fromMap).toList();
  }

  Future<void> saveOrderLines(int orderId, List<Map<String, dynamic>> lines,
      {int? sessionId}) async {
    try {
      final db = await dbHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.transaction((txn) async {
        await txn
            .delete('order_lines', where: 'order_id = ?', whereArgs: [orderId]);

        for (final line in lines) {
          await _insertLineTxn(txn,
              orderId: orderId,
              sessionId: sessionId ?? 0,
              line: line,
              createdAt: now);
        }
      });
    } catch (e) {
      debugPrint('❌ saveOrderLines error: $e');
    }
  }

  /// Inserts lines when creating a new local order.
  Future<void> insertLinesForOrder({
    required int orderId,
    required List<Map<String, dynamic>> lines,
    required int createdAt,
    int sessionId = 0,
  }) async {
    final db = await dbHelper.database;
    for (final line in lines) {
      final qty = (line['quantity'] ?? line['qty'] ?? 1) as num;
      final price = (line['price'] as num?) ?? 0;
      final tax = (line['tax_rate'] as num?) ?? 0;
      final sub = double.parse((qty * price).toStringAsFixed(2));
      final taxAmt = double.parse((sub * tax / 100).toStringAsFixed(2));
      final subIncl = double.parse((sub + taxAmt).toStringAsFixed(2));

      await db.insert(
        'order_lines',
        {
          'order_id': orderId,
          'session_id': sessionId,
          'product_id': line['product_id'],
          'product_name': (line['product_name'] as String? ?? '').isNotEmpty
              ? (line['product_name'] as String)
              : (line['name'] as String? ??
                  ((line['product_id'] is List &&
                          (line['product_id'] as List).length > 1)
                      ? (line['product_id'] as List)[1].toString()
                      : 'Product ${line['product_id']}')),
          'quantity': qty,
          'price': price,
          'price_unit': price,
          'price_subtotal': sub,
          'price_subtotal_incl': subIncl,
          'tax_rate': tax,
          'note': line['note'] ?? '',
          'customer_note': line['customer_note'] ?? '',
          'image': line['image'] as String? ?? '',
          'variant_attributes': line['variant_attributes'] ?? '',
          'is_combo':
              (line['is_combo'] == true || line['is_combo'] == 1) ? 1 : 0,
          'combo_parent_id': line['combo_parent_id'],
          'combo_name': line['combo_name'] ?? '',
          'created_at': createdAt,
        },
      );
    }
  }

  Future<void> _insertLineTxn(
    Transaction txn, {
    required int orderId,
    required int sessionId,
    required Map<String, dynamic> line,
    required int createdAt,
  }) async {
    final rawPid = line['product_id'];
    final productId = (rawPid is List && rawPid.isNotEmpty)
        ? (int.tryParse(rawPid[0].toString()) ?? 0)
        : (int.tryParse(rawPid?.toString() ?? '') ?? 0);

    final productName = (line['product_name'] as String? ?? '').isNotEmpty
        ? (line['product_name'] as String)
        : (line['name'] as String? ??
            ((rawPid is List && rawPid.length > 1)
                ? rawPid[1].toString()
                : 'Product $productId'));

    final qty = ((line['qty'] ?? line['quantity']) as num?)?.toDouble() ?? 1.0;
    final price =
        ((line['price_unit'] ?? line['price']) as num?)?.toDouble() ?? 0.0;
    final tax = (line['tax_rate'] as num?)?.toDouble() ?? 0.0;

    final sub = (line['price_subtotal'] as num?)?.toDouble() ??
        double.parse((qty * price).toStringAsFixed(2));
    final subIncl = (line['price_subtotal_incl'] as num?)?.toDouble() ??
        double.parse((sub * (1 + tax / 100)).toStringAsFixed(2));

    String variantStr = '[]';
    final rawAttrs = line['variant_attributes'];
    if (rawAttrs is List) {
      variantStr = jsonEncode(rawAttrs);
    } else if (rawAttrs is String) {
      variantStr = rawAttrs;
    }

    await txn.insert('order_lines', {
      'order_id': orderId,
      'session_id': sessionId,
      'product_id': productId,
      'product_name': productName,
      'quantity': qty.toInt(),
      'price': price,
      'price_unit': price,
      'price_subtotal': sub,
      'price_subtotal_incl': subIncl,
      'tax_rate': tax,
      'note': line['note'] as String? ?? '',
      'customer_note': line['customer_note'] as String? ?? '',
      'image': line['image'] as String? ?? '',
      'variant_attributes': variantStr,
      'is_combo': (line['is_combo'] == true || line['is_combo'] == 1) ? 1 : 0,
      'combo_parent_id': line['combo_parent_id'],
      'combo_name': line['combo_name'] ?? '',
      'created_at': createdAt,
    });
  }
}
