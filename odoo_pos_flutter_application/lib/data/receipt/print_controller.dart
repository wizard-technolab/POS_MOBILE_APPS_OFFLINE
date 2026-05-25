import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:OdoCart/data/repositories/order_repository.dart';
import 'package:OdoCart/screens/orders_screen.dart';
import 'package:OdoCart/services/app_config.dart';
import 'package:OdoCart/services/odoo_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'receipt_pdf_builder.dart';

enum ActionStatus { idle, loading, success, error }

class PrintController extends ChangeNotifier {
  // ✅ Order data
  final OrderModel order;

  ActionStatus fullPrintStatus = ActionStatus.idle;
  ActionStatus basicPrintStatus = ActionStatus.idle;
  ActionStatus emailStatus = ActionStatus.idle;
  ActionStatus whatsappStatus = ActionStatus.idle;

  // ─────────────────────────────────────────────────────────────────────
  // THERMAL PRINTER
  // ─────────────────────────────────────────────────────────────────────

  ActionStatus thermalPrintStatus = ActionStatus.idle;

  List<BluetoothInfo> availablePrinters = [];

  BluetoothInfo? selectedPrinter;

  static const String _printerAddressKey = 'thermal_printer_address';
  static const String _printerNameKey = 'thermal_printer_name';

  late bool configBasicReceipt;
  late double orderAmountPlusTip;

  PrintController({required this.order}) {
    configBasicReceipt = true;
    orderAmountPlusTip = order.amountTotal;

    _loadSavedPrinter();
  }

  // ─────────────────────────────────────────────────────────────────────
  // PDF HELPERS
  // ─────────────────────────────────────────────────────────────────────

  /// Generate and save receipt PDF temporarily
  Future<File> _generatePdfFile({
    required bool isBasic,
  }) async {
    final Uint8List pdfBytes = await ReceiptPdfBuilder.buildReceipt(
      order: order,
      isBasic: isBasic,
    );

    final tempDir = await getTemporaryDirectory();

    final file = File(
      '${tempDir.path}/${isBasic ? 'basic' : 'full'}_receipt_${order.name}.pdf',
    );

    await file.writeAsBytes(pdfBytes);

    return file;
  }

  // ─────────────────────────────────────────────────────────────────────
  // PRINT METHODS
  // ─────────────────────────────────────────────────────────────────────

  Future<void> handleFullPrint() async {
    fullPrintStatus = ActionStatus.loading;
    notifyListeners();

    try {
      await Printing.layoutPdf(
        onLayout: (format) async => await ReceiptPdfBuilder.buildReceipt(
          order: order,
          isBasic: false,
        ),
        name: order.name,
      );

      fullPrintStatus = ActionStatus.success;

      await Future.delayed(const Duration(seconds: 2));

      fullPrintStatus = ActionStatus.idle;
    } catch (e) {
      debugPrint('❌ Print error: $e');

      fullPrintStatus = ActionStatus.error;

      await Future.delayed(const Duration(seconds: 2));

      fullPrintStatus = ActionStatus.idle;
    }

    notifyListeners();
  }

