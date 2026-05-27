// ============================================================
// FIX 3 — receipt_pdf_builder.dart  (FULL FIXED FILE)
// PROBLEM: When order.companyName is empty (local/offline orders),
//          the header falls back to 'STORE RECEIPT'.
//          It should instead use AppConfig.getCompanyName() which
//          was saved when the session was selected.
//
// CHANGE SUMMARY:
//   1. Import AppConfig at top.
//   2. In buildReceipt(), read companyName from AppConfig as fallback.
//   3. Replace the hard-coded 'STORE RECEIPT' with the AppConfig value,
//      falling back to 'STORE RECEIPT' only if AppConfig also has no name.
// ============================================================

// receipt_pdf_builder.dart

import 'package:flutter/foundation.dart';
import 'package:odocart/data/repositories/order_repository.dart';
import 'package:odocart/screens/orders_screen.dart';
import 'package:odocart/services/app_config.dart'; // already imported ✅
import 'package:odocart/services/odoo_service.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class ReceiptPdfBuilder {
  /// Build receipt PDF with actual order data.
  /// Supports both online (Odoo) and offline (SQLite) order states.
  static Future<Uint8List> buildReceipt({
    required OrderModel order,
    required bool isBasic,
  }) async {
    // Fetch order lines from API or local database
    List<Map<String, dynamic>> lines = [];

    try {
      final repo = OrderRepository();
      final localOrderId = order.id;
      final serverId = order.odooOrderId;

      // 1. Always try to load from local cache first for speed and offline use
      lines = await repo.getOrderLines(localOrderId);

      // 2. If synced order and online, fetch fresh data from Odoo
      //    to get the most accurate product names and tax data.
      if (serverId > 0) {
        bool isOnline = false;
        try {
          isOnline = await OdooService.checkConnection()
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          isOnline = false;
        }

        if (isOnline) {
          try {
            final freshLines = await OdooService.fetchOrderLines(serverId);
            if (freshLines.isNotEmpty) {
              lines = freshLines;
              await repo.saveOrderLines(localOrderId, freshLines);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching order lines: $e');
      }
      // Continue with empty lines if fetch fails
    }

    // ── Resolve company name ───────────────────────────────────
    // Priority:
    //   1. order.companyName — set when order is fetched from Odoo API
    //   2. AppConfig.getCompanyName() — saved when session was selected
    //   3. 'STORE RECEIPT' — last resort fallback (no company configured)
    //
    // Local/offline orders always have companyName = '' because they are
    // created before the server assigns a company. AppConfig fills this gap.
    String resolvedCompanyName = order.companyName.trim();
    if (resolvedCompanyName.isEmpty) {
      // Order has no company name — try the session-level company name
      resolvedCompanyName = await AppConfig.getCompanyName();
    }
    // If still empty, fall back to generic label
    final headerText = resolvedCompanyName.isNotEmpty
        ? resolvedCompanyName.toUpperCase()
        : 'STORE RECEIPT';

    final pdf = pw.Document();

    const rollFormat = PdfPageFormat(
      58 * PdfPageFormat.mm,
      double.infinity,
      marginTop: 4 * PdfPageFormat.mm,
      marginBottom: 4 * PdfPageFormat.mm,
      marginLeft: 3 * PdfPageFormat.mm,
      marginRight: 3 * PdfPageFormat.mm,
    );

    pdf.addPage(
      pw.Page(
        pageFormat: rollFormat,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── Header — shows company name or 'STORE RECEIPT' ──
              pw.Center(
                // Auto-fit font size based on company name length so it always
                // fits on the 58mm roll without wrapping to multiple lines.
                // Short name (≤16 chars) → 14pt, medium (≤24) → 11pt, long → 9pt
                child: pw.Text(
                  headerText,
                  style: pw.TextStyle(
                    fontSize: headerText.length <= 16
                        ? 14
                        : headerText.length <= 24
                            ? 11
                            : 9,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ),
              pw.SizedBox(height: 6),
              _buildDashedLine(),

              // ── Order Info ──────────────────────────────────────
              pw.SizedBox(height: 6),
              pw.Text(
                'Order: ${order.name}',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.Text(
                'Date: ${order.timeLabel}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Customer: ${order.customerName}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                'Status: ${order.statusLabel}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.SizedBox(height: 6),
              _buildDashedLine(),

              // ── Items Section (only if not basic) ───────────────
              if (!isBasic && lines.isNotEmpty) ...[
                pw.SizedBox(height: 6),
                pw.Text(
                  'ITEMS',
                  style: const pw.TextStyle(fontSize: 9),
                ),
                pw.SizedBox(height: 4),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: lines.map((line) {
                    final productName =
                        line['product_name'] as String? ?? 'Unknown';

                    final qty = ((line['qty'] ?? line['quantity']) as num?)
                            ?.toDouble() ??
                        0;

                    final priceUnit =
                        ((line['price_unit'] ?? line['price']) as num?)
                                ?.toDouble() ??
                            0;

                    final rawSubIncl =
                        (line['price_subtotal_incl'] as num?)?.toDouble() ?? 0;

                    final priceSubtotalIncl =
                        rawSubIncl > 0 ? rawSubIncl : (priceUnit * qty);

                    return pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Row(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Expanded(
                              child: pw.Text(
                                productName,
                                style: pw.TextStyle(
                                  fontSize: 9,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                                maxLines: 3,
                              ),
                            ),
                            pw.SizedBox(width: 6),
                            pw.Text(
                              priceSubtotalIncl.toStringAsFixed(2),
                              style: const pw.TextStyle(fontSize: 9),
                            ),
                          ],
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          '${qty % 1 == 0 ? qty.toInt() : qty} x ${priceUnit.toStringAsFixed(2)}',
                          style: pw.TextStyle(
                            fontSize: 8,
                            color: PdfColors.grey,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                      ],
                    );
                  }).toList(),
                ),
                pw.SizedBox(height: 6),
                _buildDashedLine(),
              ],

              // ── Summary ──────────────────────────────────────────
              pw.SizedBox(height: 6),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Items:', style: const pw.TextStyle(fontSize: 9)),
                  pw.Text('${order.lineCount}',
                      style: const pw.TextStyle(fontSize: 9)),
                ],
              ),

              // Determine if order has been paid.
              // Pending (draft/new): payment not yet collected — hide payment + total.
              // Cancelled: no payment collected — show CANCELLED stamp instead.
              // Paid (done/paid/invoiced): show payment method and total.
              if (order.state == 'cancel') ...[
                // Cancelled order — show a clear CANCELLED stamp instead of total
                pw.SizedBox(height: 8),
                _buildDashedLine(),
                pw.SizedBox(height: 8),
                pw.Center(
                  child: pw.Text(
                    '*** ORDER CANCELLED ***',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ] else if (order.state == 'draft' || order.state == 'new') ...[
                // Pending order — payment not yet confirmed, hide payment method.
                // Show a PENDING stamp so the receipt is clearly not a payment proof.
                pw.SizedBox(height: 8),
                _buildDashedLine(),
                pw.SizedBox(height: 8),
                pw.Center(
                  child: pw.Text(
                    '*** ORDER PENDING ***',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ] else ...[
                // Paid / synced order — show payment method and total normally.
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Payment:', style: const pw.TextStyle(fontSize: 9)),
                    pw.Text(order.paymentMethod,
                        style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
                pw.SizedBox(height: 8),
                _buildDashedLine(),

                // ── Total ─────────────────────────────────────────
                pw.SizedBox(height: 8),
                pw.Center(
                  child: pw.Column(
                    children: [
                      pw.Text('TOTAL', style: const pw.TextStyle(fontSize: 10)),
                      pw.Text(
                        '${AppConfig.currencySymbol}${order.amountTotal.toStringAsFixed(2)}',
                        style: pw.TextStyle(
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ── Footer ──────────────────────────────────────────
              pw.SizedBox(height: 8),
              _buildDashedLine(),
              pw.SizedBox(height: 6),
              pw.Center(
                child: pw.Text(
                  // Footer message varies by order state
                  order.state == 'cancel'
                      ? 'This order was cancelled.'
                      : (order.state == 'draft' || order.state == 'new')
                          ? 'Payment not yet collected.'
                          : 'Thank you for your purchase!',
                  style: const pw.TextStyle(fontSize: 9),
                  textAlign: pw.TextAlign.center,
                ),
              ),

              // Customer note (if present)
              if (order.customerNote.isNotEmpty) ...[
                pw.SizedBox(height: 6),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(6),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(4),
                    ),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'NOTE:',
                        style: pw.TextStyle(
                          fontSize: 8,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(order.customerNote,
                          style: const pw.TextStyle(fontSize: 8)),
                    ],
                  ),
                ),
              ],

              pw.SizedBox(height: 4),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  /// Build a dashed line separator for the receipt.
  static pw.Widget _buildDashedLine() {
    return pw.Row(
      children: List.generate(
        40,
        (index) => pw.Expanded(
          child: pw.Container(
            height: 1,
            color: PdfColors.grey600,
            margin: const pw.EdgeInsets.symmetric(horizontal: 0.5),
          ),
        ),
      ),
    );
  }
}
