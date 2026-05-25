import 'package:flutter/material.dart';
import '../../../models/combo_model.dart';
import '../cart_theme.dart';

// ─────────────────────────────────────────────────
// COMBO NOTE SHEET — same Odoo-style editor but for ComboCartItem
// Uses cartKey (uuid) so each combo instance is updated independently
// ─────────────────────────────────────────────────
class ComboNoteSheet extends StatefulWidget {
  final ComboCartItem combo;
  final List<String> presetTags;
  final ValueChanged<String> onApply;
  // noteLabel: 'Add Note' (kitchen), 'Customer Note' (customer-facing)
  final String noteLabel;
  // initialNote: allows pre-filling with customerNote instead of kitchen note
  final String initialNote;

  const ComboNoteSheet({
    required this.combo,
    required this.presetTags,
    required this.onApply,
    this.noteLabel = 'Add Note',
    String? initialNote,
  }) : initialNote = initialNote ?? '';

  @override
  State<ComboNoteSheet> createState() => ComboNoteSheetState();
}

class ComboNoteSheetState extends State<ComboNoteSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // If initialNote is given (customer note), use it; otherwise fall back to kitchen note
    _ctrl = TextEditingController(
      text: widget.initialNote ?? widget.combo.note,
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
    _ctrl.selection =
        TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            // Title with COMBO badge + name
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.arrow_back_rounded,
                      color: CartTheme.textPrimary, size: 20),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: CartTheme.orange,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('COMBO',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.combo.comboName}: ${widget.noteLabel}',
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
            // Preset tag chips
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
                      widget.onApply(_ctrl.text.trim()); // Save combo note
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
