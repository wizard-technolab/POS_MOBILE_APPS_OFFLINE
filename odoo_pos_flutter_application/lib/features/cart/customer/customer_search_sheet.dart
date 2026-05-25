import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../services/cart_service.dart';
import 'customer_form_sheet.dart';
import 'customer_service.dart';

// ─────────────────────────────────────────────────
// CUSTOMER SEARCH SHEET
// ─────────────────────────────────────────────────
class CustomerSearchSheet extends StatefulWidget {
  // returnMode = true → pop with Map<String,dynamic> instead of setting cart customer.
  // Used by Split Bill sheet to pick a person from Odoo customers.
  final bool returnMode;
  const CustomerSearchSheet({super.key, this.returnMode = false});

  @override
  State<CustomerSearchSheet> createState() => CustomerSearchSheetState();
}

class CustomerSearchSheetState extends State<CustomerSearchSheet> {
  final _searchCtrl = TextEditingController();
  bool _loading = false;
  String _error = '';
  List<Map<String, dynamic>> _results = [];

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _fetchCustomers('');
    _searchCtrl.addListener(() {
      if (_debounce?.isActive ?? false) _debounce!.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        _fetchCustomers(_searchCtrl.text.trim());
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  final _customerService = CustomerService();

  Future<void> _fetchCustomers(String query) async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      final list = await _customerService.searchCustomers(query);
      if (mounted) {
        setState(() => _results = list);
      }
    } catch (_) {
      final local = await _customerService.searchLocal(query);
      if (mounted) {
        setState(() {
          _results = local;
          _error = local.isEmpty ? 'No offline customers found' : '';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _select(Map<String, dynamic> c) {
    if (widget.returnMode) {
      // Split mode — return the selected customer map to caller
      Navigator.pop(context, c);
    } else {
      // Normal mode — set as cart customer and close
      CartService.instance.setCustomer(SelectedCustomer(
        id: c['id'] as int,
        name: c['name'] as String? ?? '',
        phone: c['phone'] as String? ?? '',
        email: c['email'] as String? ?? '',
      ));
      Navigator.pop(context);
    }
  }

  // ── Open Customer Form Sheet ──────────────────────────────
  // existing = null  → New Customer mode
  // existing = {...} → Edit Customer mode (pre-fills the form)
  // After save, auto-selects the saved customer and closes the search sheet.
  void _openCustomerForm(BuildContext context,
      {required Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => CustomerFormSheet(existing: existing),
    );

    // If form returned a saved customer map, auto-select and close search
    if (result != null && mounted) {
      _select(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.cardBorder,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            // ── Header: Title + New Customer button ──────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Choose Customer',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                  // New Customer button — opens customer form sheet
                  TextButton.icon(
                    onPressed: () => _openCustomerForm(context, existing: null),
                    icon: const Icon(Icons.person_add_rounded,
                        color: AppColors.purple, size: 18),
                    label: const Text('New',
                        style: TextStyle(
                            color: AppColors.purple,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search by name or phone...',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.inputBg,
                  prefixIcon: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: AppColors.purple, strokeWidth: 2)),
                        )
                      : const Icon(Icons.search_rounded,
                          color: AppColors.textSecondary, size: 20),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded,
                              color: AppColors.textSecondary, size: 18),
                          onPressed: () => _searchCtrl.clear(),
                        )
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AppColors.cardBorder)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AppColors.cardBorder)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.purple)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error,
                    style: const TextStyle(color: AppColors.red, fontSize: 13)),
              ),
            Expanded(
              child: _results.isEmpty && !_loading
                  ? const Center(
                      child: Text('No customers found',
                          style: TextStyle(color: AppColors.textSecondary)),
                    )
                  : ListView.separated(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _results.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: AppColors.cardBorder, height: 1),
                      itemBuilder: (_, i) {
                        final c = _results[i];
                        final name = c['name'] as String? ?? '';
                        final phone = c['phone'] as String? ?? '';
                        final email = c['email'] as String? ?? '';
                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 4),
                          leading: CircleAvatar(
                            backgroundColor: AppColors.purple,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          title: Text(name,
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            [phone, email]
                                .where((s) => s.isNotEmpty)
                                .join('  ·  '),
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 12),
                          ),
                          // Edit icon — opens form pre-filled with this customer's data
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_rounded,
                                color: AppColors.textSecondary, size: 18),
                            tooltip: 'Edit customer',
                            onPressed: () =>
                                _openCustomerForm(context, existing: c),
                          ),
                          onTap: () => _select(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
