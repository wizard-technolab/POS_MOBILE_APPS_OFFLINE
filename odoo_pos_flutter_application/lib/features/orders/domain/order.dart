import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Order list/detail model (local SQLite or Odoo API).
class OrderModel {
  final int id;
  final int odooOrderId;
  final String name;
  final String state;
  final String dateOrder;
  final double amountTotal;
  final String customerName;
  final String customerNote;
  final int lineCount;
  final String paymentMethod;
  final String companyName;
  final bool isLocal;

  const OrderModel({
    required this.id,
    required this.odooOrderId,
    required this.name,
    required this.state,
    required this.dateOrder,
    required this.amountTotal,
    required this.customerName,
    this.customerNote = '',
    required this.lineCount,
    required this.paymentMethod,
    required this.companyName,
    this.isLocal = false,
  });

  factory OrderModel.fromJson(Map<String, dynamic> json) {
    // Read customer_name directly from API response first (most reliable).
    // Odoo API returns 'customer_name' as a plain string in /api/orders response.
    // If not present, fall back to partner_id list format [id, name].
    // If both are missing or empty, show 'Walk-in'.
    final directName = json['customer_name'] as String?;
    final partner = json['partner_id'];
    final partnerName = (partner is List && partner.length > 1)
        ? (partner[1] as String? ?? '')
        : '';
    final customer =
        (directName != null && directName.isNotEmpty && directName != 'Walk-in')
            ? directName
            : (partnerName.isNotEmpty ? partnerName : 'Walk-in');

    final methods = json['payment_methods'];
    final payMethod = (methods is List && methods.isNotEmpty)
        ? (methods).join(' · ')
        : 'Cash';

    final lineIds = json['lines'];
    final lines = lineIds is List ? lineIds.length : 0;

    // Try 'company_name' first — sent directly as a plain string by /api/orders.
    // Fallback to parsing company_id list format [id, "Name"] for older API responses.
    // If both are missing or false, use empty string (AppConfig fallback handles display).
    final directCompanyName = json['company_name'] as String?;
    final company = json['company_id'];
    final companyFromId = (company is List && company.length > 1)
        ? (company[1] as String? ?? '')
        : ''; // false / null / unexpected type → no company name
    final compName = (directCompanyName != null && directCompanyName.isNotEmpty)
        ? directCompanyName
        : companyFromId;

    return OrderModel(
      id: json['id'] as int,
      odooOrderId: json['id'] as int, // Odoo's ID
      name: json['name'] as String? ??
          'ORDER-${json['id']}', // Fallback to ID if name is missing
      state: json['state'] as String? ?? 'draft',
      dateOrder: json['date_order'] as String? ?? '',
      amountTotal: (json['amount_total'] as num?)?.toDouble() ?? 0.0,
      customerName: customer,
      customerNote: json['customer_note'] as String? ?? '',
      lineCount: lines,
      paymentMethod: payMethod,
      companyName: compName,
      isLocal: false,
    );
  }

  factory OrderModel.fromLocalDb(Map<String, dynamic> row) {
    final dateMs = row['created_at'] as int;
    final dateOrder =
        DateTime.fromMillisecondsSinceEpoch(dateMs).toIso8601String();

    final lineCount = (row['line_count'] as int?) ?? 0;
    final paymentMethod = row['payment_method'] as String? ?? 'Cash';

    // ✅ FIX: Use the saved name with device code instead of generating generic name
    // This ensures the order name includes device code for offline, draft, and all synced orders
    final savedName = row['name'] as String? ?? '';
    final orderName = savedName.isNotEmpty
        ? savedName
        : 'ORDER-${row['id']}'; // Fallback only if name is empty (shouldn't happen)

    return OrderModel(
      id: row['id'] as int,
      odooOrderId: row['odoo_order_id'] as int? ?? 0,
      name: orderName,
      state: row['status'] as String? ?? 'draft',
      dateOrder: dateOrder,
      amountTotal: (row['total'] as num?)?.toDouble() ?? 0.0,
      customerName: row['customer_name'] as String? ?? 'Walk-in',
      customerNote: row['customer_note'] as String? ?? '',
      lineCount: lineCount,
      paymentMethod: paymentMethod,
      companyName: row['company_name'] as String? ?? '',
      isLocal: true,
    );
  }

  String get statusLabel {
    switch (state) {
      case 'done':
      case 'paid':
      case 'invoiced':
        return 'Synced';
      case 'draft':
      case 'new':
        return isLocal ? 'Pending' : 'Pending';
      case 'cancel':
        return 'Cancelled';
      case 'failed':
        return 'Failed';
      default:
        return state;
    }
  }

  Color get statusColor {
    switch (state) {
      case 'done':
      case 'paid':
      case 'invoiced': // Paid from Odoo backend
        return AppColors.green;
      case 'draft':
      case 'new':
        return AppColors.orangeAlt;
      case 'cancel':
        return AppColors.red;
      case 'failed':
        return AppColors.red;
      default:
        return AppColors.textSecondary;
    }
  }

  bool get isSynced =>
      state == 'done' || state == 'paid' || state == 'invoiced';

  String get timeLabel {
    if (dateOrder.isEmpty) return '';
    try {
      final dt = DateTime.parse(dateOrder).toLocal();
      final now = DateTime.now();
      final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final m = dt.minute.toString().padLeft(2, '0');
      final ap = dt.hour >= 12 ? 'PM' : 'AM';
      final time = '$h:$m $ap';

      final today = DateTime(now.year, now.month, now.day);
      final orderDate = DateTime(dt.year, dt.month, dt.day);
      final diff = orderDate.difference(today).inDays;

      if (diff == 0) return 'Today, $time';
      if (diff == -1) return 'Yesterday, $time';

      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]}, $time';
    } catch (_) {
      return dateOrder;
    }
  }

  String get dateGroup {
    if (dateOrder.isEmpty) return '';
    try {
      final dt = DateTime.parse(dateOrder).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final diff = DateTime(dt.year, dt.month, dt.day).difference(today).inDays;

      if (diff == 0) return 'Today';
      if (diff == -1) return 'Yesterday';

      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return '';
    }
  }
}
