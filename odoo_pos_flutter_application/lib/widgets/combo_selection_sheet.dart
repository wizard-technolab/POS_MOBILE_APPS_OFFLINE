// ─────────────────────────────────────────────────────────────
// combo_selection_sheet.dart
// Bottom sheet that lets the user configure a combo product
// before adding it to the cart.
// ─────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import '../services/app_config.dart';
import 'package:odocart/models/combo_model.dart';
import 'package:odocart/services/cart_service.dart';

// ── Colors (same palette as the rest of the app) ──────────
const _kBg = Color(0xFF0D0F1C);
const _kCard = Color(0xFF151828);
const _kCardBorder = Color(0xFF1E2235);
const _kPurple = Color(0xFF6C63FF);
const _kPurpleLight = Color(0xFF8B83FF);
const _kGreen = Color(0xFF1DB954);
const _kOrange = Color(0xFFE8A020);
const _kRed = Color(0xFFE53935);
const _kTextPrimary = Color(0xFFFFFFFF);
const _kTextSecondary = Color(0xFF8B90A7);
const _kInputBg = Color(0xFF1A1D2E);

// ── Entry point: open the combo sheet and return the cartKey
// on success, or null if the user dismissed without adding.
Future<String?> showComboSelectionSheet(
  BuildContext context,
  ComboProduct combo,
) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: _kCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ComboSelectionSheet(combo: combo),
  );
}

class _ComboSelectionSheet extends StatefulWidget {
  final ComboProduct combo;
  const _ComboSelectionSheet({required this.combo});

  @override
  State<_ComboSelectionSheet> createState() => _ComboSelectionSheetState();
}

class _ComboSelectionSheetState extends State<_ComboSelectionSheet> {
  ComboSelection _selection = ComboSelection.empty();

  // User-selected quantity for this combo, defaults to 1
  int _comboQty = 1;

  // Shorthand
  ComboProduct get _combo => widget.combo;

  // Current total price = (base + extras) × qty chosen by user
  double get _currentTotal =>
      (_combo.basePrice + _selection.extraTotal) * _comboQty;

