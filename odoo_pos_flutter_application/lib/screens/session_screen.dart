import 'package:flutter/material.dart';
import 'package:odocart/widgets/top_notification.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../services/app_config.dart';
import '../services/api_client.dart';
import '../services/cart_service.dart';
import '../services/db_helper.dart';
import '../data/repositories/order_repository.dart';
import '../services/odoo_service.dart';
import 'login_screen.dart';

// ─────────────────────────────────────────────
// COLORS
// ─────────────────────────────────────────────
const kBg = Color(0xFF0D0F1C);
const kCard = Color(0xFF151828);
const kCardBorder = Color(0xFF1E2235);
const kPurple = Color(0xFF6C63FF);
const kPurpleLight = Color(0xFF8B83FF);
const kGreen = Color(0xFF1DB954);
const kOrange = Color(0xFFE8A020);
const kRed = Color(0xFFE53935);
const kTextPrimary = Color(0xFFFFFFFF);
const kTextSecondary = Color(0xFF8B90A7);
const kInputBg = Color(0xFF1A1D2E);

class PosSessionScreen extends StatefulWidget {
  const PosSessionScreen({super.key});

  @override
  State<PosSessionScreen> createState() => _PosSessionScreenState();
}

class _PosSessionScreenState extends State<PosSessionScreen> {
  bool _isLoadingSessions = false;
  List<Map<String, dynamic>> _posSessions = [];

  @override
  void initState() {
    super.initState();
    _loadPosSessions();
  }

  // ─────────────────────────────────────────────
  // LOAD SESSIONS
  // ─────────────────────────────────────────────

