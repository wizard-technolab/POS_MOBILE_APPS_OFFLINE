import 'package:flutter/material.dart';
import 'package:OdoCart/screens/orders_screen.dart';
import 'package:OdoCart/services/app_config.dart';
import 'print_controller.dart';

// ── Color Constants (match order_screen.dart) ──────────────────────────
const _kBg = Color(0xFF0D0F1C);
const _kCard = Color(0xFF151828);
const _kCardBorder = Color(0xFF1E2235);
const _kPurple = Color(0xFF6C63FF);
const _kTextPrimary = Color(0xFFFFFFFF);
const _kTextSecondary = Color(0xFF8B90A7);
const _kInputBg = Color(0xFF1A1D2E);
const _kGreen = Color(0xFF1DB954);
const _kOrange = Color(0xFFFF9800);

class ReceiptScreen extends StatefulWidget {
  // ✅ NEW: Accept order data
  final OrderModel order;

  const ReceiptScreen({
    super.key,
    required this.order,
  });

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  late PrintController _controller;

  @override
  void initState() {
    super.initState();
    // ✅ Pass order data to PrintController
    _controller = PrintController(order: widget.order);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSmallScreen = MediaQuery.of(context).size.width < 992;

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        title: const Text(
          'Receipt',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: _kTextSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: isSmallScreen ? _buildMobileLayout() : _buildDesktopLayout(),
      ),
    );
  }

  // ── Mobile Layout (vertical, scrollable) ──────────────────────────────
  Widget _buildMobileLayout() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSuccessBanner(),
                const SizedBox(height: 20),
                _buildOrderInfoSection(),
                const SizedBox(height: 20),
                _buildActionButtonsSection(),
                const SizedBox(height: 20),
                _buildShareButtonsSection(),
                const SizedBox(height: 20),
                // Receipt preview on mobile (below actions)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kCardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'RECEIPT PREVIEW',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Divider(
                        color: Colors.grey[300],
                        height: 1,
                      ),
                      const SizedBox(height: 12),
                      _buildReceiptPreview(),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
        _buildStickyBottomBar(true),
      ],
    );
  }

  // ── Desktop Layout (horizontal, two panels) ───────────────────────────
  Widget _buildDesktopLayout() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // ── Left Panel: Actions ──────────────────────────────
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSuccessBanner(),
                      const SizedBox(height: 20),
                      _buildOrderInfoSection(),
                      const SizedBox(height: 20),
                      _buildActionButtonsSection(),
                      const SizedBox(height: 20),
                      _buildShareButtonsSection(),
                    ],
                  ),
                ),
              ),

              // ── Right Panel: Receipt Preview ─────────────────────
              Expanded(
                flex: 1,
                child: Container(
                  color: _kInputBg,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    width: 300,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _kCardBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Text(
                            'RECEIPT PREVIEW',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Divider(
                            color: Colors.grey[300],
                            height: 1,
                          ),
                          const SizedBox(height: 12),
                          _buildReceiptPreview(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildStickyBottomBar(false),
      ],
    );
  }

  // ── Success Banner ───────────────────────────────────────────────────
  Widget _buildSuccessBanner() {
    // Pending orders (draft/new) have not been paid yet.
    // Show an orange "Order Pending" banner instead of green "Payment Successful".
    final bool isPending =
        widget.order.state == 'draft' || widget.order.state == 'new';

    // Pick banner color: orange for pending, green for paid/synced
    final Color bannerColor = isPending ? _kOrange : _kGreen;

    // Pick icon: hourglass for pending, checkmark for paid
    final IconData bannerIcon =
        isPending ? Icons.hourglass_top_rounded : Icons.check_circle_rounded;

    // Pick title text based on state
    final String bannerTitle = isPending
        ? 'Order Pending'
        : (widget.order.state == 'refund'
            ? 'Refund Processed'
            : 'Payment Successful');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bannerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Icon(
            bannerIcon,
            color: bannerColor,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            bannerTitle,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          // Show amount only for paid/synced orders.
          // Pending orders have not collected payment yet — hiding the amount
          // avoids showing "Cash ₹X" which would be misleading.
          if (!isPending)
            Text(
              '${AppConfig.currencySymbol}${widget.order.amountTotal.toStringAsFixed(2)}',
              style: const TextStyle(
                color: _kPurple,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }

  // ── Order Info Section ───────────────────────────────────────────────
  Widget _buildOrderInfoSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORDER DETAILS',
            style: TextStyle(
              color: _kTextSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          _infoRow('Order ID', widget.order.name),
          _infoRow('Customer', widget.order.customerName),
          _infoRow('Items', '${widget.order.lineCount}'),

          // Hide payment method for pending (draft/new) and cancelled orders.
          // Pending: payment has not been collected yet — showing "Cash" is misleading.
          // Cancelled: same logic already applied in PDF builder.
          if (widget.order.state != 'draft' &&
              widget.order.state != 'new' &&
              widget.order.state != 'cancel')
            _infoRow('Payment', widget.order.paymentMethod),

          _infoRow('Date', widget.order.timeLabel),
          _infoRow(
              'Status', widget.order.statusLabel, widget.order.statusColor),
        ],
      ),
    );
  }

  Future<void> _showPrinterSelector() async {
    await _controller.scanPrinters();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  height: 450,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Select Thermal Printer',
                        style: TextStyle(
                          color: _kTextPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _controller.availablePrinters.isEmpty
                            ? const Center(
                                child: Text(
                                  'No paired printers found',
                                  style: TextStyle(
                                    color: _kTextSecondary,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: _controller.availablePrinters.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (_, index) {
                                  final printer =
                                      _controller.availablePrinters[index];

                                  final isSelected =
                                      _controller.selectedPrinter?.macAdress ==
                                          printer.macAdress;

                                  return InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      final connected =
                                          await _controller.connectPrinter(
                                        printer,
                                      );

                                      if (!mounted) return;

                                      if (connected) {
                                        Navigator.pop(context);

                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            backgroundColor: _kGreen,
                                            content: Text(
                                              'Connected to ${printer.name}',
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: _kInputBg,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelected
                                              ? _kPurple
                                              : _kCardBorder,
                                          width: isSelected ? 2 : 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.print_rounded,
                                            color: isSelected
                                                ? _kPurple
                                                : _kTextSecondary,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  printer.name,
                                                  style: const TextStyle(
                                                    color: _kTextPrimary,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  printer.macAdress,
                                                  style: const TextStyle(
                                                    color: _kTextSecondary,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isSelected)
                                            const Icon(
                                              Icons.check_circle_rounded,
                                              color: _kGreen,
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Action Buttons ───────────────────────────────────────────────────
// ── Action Buttons ───────────────────────────────────────────────────
  Widget _buildActionButtonsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Print Full Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kPurple,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          onPressed: _controller.fullPrintStatus == ActionStatus.loading
              ? null
              : _controller.handleFullPrint,
          icon: _controller.fullPrintStatus == ActionStatus.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : const Icon(Icons.print_rounded, size: 18),
          label: Text(
            _controller.fullPrintStatus == ActionStatus.loading
                ? 'Printing...'
                : 'Print Full Receipt',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        const SizedBox(height: 10),

        // THERMAL PRINTER SELECTOR

        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: _kTextPrimary,
            side: const BorderSide(color: _kCardBorder),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _showPrinterSelector,
          icon: const Icon(
            Icons.bluetooth_searching_rounded,
          ),
          label: Text(
            _controller.selectedPrinter == null
                ? 'Select Thermal Printer'
                : 'Printer: ${_controller.selectedPrinter!.name}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        const SizedBox(height: 10),

        // THERMAL PRINT BUTTON

        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 0,
          ),
          onPressed: _controller.thermalPrintStatus == ActionStatus.loading
              ? null
              : _controller.handleThermalPrint,
          icon: _controller.thermalPrintStatus == ActionStatus.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                      Colors.white,
                    ),
                  ),
                )
              : const Icon(
                  Icons.receipt_long_rounded,
                ),
          label: Text(
            _controller.thermalPrintStatus == ActionStatus.loading
                ? 'Printing Thermal Receipt...'
                : 'Print Thermal Receipt',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        if (_controller.configBasicReceipt) ...[
          const SizedBox(height: 10),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kInputBg,
              foregroundColor: _kTextSecondary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: _kCardBorder),
              ),
              elevation: 0,
            ),
            onPressed: _controller.basicPrintStatus == ActionStatus.loading
                ? null
                : _controller.handleBasicPrint,
            icon: _controller.basicPrintStatus == ActionStatus.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(_kTextSecondary),
                    ),
                  )
                : const Icon(Icons.print_rounded, size: 18),
            label: Text(
              _controller.basicPrintStatus == ActionStatus.loading
                  ? 'Printing...'
                  : 'Print Basic Receipt',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Share Buttons (Email, WhatsApp, General Share) ──────────────────
  Widget _buildShareButtonsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'SHARE RECEIPT',
          style: TextStyle(
            color: _kTextSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 10),
        // Email Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kCard,
            foregroundColor: _kOrange,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: _kOrange, width: 1.5),
            ),
            elevation: 0,
          ),
          onPressed: _controller.emailStatus == ActionStatus.loading
              ? null
              : _controller.handleEmailReceipt,
          icon: _controller.emailStatus == ActionStatus.loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(_kOrange),
                  ),
                )
              : const Icon(Icons.mail_outline_rounded, size: 16),
          label: Text(
            _controller.emailStatus == ActionStatus.loading
                ? 'Sending...'
                : 'Send via Email',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // WhatsApp Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kCard,
            foregroundColor: _kGreen,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: _kGreen, width: 1.5),
            ),
            elevation: 0,
          ),
          onPressed: _controller.whatsappStatus == ActionStatus.loading
              ? null
              : _controller.handleWhatsappReceipt,
          icon: _controller.whatsappStatus == ActionStatus.loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(_kGreen),
                  ),
                )
              : const Icon(Icons.chat_bubble_outline_rounded, size: 16),
          label: Text(
            _controller.whatsappStatus == ActionStatus.loading
                ? 'Opening...'
                : 'Send via WhatsApp',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // General Share Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kCard,
            foregroundColor: _kPurple,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: _kPurple, width: 1.5),
            ),
            elevation: 0,
          ),
          onPressed: _controller.handleShareReceipt,
          icon: const Icon(Icons.share_rounded, size: 16),
          label: const Text(
            'Share Receipt',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // ── Receipt Preview (Mock thermal receipt) ────────────────────────────
  Widget _buildReceiptPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          widget.order.companyName.isNotEmpty
              ? widget.order.companyName.toUpperCase()
              : 'STORE RECEIPT',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Divider(color: Colors.grey[400], height: 1),
        const SizedBox(height: 8),
        Text(
          widget.order.timeLabel,
          style: const TextStyle(fontSize: 8, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          'Order: ${widget.order.name}',
          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.grey[300]!),
              bottom: BorderSide(color: Colors.grey[300]!),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Items',
                    style: TextStyle(fontSize: 8),
                  ),
                  Text(
                    '${widget.order.lineCount}',
                    style: const TextStyle(
                        fontSize: 8, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Customer',
                    style: TextStyle(fontSize: 8),
                  ),
                  Text(
                    widget.order.customerName,
                    style: const TextStyle(fontSize: 8),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'TOTAL',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
            Text(
              '${AppConfig.currencySymbol}${widget.order.amountTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Hide payment method label for pending (draft/new) and cancelled orders.
        // Only show it when the order is actually paid/synced.
        if (widget.order.state != 'draft' &&
            widget.order.state != 'new' &&
            widget.order.state != 'cancel')
          Text(
            widget.order.paymentMethod,
            style: const TextStyle(fontSize: 8, color: Colors.grey),
          ),
      ],
    );
  }

  // ── Sticky Bottom Bar ────────────────────────────────────────────────
  Widget _buildStickyBottomBar(bool isSmallScreen) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border(
          top: BorderSide(color: _kCardBorder),
        ),
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _kPurple,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
        onPressed: () => Navigator.pop(context),
        child: const Text(
          'New Order',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  // ── Info Row Helper ──────────────────────────────────────────────────
  Widget _infoRow(String label, String value, [Color? valueColor]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _kTextSecondary,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? _kTextPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}
