import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Callbacks for cart 3-dot actions menu (notes, split, cancel).
class CartActionsHandlers {
  final VoidCallback onProductNote;
  final VoidCallback onCustomerNotePerProduct;
  final VoidCallback onSplitBill;
  final VoidCallback onCancelOrder;

  const CartActionsHandlers({
    required this.onProductNote,
    required this.onCustomerNotePerProduct,
    required this.onSplitBill,
    required this.onCancelOrder,
  });
}

/// Bottom sheet: Note, Customer Note (per product), Split, Cancel Order.
class CartActionsSheet {
  CartActionsSheet._();

  static void show(BuildContext context, CartActionsHandlers handlers) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.cardBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(sheetContext),
                      child: const Icon(Icons.arrow_back_rounded,
                          color: AppColors.textPrimary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Actions',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.cardBorder, height: 1),
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined,
                    color: AppColors.textPrimary, size: 22),
                title: const Text('Note',
                    style:
                        TextStyle(color: AppColors.textPrimary, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  handlers.onProductNote();
                },
              ),
              const Divider(color: AppColors.cardBorder, height: 1),
              ListTile(
                leading: const Icon(Icons.person_outline_rounded,
                    color: AppColors.textPrimary, size: 22),
                title: const Text('Customer Note (Per Product)',
                    style:
                        TextStyle(color: AppColors.textPrimary, fontSize: 15)),
                subtitle: const Text('Shown on receipt — per product',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  handlers.onCustomerNotePerProduct();
                },
              ),
              const Divider(color: AppColors.cardBorder, height: 1),
              ListTile(
                leading: const Icon(Icons.call_split_rounded,
                    color: AppColors.textPrimary, size: 22),
                title: const Text('Split',
                    style:
                        TextStyle(color: AppColors.textPrimary, fontSize: 15)),
                subtitle: const Text('Divide bill equally among guests',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  handlers.onSplitBill();
                },
              ),
              const Divider(color: AppColors.cardBorder, height: 1),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.red, size: 22),
                title: const Text('Cancel Order',
                    style: TextStyle(color: AppColors.red, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  handlers.onCancelOrder();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