  Future<void> _loadPosSessions() async {
    setState(() => _isLoadingSessions = true);

    try {
      // First try to load from local database
      final localSessions = await _loadSessionsFromLocal();

      if (localSessions.isNotEmpty) {
        if (mounted) {
          setState(() {
            _posSessions = localSessions;
            _isLoadingSessions = false;
          });
        }
        // Try to refresh from server in background
        _refreshSessionsFromServer();
        return;
      }

      // If no local sessions, try to fetch from server
      final sessions = await _fetchPosSessionsFromOdoo();

      if (sessions.isNotEmpty) {
        // Save to local database
        await DatabaseHelper().saveOrUpdateSessions(sessions);
      }

      if (mounted) {
        setState(() {
          _posSessions = sessions;
          _isLoadingSessions = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingSessions = false);
    }
  }

  Future<List<Map<String, dynamic>>> _loadSessionsFromLocal() async {
    try {
      final dbHelper = DatabaseHelper();
      return await dbHelper.getSessionsOffline();
    } catch (_) {
      return [];
    }
  }

  Future<void> _refreshSessionsFromServer() async {
    try {
      final sessions = await _fetchPosSessionsFromOdoo();
      if (sessions.isNotEmpty) {
        // Save to local database
        await DatabaseHelper().saveOrUpdateSessions(sessions);
        // Update UI if still mounted
        if (mounted) {
          setState(() => _posSessions = sessions);
        }
      }
    } catch (_) {
      // Silent fail - keep local sessions
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPosSessionsFromOdoo() async {
    final response = await ApiClient.get(
      '/api/v1/pos-sessions',
      timeout: const Duration(seconds: 10),
    );

    final data = jsonDecode(response.body);

    if (data['status'] == 'success' && data['data'] is List) {
      return List<Map<String, dynamic>>.from(data['data']);
    }

    return [];
  }

  // ─────────────────────────────────────────────
  // SESSION SELECTION
  // ─────────────────────────────────────────────

  // Save current cart as a draft/pending order if:
  // 1. The cart is not empty, AND
  // 2. User is switching to a DIFFERENT session (not re-selecting the same one)
  // This prevents cart items from being silently discarded on session switch.
  Future<void> _saveCartAsDraftIfSessionChanging(int newSessionId) async {
    try {
      final currentSessionId = await AppConfig.getPosSessionId();

      // Same session re-selected — no action needed
      if (currentSessionId == newSessionId) return;

      final cart = CartService.instance;
      final hasItems = cart.cart.isNotEmpty || cart.comboCart.isNotEmpty;

      // Cart is empty — nothing to save
      if (!hasItems) return;

      final deviceCode = await AppConfig.getDeviceCode();
      final companyName = await AppConfig.getCompanyName();
      final orderRepo = OrderRepository();
      final externalId = const Uuid().v4();

      // Build order lines from regular cart items
      final lines = <Map<String, dynamic>>[];
      for (final item in cart.cart.values) {
        lines.add({
          'product_id': item.productId,
          'product_name': item.name, // shown in order detail list
          'quantity': item.qty,
          'price': item.price,
          // Use each item's own taxRate (not the cart average) for accurate line tax
          'tax_rate': item.taxRate,
          'note': item.note, // kitchen / internal note
          'customer_note': item.customerNote, // per-item customer note
          'image': item.image, // Explicitly include product image
          // JSON-encoded variant pairs — displayed as chips in detail sheet
          'variant_attributes': jsonEncode(item.variantAttributes),
        });
      }
      // Add combo items as flattened order lines
      for (final combo in cart.comboCart.values) {
        lines.addAll(combo.toOrderLines(taxRate: cart.taxRate));
      }

      if (lines.isEmpty) return;

      // ── EDITING PENDING ORDER: Update existing draft instead of creating new ──
      // If the cashier had restored a pending order via "Add back to cart" and then
      // switches session without paying, UPDATE the original order instead of
      // creating a second draft row for the same order.
      if (cart.editingPendingLocalId != null) {
        await orderRepo.updateOfflineOrder(
          orderId: cart.editingPendingLocalId!,
          lines: lines,
          total: cart.total,
          taxAmount: cart.taxAmount,
          customerId: cart.customerNotifier.value?.id ?? 0,
          customerName: cart.customerNotifier.value?.name,
          customerNote: cart.customerNoteNotifier.value,
        );
        debugPrint(
            '💾 Updated existing pending order ${cart.editingPendingLocalId} on session switch');
        // editingPending fields are cleared by CartService.clearCartForSessionSwitch()
        // which is called right after this method returns.
        return;
      }
      // ── END EDITING PENDING ORDER ────────────────────────────────────────────

      // Save as a local draft — synced=0 means it will appear in Orders as pending
      final orderId = await orderRepo.createOfflineOrder(
        externalId: externalId,
        deviceCode: deviceCode,
        customerId: cart.customerNotifier.value?.id ?? 0,
        customerName: cart.customerNotifier.value?.name,
        sessionId: currentSessionId,
        customerNote: cart.customerNoteNotifier.value,
        lines: lines,
        total: cart.total,
        taxAmount: cart.taxAmount,
        companyName: companyName,
      );

      debugPrint(
          '💾 Saved \${lines.length} cart item(s) as pending order before session switch');

      // Also sync the draft to Odoo so it appears in the POS backend orders list.
      // This is fire-and-forget — if it fails, order is still saved in SQLite
      // and the user can pay it later from the app pending list.
      try {
        final odooLines = lines
            .map((line) => {
                  'product_id': line['product_id'] as int,
                  'qty': (line['quantity'] as num?)?.toInt() ??
                      (line['qty'] as num?)?.toInt() ??
                      1,
                  'price': (line['price'] as num?)?.toDouble() ?? 0.0,
                  'tax_rate': (line['tax_rate'] as num?)?.toDouble() ?? 0.0,
                  'note': line['note'] as String? ?? '',
                  'customer_note': line['customer_note'] as String? ?? '',
                  'is_combo': line['is_combo'] == true || line['is_combo'] == 1,
                  'combo_parent_id': line['combo_parent_id'],
                  'combo_name': line['combo_name'] as String? ?? '',
                })
            .toList();

        final serverId = await OdooService.syncLocalDraftToOdoo(
          externalId: externalId,
          sessionId: currentSessionId,
          deviceCode: deviceCode,
          customerId: cart.customerNotifier.value?.id,
          customerNote: cart.customerNoteNotifier.value,
          lines: odooLines,
          totalAmount: cart.total,
        );

        // Link local ID to server ID to avoid duplicates
        if (orderId > 0 && serverId > 0) {
          await orderRepo.saveDraftOdooOrderId(orderId, serverId);
        }
        debugPrint('☁️ Draft order synced to Odoo before session switch');
      } catch (odooErr) {
        // Non-fatal — order already saved in SQLite, user can pay from pending list
        debugPrint(
            '⚠️ Could not sync draft to Odoo on session switch: \$odooErr');
      }
    } catch (e) {
      // Non-fatal — log and continue with session switch
      debugPrint('⚠️ Could not save cart as draft on session change: $e');
    }
  }

  Future<void> _onSessionSelected(Map<String, dynamic> session) async {
    final id = session['id'] as int;
    final posName = session['pos_config_name'] as String? ?? '';
    final sessionName = session['name'] as String? ?? '';

    final displayName =
        posName.isNotEmpty ? '$sessionName — $posName' : sessionName;

    // No need to call saveOrUpdateSessions([session]) here — the full session
    // list was already saved when it was fetched from the server. Calling it
    // with a single item would delete all other sessions from the local DB.

    // If cart has items and user is switching to a different session,
    // save those items as a pending (draft) order before clearing the cart.
    // This ensures no items are lost — user can find them in Orders screen.
    await _saveCartAsDraftIfSessionChanging(id);

    // Use clearCartForSessionSwitch() instead of clearCart().
    // clearCart() deletes pending_cart_items rows which can cause a race condition
    // (reads session ID async after new session is already saved → wrong session deleted).
    CartService.instance.clearCartForSessionSwitch();

    await AppConfig.savePosSessionId(id);
    await AppConfig.savePosSessionName(displayName);
    await AppConfig.saveRawPosSessionName(
        sessionName); // Store raw name for order sequence generation

    // Save currency symbol from the selected session so AppConfig.currencySymbol
    // shows the backend currency (e.g. ₹, $, €) instead of the default.
    final rawSymbol = session['currency_symbol'] as String? ?? '₹';
    await AppConfig.setCurrencySymbol(rawSymbol);

    // ── FIX: Save company name so offline receipts show the correct header ──
    // The session API returns company_id as [id, "Company Name"] (Odoo many2one
    // format). We extract index [1] and persist it in SharedPreferences.
    // Without this call, AppConfig.getCompanyName() always returns '' and the
    // receipt PDF builder falls back to the generic 'STORE RECEIPT' label.
    final companyRaw = session['company_id'];
    final companyNameFromSession = (companyRaw is List && companyRaw.length > 1)
        ? companyRaw[1].toString().trim()
        : '';
    if (companyNameFromSession.isNotEmpty) {
      await AppConfig.saveCompanyName(companyNameFromSession);
    }
    // ── END FIX ─────────────────────────────────────────────────────────────

    if (mounted) {
      _showSnack('✅ Session selected: $displayName', kGreen);

      // Navigate to MainShell after a brief delay for UX
      await Future.delayed(const Duration(milliseconds: 800));

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const MainShell(),
          ),
        );
      }
    }
  }

  // ─────────────────────────────────────────────
  // SIGN OUT
  // ─────────────────────────────────────────────

  Future<void> _signOut() async {
    // Before clearing auth, save any active cart items as a pending draft.
    // This prevents items from being silently lost on logout.
    // We use the current session ID (not a "new" one) so the draft is saved
    // under the correct session and appears in the Orders screen.
    final cart = CartService.instance;
    final hasItems = cart.cart.isNotEmpty || cart.comboCart.isNotEmpty;

    if (hasItems) {
      try {
        final currentSessionId = await AppConfig.getPosSessionId();
        final deviceCode = await AppConfig.getDeviceCode();
        final orderRepo = OrderRepository();
        final companyName = await AppConfig.getCompanyName();

        // ── FIX: Prevent duplicate draft on logout when editing a pending order ──
        //
        // ROOT CAUSE (old code):
        //   `const Uuid().v4()` always generated a brand-new UUID, even when
        //   the user had restored a pending order to the cart and then logged out.
        //   This caused two drafts: the original pending order + a new duplicate.
        //
        // FIX:
        //   If the cart is currently editing a pending order (editingPendingExternalId
        //   is set), reuse that same external_id so the Odoo UPSERT logic finds the
        //   existing draft and updates it instead of creating a new one.
        //   Also pass odooOrderId so Odoo can match by DB id as a fallback.
        final isEditingPending = cart.editingPendingLocalId != null;
        final externalId = cart.editingPendingExternalId ?? const Uuid().v4();
        final odooOrderId =
            cart.editingPendingOdooOrderId; // null for fresh carts

        // Include ALL display fields so the pending order looks identical
        // to a synced order in the Order History detail sheet.
        final lines = <Map<String, dynamic>>[];
        for (final item in cart.cart.values) {
          lines.add({
            'product_id': item.productId,
            'product_name': item.name, // shown in order detail list
            'quantity': item.qty,
            'price': item.price,
            // Use each item's own taxRate for accurate line tax
            'tax_rate': item.taxRate,
            'note': item.note, // kitchen / internal note
            'customer_note': item.customerNote, // per-item customer note
            'image': item.image, // Explicitly include product image
            // JSON-encoded variant pairs — chips in detail sheet
            'variant_attributes': jsonEncode(item.variantAttributes),
          });
        }
        for (final combo in cart.comboCart.values) {
          lines.addAll(combo.toOrderLines(taxRate: cart.taxRate));
        }

        if (lines.isNotEmpty) {
          int orderId;

          if (isEditingPending && cart.editingPendingLocalId != null) {
            // UPDATE the existing local draft order — do NOT create a new one.
            // This prevents a duplicate entry in the local SQLite orders table.
            await orderRepo.updateOfflineOrder(
              orderId: cart.editingPendingLocalId!,
              lines: lines,
              total: cart.total,
              taxAmount: cart.taxAmount,
              customerId: cart.customerNotifier.value?.id ?? 0,
              customerName: cart.customerNotifier.value?.name,
              customerNote: cart.customerNoteNotifier.value,
            );
            orderId = cart.editingPendingLocalId!;
            debugPrint(
                '💾 Updated existing pending order $orderId on logout (${lines.length} lines)');
          } else {
            // Fresh cart — create a new local draft as usual.
            orderId = await orderRepo.createOfflineOrder(
              externalId: externalId,
              deviceCode: deviceCode,
              customerId: cart.customerNotifier.value?.id ?? 0,
              customerName: cart.customerNotifier.value?.name,
              sessionId: currentSessionId,
              customerNote: cart.customerNoteNotifier.value,
              lines: lines,
              total: cart.total,
              taxAmount: cart.taxAmount,
              companyName: companyName,
            );
            debugPrint(
                '💾 Saved ${lines.length} cart item(s) as pending order on logout');
          }

          // Also sync the draft to Odoo so it appears in the POS backend orders list.
          // Fire-and-forget — failure is non-fatal; user can pay from pending list later.
          try {
            final odooLines = lines
                .map((line) => {
                      'product_id': line['product_id'] as int,
                      'qty': (line['quantity'] as num?)?.toInt() ?? 1,
                      'price': (line['price'] as num?)?.toDouble() ?? 0.0,
                      'tax_rate': (line['tax_rate'] as num?)?.toDouble() ?? 0.0,
                      'note': line['note'] as String? ?? '',
                      'customer_note': line['customer_note'] as String? ?? '',
                    })
                .toList();

            // Pass odooOrderId so the backend can find the original draft by
            // Odoo DB id even if the externalId has changed (restored order case).
            final serverId = await OdooService.syncLocalDraftToOdoo(
              externalId: externalId,
              odooOrderId: odooOrderId,
              sessionId: currentSessionId,
              deviceCode: deviceCode,
              customerId: cart.customerNotifier.value?.id,
              customerNote: cart.customerNoteNotifier.value,
              lines: odooLines,
              totalAmount: cart.total,
            );

            // Link local ID to server ID to avoid duplicates
            if (orderId > 0 && serverId > 0) {
              await orderRepo.saveDraftOdooOrderId(orderId, serverId);
            }
            debugPrint('☁️ Draft order synced to Odoo on logout');
          } catch (odooErr) {
            debugPrint('⚠️ Could not sync draft to Odoo on logout: \$odooErr');
          }
        }
      } catch (e) {
        // Non-fatal — log and continue with logout
        debugPrint('⚠️ Could not save cart as draft on logout: $e');
      }

      // Clear cart so the next login starts fresh regardless of session
      CartService.instance.clearCart();
    }

    // Clear only the current auth session. Keep saved email/password and
    // subscription data so re-login does not ask for the subscription code again.
    await AppConfig.clear();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const LoginScreen(),
      ),
      (route) => false,
    );
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────

