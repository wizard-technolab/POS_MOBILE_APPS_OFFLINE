// credit_limit_service.dart
//
// PURPOSE:
//   Fetch and evaluate a customer's credit limit before checkout.
//   Call checkCredit() right before opening the payment sheet — so the
//   cashier sees a live warning based on Odoo's current receivable balance.
//
// USAGE IN CART SCREEN:
//   1. When customer is selected in cart, call checkCredit().
//   2. Decide action based on the returned CreditStatus:
//      - CreditStatus.blocked  → show RED dialog, disable Pay button
//      - CreditStatus.warning  → show ORANGE banner, allow checkout with override
//      - CreditStatus.ok       → proceed normally (no warning needed)
//
// ─────────────────────────────────────────────────────────────

import 'dart:convert';
import 'api_client.dart';

// ── Enum: result of a credit check ───────────────────────────
enum CreditStatus {
  ok, // no limit configured, or balance is well within limit
  warning, // order total would exceed available credit (but not blocked)
  blocked, // credit_on_hold = true — account is manually blocked
}

// ── Model: data returned by the API ──────────────────────────
class CustomerCreditInfo {
  final int customerId;
  final String customerName;

  /// Current outstanding receivable balance (from Odoo invoices)
  final double credit;

  /// Configured credit limit (0 = no limit set)
  final double creditLimit;

  /// True when the account is manually blocked by the manager
  final bool creditOnHold;

  /// How much the customer can still spend before hitting the limit.
  /// Null when creditLimit = 0 (unlimited).
  final double? availableCredit;

  const CustomerCreditInfo({
    required this.customerId,
    required this.customerName,
    required this.credit,
    required this.creditLimit,
    required this.creditOnHold,
    required this.availableCredit,
  });

  factory CustomerCreditInfo.fromJson(Map<String, dynamic> json) {
    return CustomerCreditInfo(
      customerId: json['customer_id'] as int,
      customerName: json['customer_name'] as String? ?? '',
      credit: (json['credit'] as num?)?.toDouble() ?? 0,
      creditLimit: (json['credit_limit'] as num?)?.toDouble() ?? 0,
      creditOnHold: json['credit_on_hold'] as bool? ?? false,
      availableCredit: json['available_credit'] != null
          ? (json['available_credit'] as num).toDouble()
          : null,
    );
  }

  /// True when a credit limit is configured AND the customer has used some of it.
  bool get hasLimit => creditLimit > 0;
}

// ── Service ───────────────────────────────────────────────────
class CreditLimitService {
  /// Fetch credit info for [customerId] from Odoo.
  ///
  /// Returns null on network error or if customer is not found —
  /// in that case the caller should proceed without blocking the sale.
  static Future<CustomerCreditInfo?> fetchCreditInfo(int customerId) async {
    try {
      final response = await ApiClient.get(
        '/api/customer/$customerId/credit',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 8),
      );

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'success') return null;

      return CustomerCreditInfo.fromJson(data['data'] as Map<String, dynamic>);
    } catch (_) {
      // Network error — do not block the sale, return null
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────
  // Evaluate credit status given the order total.
  //
  // Rules:
  //   1. credit_on_hold = true            → BLOCKED  (hard stop)
  //   2. available_credit < orderTotal    → WARNING  (soft stop, can override)
  //   3. Everything else                  → OK
  //
  // [info]  — result from fetchCreditInfo (null = skip check)
  // [orderTotal] — cart total the customer is about to pay
  // ─────────────────────────────────────────────────────────
  static CreditStatus evaluate(CustomerCreditInfo? info, double orderTotal) {
    if (info == null) return CreditStatus.ok; // no data = don't block

    // Hard block — manager has manually put account on hold
    if (info.creditOnHold) return CreditStatus.blocked;

    // Soft warning — this order would exceed the remaining credit
    if (info.availableCredit != null && orderTotal > info.availableCredit!) {
      return CreditStatus.warning;
    }

    return CreditStatus.ok;
  }

  // ─────────────────────────────────────────────────────────
  // Build a human-readable message for the warning banner.
  // ─────────────────────────────────────────────────────────
  static String buildWarningMessage(
      CustomerCreditInfo info, String currencySymbol) {
    if (info.creditOnHold) {
      return 'Account On Hold: ${info.customerName}\'s account is blocked. '
          'Please contact the manager.';
    }

    if (info.availableCredit != null) {
      return 'Credit Limit Warning: ${info.customerName} has only '
          '$currencySymbol${info.availableCredit!.toStringAsFixed(2)} '
          'credit remaining '
          '(Limit: $currencySymbol${info.creditLimit.toStringAsFixed(2)}, '
          'Used: $currencySymbol${info.credit.toStringAsFixed(2)}).';
    }

    return '';
  }
}
