import 'dart:convert';

/// One order line from SQLite or Odoo API (raw map wrapper + display helpers).
class OrderLine {
  final Map<String, dynamic> data;

  const OrderLine(this.data);

  factory OrderLine.fromMap(Map<String, dynamic> map) => OrderLine(map);

  String get productName => data['product_name'] as String? ?? 'Unknown';

  double get qty =>
      ((data['qty'] ?? data['quantity']) as num?)?.toDouble() ?? 0;

  double get priceUnit =>
      ((data['price_unit'] ?? data['price']) as num?)?.toDouble() ?? 0;

  double get priceSubtotalIncl {
    final rawSubIncl = (data['price_subtotal_incl'] as num?)?.toDouble() ?? 0;
    return rawSubIncl > 0 ? rawSubIncl : (priceUnit * qty);
  }

  String get customerNote => data['customer_note'] as String? ?? '';

  String get note => data['note'] as String? ?? '';

  String? get imageBase64 {
    final img = data['image'] as String?;
    return (img != null && img.isNotEmpty) ? img : null;
  }

  List<Map<String, String>> get variantAttributes {
    try {
      final rawAttrs = data['variant_attributes'];
      if (rawAttrs is List && rawAttrs.isNotEmpty) {
        return rawAttrs.map((e) => Map<String, String>.from(e as Map)).toList();
      }
      if (rawAttrs is String && rawAttrs.isNotEmpty && rawAttrs != '[]') {
        final decoded = jsonDecode(rawAttrs) as List?;
        if (decoded != null) {
          return decoded
              .map((e) => Map<String, String>.from(e as Map))
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  /// Maps used by repositories and legacy UI code.
  Map<String, dynamic> toMap() => data;
}
