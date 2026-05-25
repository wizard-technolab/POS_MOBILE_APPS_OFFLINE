import 'package:flutter/material.dart';
import '../../../services/cart_service.dart';
import '../cart_theme.dart';

// ─────────────────────────────────────────────────
// PRODUCT NOTE SHEET — Odoo POS style note editor
// Preset tag buttons + free-text input
// ─────────────────────────────────────────────────
class ProductNoteSheet extends StatefulWidget {
  final CartItem item;
  final List<String> presetTags;
  final ValueChanged<String> onApply;
  // noteLabel: 'Add Note' (kitchen), 'Customer Note' (customer-facing)
  final String noteLabel;
  // initialNote: explicitly pre-fills the text field.
  // null  → default to kitchen note (widget.item.note) — used by kitchen note sheet.
  // ''    → blank field — used by customer note sheet when no note saved yet.
  // 'xyz' → pre-fill with existing customer note.
  final String? initialNote;

  const ProductNoteSheet({
    super.key,
    required this.item,
    required this.presetTags,
    required this.onApply,
    this.noteLabel = 'Add Note',
    this.initialNote, // null = use item.note; '' = blank; 'xyz' = pre-fill
  });

  @override
  State<ProductNoteSheet> createState() => ProductNoteSheetState();
}

class ProductNoteSheetState extends State<ProductNoteSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // initialNote == null → kitchen note sheet → pre-fill with item.note
    // initialNote != null → customer note sheet → use initialNote as-is (may be empty)
    _ctrl = TextEditingController(
      text: widget.initialNote ?? widget.item.note,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Appends a preset tag to the text input (space-separated if not empty)
  void _applyTag(String tag) {
    final current = _ctrl.text.trim();
    _ctrl.text = current.isEmpty ? tag : '$current $tag';
    // Move cursor to end
    _ctrl.selection =
        TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Push sheet above keyboard
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: CartTheme.cardBorder,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            // Title: "ProductName: Add Note"
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.arrow_back_rounded,
                      color: CartTheme.textPrimary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${widget.item.name}: ${widget.noteLabel}',
                    style: const TextStyle(
                      color: CartTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Preset tag chips — tap to append to text field
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.presetTags.map((tag) {
                return GestureDetector(
                  onTap: () => _applyTag(tag),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: CartTheme.inputBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: CartTheme.cardBorder),
                    ),
                    child: Text(
                      tag,
                      style: const TextStyle(
                          color: CartTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            // Free-text input
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(color: CartTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Type a custom note...',
                hintStyle: const TextStyle(color: CartTheme.textSecondary),
                filled: true,
                fillColor: CartTheme.inputBg,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: CartTheme.cardBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: CartTheme.cardBorder)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: CartTheme.purple)),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 16),
            // Apply / Discard buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      widget.onApply(_ctrl.text.trim()); // Save note
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: CartTheme.purple,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: const Text('Apply',
                        style: TextStyle(
                            color: CartTheme.textPrimary,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: CartTheme.cardBorder),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Discard',
                        style: TextStyle(color: CartTheme.textSecondary)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