  // Whether all required groups are satisfied
  bool get _canAdd => _selection.isComplete(_combo.groups);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollController) {
        return Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                children: [
                  _buildProgressBar(),
                  const SizedBox(height: 16),
                  ..._combo.groups.map(_buildGroup),
                  const SizedBox(height: 100), // space for bottom bar
                ],
              ),
            ),
            _buildBottomBar(context),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    debugPrint('🎁 Opened combo sheet for: ${widget.combo.name}');
    debugPrint('📦 Groups: ${widget.combo.groups.length}');
    for (final g in widget.combo.groups) {
      debugPrint('  - ${g.groupName}: ${g.choices.length} choices');
    }
  }

  // ── Header ───────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _kCardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kOrange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kOrange.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'COMBO',
                  style: TextStyle(
                    color: _kOrange,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _combo.name,
                  style: const TextStyle(
                    color: _kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${AppConfig.currencySymbol}${_combo.basePrice.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: _kPurpleLight,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose items from each group below to complete your combo.',
            style: TextStyle(color: _kTextSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── Progress bar (one segment per group) ─────────────────
  Widget _buildProgressBar() {
    return Row(
      children: _combo.groups.map((group) {
        final chosen = _selection.selectedChoices[group.groupId]?.length ?? 0;
        final done = chosen >= group.minQty || !group.isRequired;
        return Expanded(
          child: Container(
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: done ? _kOrange : _kCardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ── One group card ────────────────────────────────────────
  Widget _buildGroup(ComboGroup group) {
    final chosen = _selection.selectedChoices[group.groupId]?.length ?? 0;
    final isDone = chosen >= group.minQty || !group.isRequired;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDone ? _kGreen.withValues(alpha: 0.4) : _kCardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Group header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            group.groupName,
                            style: const TextStyle(
                              color: _kTextPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Required / Optional badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: group.isRequired
                                  ? _kPurple.withValues(alpha: 0.15)
                                  : _kInputBg,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              group.isRequired ? 'required' : 'optional',
                              style: TextStyle(
                                color: group.isRequired
                                    ? _kPurpleLight
                                    : _kTextSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        group.maxQty == 1
                            ? 'Choose 1 (${group.isRequired ? 'required' : 'optional'})'
                            : 'Choose up to ${group.maxQty}',
                        style: const TextStyle(
                          color: _kTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Done check mark
                if (isDone)
                  Row(
                    children: const [
                      Icon(Icons.check_rounded, color: _kGreen, size: 16),
                      SizedBox(width: 4),
                      Text(
                        'Done',
                        style: TextStyle(
                          color: _kGreen,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                else
                  // Show count remaining for multi-select groups
                  Text(
                    '$chosen/${group.maxQty}',
                    style: const TextStyle(
                      color: _kTextSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: _kCardBorder),

          // Choice rows
          ...group.choices.map((choice) => _buildChoiceRow(group, choice)),
        ],
      ),
    );
  }

  // ── One choice row inside a group ────────────────────────
  Widget _buildChoiceRow(ComboGroup group, ComboChoice choice) {
    final isSelected = _selection.isSelected(group.groupId, choice.productId);
    final isAvailable = choice.isAvailable;

    return GestureDetector(
      onTap: isAvailable
          ? () {
              setState(() {
                _selection = _selection.withChoice(group, choice);
              });
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: !isAvailable
              ? _kRed.withValues(alpha: 0.08)
              : isSelected
                  ? _kGreen.withValues(alpha: 0.12)
                  : _kInputBg.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: !isAvailable
                ? _kRed.withValues(alpha: 0.45)
                : isSelected
                    ? _kGreen
                    : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            // Radio / checkbox indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: isSelected ? _kGreen : Colors.transparent,
                shape: group.maxQty == 1 ? BoxShape.circle : BoxShape.rectangle,
                borderRadius:
                    group.maxQty > 1 ? BorderRadius.circular(6) : null,
                border: Border.all(
                  color: !isAvailable
                      ? _kRed.withValues(alpha: 0.7)
                      : isSelected
                          ? _kGreen
                          : _kTextSecondary,
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 14)
                  : null,
            ),
            const SizedBox(width: 12),

            // Choice name
            Expanded(
              child: Text(
                choice.productName,
                style: TextStyle(
                  color: !isAvailable
                      ? _kTextSecondary.withValues(alpha: 0.55)
                      : isSelected
                          ? _kTextPrimary
                          : _kTextSecondary,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),

            // Extra price / stock label
            Text(
              !isAvailable
                  ? 'Out of stock'
                  : choice.extraPrice == 0
                      ? '+${AppConfig.currencySymbol}0'
                      : '+${AppConfig.currencySymbol}${choice.extraPrice.toStringAsFixed(0)}',
              style: TextStyle(
                color: !isAvailable
                    ? _kRed
                    : isSelected
                        ? _kGreen
                        : _kTextSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Bottom bar: total + qty counter + Add button ─────────
  Widget _buildBottomBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: BoxDecoration(
        color: _kCard,
        border: const Border(top: BorderSide(color: _kCardBorder)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Qty row: price on left, +/- counter on right ──
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Combo Total',
                    style: TextStyle(color: _kTextSecondary, fontSize: 12),
                  ),
                  Text(
                    // Total updates live as qty changes
                    '${AppConfig.currencySymbol}${_currentTotal.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: _kPurpleLight,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // ── Quantity stepper (default 1, min 1) ─────────
              Row(
                children: [
                  // Minus button — disabled at qty = 1
                  GestureDetector(
                    onTap: () {
                      if (_comboQty > 1) {
                        setState(() => _comboQty--);
                      }
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _comboQty <= 1
                            ? _kInputBg.withValues(alpha: 0.5)
                            : _kInputBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.remove_rounded,
                        color: _comboQty <= 1
                            ? _kTextSecondary.withValues(alpha: 0.4)
                            : _kTextSecondary,
                        size: 18,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      '$_comboQty',
                      style: const TextStyle(
                        color: _kTextPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Plus button
                  GestureDetector(
                    onTap: () => setState(() => _comboQty++),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _kPurple,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.add_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ── Add to Cart button ───────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _canAdd ? () => _addToCart(context) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kOrange,
                disabledBackgroundColor: _kOrange.withValues(alpha: 0.4),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(
                // Show qty in button label so user gets confirmation
                'Add $_comboQty Combo${_comboQty > 1 ? "s" : ""} to Cart',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addToCart(BuildContext context) {
    // Pass _comboQty so cart stores the correct quantity right away
    final cartKey = CartService.instance.addConfiguredCombo(
      combo: _combo,
      selection: _selection,
      qty: _comboQty,
    );
    Navigator.of(context).pop(cartKey); // returns the cartKey to caller
  }
}