  Future<bool> requestBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> handleBasicPrint() async {
    basicPrintStatus = ActionStatus.loading;

    notifyListeners();

    try {
      await Printing.layoutPdf(
        onLayout: (format) async => await ReceiptPdfBuilder.buildReceipt(
          order: order,
          isBasic: true,
        ),
        name: order.name,
      );

      basicPrintStatus = ActionStatus.success;

      await Future.delayed(const Duration(seconds: 2));

      basicPrintStatus = ActionStatus.idle;
    } catch (e) {
      debugPrint('❌ Print error: $e');

      basicPrintStatus = ActionStatus.error;

      await Future.delayed(const Duration(seconds: 2));

      basicPrintStatus = ActionStatus.idle;
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────
  // EMAIL
  // ─────────────────────────────────────────────────────────────────────

  Future<void> handleEmailReceipt() async {
    emailStatus = ActionStatus.loading;

    notifyListeners();

    try {
      final file = await _generatePdfFile(isBasic: false);

      final email = Email(
        body: 'Please find attached receipt.',
        subject: 'Receipt - ${order.name}',
        attachmentPaths: [file.path],
        isHTML: false,
      );

      await FlutterEmailSender.send(email);

      emailStatus = ActionStatus.success;

      await Future.delayed(const Duration(seconds: 1));

      emailStatus = ActionStatus.idle;
    } catch (e) {
      debugPrint('❌ Email error: $e');

      emailStatus = ActionStatus.error;

      await Future.delayed(const Duration(seconds: 2));

      emailStatus = ActionStatus.idle;
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────
  // WHATSAPP
  // ─────────────────────────────────────────────────────────────────────

  Future<void> handleWhatsappReceipt() async {
    whatsappStatus = ActionStatus.loading;

    notifyListeners();

    try {
      final file = await _generatePdfFile(isBasic: false);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Receipt for order ${order.name}\n'
            'Total: ${AppConfig.currencySymbol}${order.amountTotal.toStringAsFixed(2)}',
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      );

      whatsappStatus = ActionStatus.success;

      await Future.delayed(const Duration(seconds: 1));

      whatsappStatus = ActionStatus.idle;
    } catch (e) {
      debugPrint('❌ WhatsApp share error: $e');

      whatsappStatus = ActionStatus.error;

      await Future.delayed(const Duration(seconds: 2));

      whatsappStatus = ActionStatus.idle;
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────
  // THERMAL PRINTER HELPERS
  // ─────────────────────────────────────────────────────────────────────
  Future<void> _loadSavedPrinter() async {
    try {
      final prefs = await AppConfig.preferences;

      final savedAddress = prefs.getString(_printerAddressKey);
      final savedName = prefs.getString(_printerNameKey);

      if (savedAddress != null && savedName != null) {
        selectedPrinter = BluetoothInfo(
          name: savedName,
          macAdress: savedAddress,
        );

        notifyListeners();
      }
    } catch (e) {
      debugPrint('❌ Failed loading saved printer: $e');
    }
  }

  Future<void> saveSelectedPrinter(BluetoothInfo printer) async {
    try {
      final prefs = await AppConfig.preferences;

      await prefs.setString(
        _printerAddressKey,
        printer.macAdress,
      );

      await prefs.setString(
        _printerNameKey,
        printer.name,
      );

      selectedPrinter = printer;

      notifyListeners();
    } catch (e) {
      debugPrint('❌ Failed saving printer: $e');
    }
  }

  Future<void> scanPrinters() async {
    try {
      final granted = await requestBluetoothPermissions();

      if (!granted) return;

      availablePrinters = await PrintBluetoothThermal.pairedBluetooths;

      notifyListeners();
    } catch (e) {
      debugPrint('❌ Failed scanning printers: $e');
    }
  }

  Future<bool> connectPrinter(BluetoothInfo printer) async {
    try {
      final connected = await PrintBluetoothThermal.connect(
        macPrinterAddress: printer.macAdress,
      );

      if (connected) {
        await saveSelectedPrinter(printer);
      }

      notifyListeners();

      return connected;
    } catch (e) {
      debugPrint('❌ Failed connecting printer: $e');

      return false;
    }
  }

  Future<List<int>> _buildThermalReceiptBytes() async {
    List<Map<String, dynamic>> lines = [];

    try {
      final repo = OrderRepository();
      final localOrderId = order.id;
      final serverId = order.odooOrderId;

      // 1. Try local SQLite cache first
      lines = await repo.getOrderLines(localOrderId);

      // 2. If order is synced to Odoo and online, prefer fresh data from server
      if (serverId > 0) {
        bool isOnline = false;
        try {
          isOnline = await OdooService.checkConnection()
              .timeout(const Duration(seconds: 2));
        } catch (_) {}

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
      debugPrint('❌ Failed fetching order lines: $e');
    }

    final profile = await CapabilityProfile.load();

    final generator = Generator(
      PaperSize.mm58,
      profile,
    );

    List<int> bytes = [];

    bytes += generator.text(
      order.companyName.isNotEmpty
          ? order.companyName.toUpperCase()
          : 'STORE RECEIPT',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );

    bytes += generator.feed(1);

    bytes += generator.text(
      order.timeLabel,
      styles: const PosStyles(
        align: PosAlign.center,
      ),
    );

    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(
        text: 'Order',
        width: 5,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: order.name,
        width: 7,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += generator.row([
      PosColumn(
        text: 'Customer',
        width: 5,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: order.customerName,
        width: 7,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += generator.row([
      PosColumn(
        text: 'Payment',
        width: 5,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: order.paymentMethod,
        width: 7,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);

    bytes += generator.hr();

    for (final line in lines) {
      final productName = line['product_name'] as String? ?? 'Unknown Product';

      final qty = ((line['qty'] ?? line['quantity']) as num?)?.toDouble() ?? 0;

      final priceUnit =
          ((line['price_unit'] ?? line['price']) as num?)?.toDouble() ?? 0;

      // BUG FIX: explicitly check > 0 so the fallback fires for both null AND 0.0
      final rawSubIncl = (line['price_subtotal_incl'] as num?)?.toDouble() ?? 0;

      final subtotal = rawSubIncl > 0 ? rawSubIncl : (qty * priceUnit);

      bytes += generator.text(
        productName,
        styles: const PosStyles(
          bold: true,
        ),
      );

      bytes += generator.row([
        PosColumn(
          text:
              '${qty % 1 == 0 ? qty.toInt() : qty} x ${priceUnit.toStringAsFixed(2)}',
          width: 6,
        ),
        PosColumn(
          text: subtotal.toStringAsFixed(2),
          width: 6,
          styles: const PosStyles(
            align: PosAlign.right,
          ),
        ),
      ]);

      bytes += generator.feed(1);
    }

    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(
        text: 'Items',
        width: 6,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: '${order.lineCount}',
        width: 6,
        styles: const PosStyles(
          align: PosAlign.right,
        ),
      ),
    ]);

    bytes += generator.feed(1);

    bytes += generator.row([
      PosColumn(
        text: 'TOTAL',
        width: 6,
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
      PosColumn(
        text:
            '${AppConfig.currencySymbol}${order.amountTotal.toStringAsFixed(2)}',
        width: 6,
        styles: const PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    ]);

    bytes += generator.hr();

    if (order.customerNote.isNotEmpty) {
      bytes += generator.text(
        'NOTE:',
        styles: const PosStyles(
          bold: true,
        ),
      );

      bytes += generator.text(order.customerNote);

      bytes += generator.hr();
    }

    bytes += generator.text(
      'Thank you for your purchase!',
      styles: const PosStyles(
        align: PosAlign.center,
      ),
    );

    bytes += generator.feed(3);

    return bytes;
  }

  // ─────────────────────────────────────────────────────────────────────
  // THERMAL PRINT
  // ─────────────────────────────────────────────────────────────────────

  Future<void> handleThermalPrint() async {
    thermalPrintStatus = ActionStatus.loading;

    notifyListeners();

    try {
      final granted = await requestBluetoothPermissions();

      if (!granted) {
        thermalPrintStatus = ActionStatus.error;

        notifyListeners();

        return;
      }

      if (selectedPrinter == null) {
        debugPrint('❌ No printer selected');

        thermalPrintStatus = ActionStatus.error;

        notifyListeners();

        return;
      }

      final connected = await connectPrinter(selectedPrinter!);

      if (!connected) {
        debugPrint('❌ Failed connecting printer');

        thermalPrintStatus = ActionStatus.error;

        notifyListeners();

        return;
      }

      final bytes = await _buildThermalReceiptBytes();

      await PrintBluetoothThermal.writeBytes(bytes);

      thermalPrintStatus = ActionStatus.success;

      await Future.delayed(const Duration(seconds: 2));

      thermalPrintStatus = ActionStatus.idle;
    } catch (e) {
      debugPrint('❌ Thermal print error: $e');

      thermalPrintStatus = ActionStatus.error;

      await Future.delayed(const Duration(seconds: 2));

      thermalPrintStatus = ActionStatus.idle;
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────
  // GENERAL SHARE
  // ─────────────────────────────────────────────────────────────────────

  Future<void> handleShareReceipt() async {
    try {
      final file = await _generatePdfFile(isBasic: false);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Receipt - ${order.name}',
        text: 'Receipt for order ${order.name}\n'
            'Total: ${AppConfig.currencySymbol}${order.amountTotal.toStringAsFixed(2)}',
      );
    } catch (e) {
      debugPrint('❌ Share error: $e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