  void _showSnack(String msg, Color color) {
    // Show notification at the top of the screen instead of bottom snackbar
    showTopNotification(
      context,
      msg,
      color: color,
      duration: const Duration(seconds: 2),
    );
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _buildBody(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Select POS Session',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              IconButton(
                onPressed: _signOut,
                icon: const Icon(
                  Icons.logout_rounded,
                  color: kRed,
                  size: 22,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose which POS session this device will use to place orders.',
            style: TextStyle(
              color: kTextSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    // Loading state
    if (_isLoadingSessions) {
      return const Center(
        child: CircularProgressIndicator(
          color: kPurple,
          strokeWidth: 2.5,
        ),
      );
    }

    // No sessions
    if (_posSessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: kRed.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.point_of_sale_rounded,
                  color: kRed,
                  size: 40,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'No POS Sessions Found',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please open a POS session in Odoo first, then refresh.',
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isLoadingSessions ? null : _loadPosSessions,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: kTextPrimary,
                    size: 18,
                  ),
                  label: const Text(
                    'Refresh Sessions',
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPurple,
                    disabledBackgroundColor: kPurple.withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Sessions list
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          ..._posSessions.asMap().entries.map((entry) {
            final index = entry.key;
            final session = entry.value;
            final posName = session['pos_config_name'] as String? ?? '';
            final sessionName = session['name'] as String? ?? '';
            final displayName =
                posName.isNotEmpty ? '$sessionName — $posName' : sessionName;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SessionCard(
                title: displayName,
                sessionName: sessionName,
                posName: posName,
                index: index,
                total: _posSessions.length,
                onTap: () => _onSessionSelected(session),
              ),
            );
          }),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SESSION CARD WIDGET
// ─────────────────────────────────────────────

class _SessionCard extends StatefulWidget {
  final String title;
  final String sessionName;
  final String posName;
  final int index;
  final int total;
  final VoidCallback onTap;

  const _SessionCard({
    required this.title,
    required this.sessionName,
    required this.posName,
    required this.index,
    required this.total,
    required this.onTap,
  });

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _isPressed ? kCard.withValues(alpha: 0.8) : kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isPressed ? kPurple : kCardBorder,
            width: _isPressed ? 2 : 1,
          ),
          boxShadow: _isPressed
              ? [
                  BoxShadow(
                    color: kPurple.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [kPurple, kPurpleLight],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.point_of_sale_rounded,
                    color: kTextPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.sessionName,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.posName.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            widget.posName,
                            style: const TextStyle(
                              color: kTextSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: kPurple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.index + 1}/${widget.total}',
                    style: const TextStyle(
                      color: kPurple,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 1,
              color: kCardBorder,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: kGreen.withValues(alpha: 0.6),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Open & Ready',
                  style: TextStyle(
                    color: kGreen.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: kTextSecondary.withValues(alpha: 0.5),
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
