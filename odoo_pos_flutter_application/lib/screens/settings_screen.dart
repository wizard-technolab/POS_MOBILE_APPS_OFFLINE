// lib/screens/settings_screen.dart

import 'dart:async';
import 'dart:convert'; // For jsonEncode — used to encode variant_attributes list

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:odocart/widgets/top_notification.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../services/odoo_service.dart';
import '../services/app_config.dart' hide sessionChangeNotifier;
import '../services/cart_service.dart';
import '../data/repositories/order_repository.dart';
import '../models/user_model.dart';
import '../models/sync_model.dart';
import '../services/sync_manager.dart' show SyncManager;
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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isSavingPos = false;

  bool _isOnline = true;

  // Real-time connectivity listener — updates _isOnline instantly on wifi drop/restore.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  UserModel? _user;
  SyncModel? _syncData;

  final _deviceCodeCtrl = TextEditingController();

  String _savedEmail = '';
  String _selectedSessionName = '';
  String _licenseCode = '';
  String _expiryDate = '';
  int _daysRemaining = 0;
  bool _licenseCodeVisible = false;
  String _adminEmail = '';

  @override
  void initState() {
    super.initState();
    _loadAllData();
    // Reload sync status when session changes in this same screen
    sessionChangeNotifier.addListener(_onSessionChangedReloadStatus);
    // Reload when app comes back to foreground
    WidgetsBinding.instance.addObserver(this);
    _startConnectivityListener();
  }

  // Called when session is selected — refresh sync counts for new session
  void _onSessionChangedReloadStatus() {
    if (mounted) _loadSyncStatus();
  }

  // Listens to real-time connectivity changes.
  // Updates _isOnline instantly when wifi drops or restores.
  void _startConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final isOnline =
          result.isNotEmpty && result.first != ConnectivityResult.none;
      if (mounted && _isOnline != isOnline) {
        setState(() => _isOnline = isOnline);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _loadAllData();
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    sessionChangeNotifier.removeListener(_onSessionChangedReloadStatus);
    WidgetsBinding.instance.removeObserver(this);
    _deviceCodeCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────
  // LOAD DATA
  // ─────────────────────────────────────────

  Future<void> _loadAllData() async {
    setState(() => _isLoading = true);

    await Future.wait([
      _loadConfig(),
      _loadUserData(),
      _loadSyncStatus(),
      _checkConnectionStatus(),
      _loadLicenseInfo(),
    ]);

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadConfig() async {
    final email = await AppConfig.getApiEmail();
    final deviceCode = await AppConfig.getDeviceCode();

    if (!mounted) return;

    _savedEmail = email;
    _deviceCodeCtrl.text = deviceCode;
  }

  Future<void> _loadUserData() async {
    final user = await OdooService.getCurrentUser();

    if (!mounted) return;
    setState(() => _user = user);
  }

  Future<void> _loadSyncStatus() async {
    final sync = await OdooService.getSyncStatus();

    // Load current session name
    final sessionName = await AppConfig.getPosSessionName();

    if (!mounted) return;
    setState(() {
      _syncData = sync;
      _selectedSessionName = sessionName;
    });
  }

  Future<void> _checkConnectionStatus() async {
    // Start with current state (don't block)
    // If user was online before, assume online
    final lastKnownState = _isOnline;
    setState(() => _isOnline = lastKnownState);

    // Check in background with short timeout
    try {
      final isConnected = await OdooService.checkConnection()
          .timeout(const Duration(seconds: 2));

      if (mounted) {
        setState(() => _isOnline = isConnected);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isOnline = false);
      }
    }
  }

  // ✅ NEW: Load license/subscription information
  Future<void> _loadLicenseInfo() async {
    final email = await AppConfig.getApiEmail();
    final code = await AppConfig.getSubscriptionCode();
    final expDate = await AppConfig.getSubscriptionExpDate();
    final daysLeft = await AppConfig.getSubscriptionDaysRemaining();

    if (!mounted) return;
    setState(() {
      _adminEmail = email;
      _licenseCode = code;
      _expiryDate = expDate;
      _daysRemaining = daysLeft;
    });
  }

  // ─────────────────────────────────────────
  // POS CONFIG SAVE
  // ─────────────────────────────────────────

  Future<void> _savePosConfig() async {
    final deviceCode = _deviceCodeCtrl.text.trim();

    if (deviceCode.isEmpty) {
      _showSnack('Device Code cannot be empty.', kOrange);
      return;
    }

    setState(() => _isSavingPos = true);

    await AppConfig.saveDeviceCode(deviceCode);

    if (!mounted) return;

    setState(() => _isSavingPos = false);
    _showSnack('✅ POS Config saved successfully.', kGreen);
  }

  // ─────────────────────────────────────────
  // SYNC
  // ─────────────────────────────────────────

  Future<void> _handleSync() async {
    setState(() => _isSyncing = true);

    final success = await SyncManager().syncNow();

    await _loadSyncStatus();

    if (!mounted) return;

    setState(() => _isSyncing = false);

    if (success) {
      _showSnack('✅ Sync completed successfully', kGreen);
    } else {
      _showSnack('⚠️ Sync failed or server unreachable', kOrange);
    }
  }

  // ─────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────

  void _showSnack(String msg, Color color) {
    // Show notification at the top of the screen instead of bottom snackbar
    showTopNotification(
      context,
      msg,
      color: color,
      duration: const Duration(seconds: 3),
    );
  }

  // Opens the account detail bottom sheet that contains
  // LICENSE & CONNECTION info and POS ORDER CONFIGURATION.
  // Triggered when the user taps on the profile card.
  void _openAccountSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AccountDetailSheet(
        isOnline: _isOnline,
        licenseCode: _licenseCode,
        expiryDate: _expiryDate,
        daysRemaining: _daysRemaining,
        adminEmail: _adminEmail,
        deviceCodeCtrl: _deviceCodeCtrl,
        isSavingPos: _isSavingPos,
        onSavePosConfig: _savePosConfig,
        licenseCodeVisible: _licenseCodeVisible,
        onToggleLicenseVisibility: () {
          setState(() => _licenseCodeVisible = !_licenseCodeVisible);
          // Rebuild sheet by closing and reopening so it reflects new state.
          // Simpler approach: pass a ValueNotifier or use StatefulBuilder inside sheet.
          Navigator.of(context).pop();
          _openAccountSheet();
        },
      ),
    );
  }

  Future<void> _signOut() async {
    if (!_isOnline) {
      _showSnack(
          'Cannot sign out while offline. Please connect to the internet to ensure your local data is synced to Odoo.',
          kOrange);
      return;
    }

    // Save any active cart items as a pending draft before clearing auth.
    // This ensures no items are silently lost when the user logs out from Settings.
    final cart = CartService.instance;
    final hasItems = cart.cart.isNotEmpty || cart.comboCart.isNotEmpty;

    if (hasItems) {
      try {
        final currentSessionId = await AppConfig.getPosSessionId();
        final deviceCode = await AppConfig.getDeviceCode();
        final orderRepo = OrderRepository();

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

        // Build order lines from regular cart items
        final lines = <Map<String, dynamic>>[];
        for (final item in cart.cart.values) {
          lines.add({
            'product_id': item.productId,
            'product_name': item.name,
            'quantity': item.qty,
            'price': item.price,
            // Use each item's own taxRate for accurate per-line tax
            'tax_rate': item.taxRate,
            'note': item.note,
            // Save customer note so Order History detail shows it correctly
            'customer_note': item.customerNote,
            // Save image so item detail popup shows product image
            'image': item.image,
            // Save variant attributes so detail chips show (e.g. Size: 4XL)
            'variant_attributes': jsonEncode(item.variantAttributes),
          });
        }
        // Add combo items as flattened order lines
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
                '💾 Updated existing pending order $orderId on Settings logout (${lines.length} lines)');
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
            );
            debugPrint(
                '💾 Saved ${lines.length} cart item(s) as pending order on logout from Settings');
          }

          // Also sync the draft to Odoo so it appears in the POS backend orders list.
          // Fire-and-forget — failure here is non-fatal; user can pay from pending list.
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
                      'is_combo':
                          line['is_combo'] == true || line['is_combo'] == 1,
                      'combo_parent_id': line['combo_parent_id'],
                      'combo_name': line['combo_name'] as String? ?? '',
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

            // Link the local order to the Odoo order ID to prevent double syncs
            if (orderId > 0 && serverId > 0) {
              await orderRepo.saveDraftOdooOrderId(orderId, serverId);
            }
            debugPrint('☁️ Draft order synced to Odoo on Settings logout');
          } catch (odooErr) {
            debugPrint(
                '⚠️ Could not sync draft to Odoo on Settings logout: $odooErr');
          }
        }
      } catch (e) {
        debugPrint('⚠️ Could not save cart draft on logout: $e');
      }

      // Clear the in-memory and persisted cart so next login starts fresh
      CartService.instance.clearCart();
    }

    // Clear only the current auth session. Keep saved email/password and
    // subscription data so re-login does not ask for the subscription code again.
    await AppConfig.clear();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  // ─────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: kPurple),
              )
            : RefreshIndicator(
                color: kPurple,
                backgroundColor: kCard,
                onRefresh: _loadAllData,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 24),
                      _buildHeader(),
                      const SizedBox(height: 24),
                      _buildProfileCard(),
                      const SizedBox(height: 20),
                      _buildSessionCard(),
                      const SizedBox(height: 20),
                      _buildSyncStatusSection(),
                      const SizedBox(height: 20),
                      _buildGeneralSection(),
                      const SizedBox(height: 20),
                      _buildSignOutButton(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        IconButton(
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => const MainShell(),
              ),
            );
          },
          icon: const Icon(
            Icons.close_rounded,
            color: kTextPrimary,
            size: 28,
          ),
        ),
      ],
    );
  }

  Widget _buildProfileCard() {
    final hasSavedCreds = _savedEmail.isNotEmpty;
    final name = _user?.name ?? (hasSavedCreds ? _savedEmail : 'Not connected');
    final email = _user?.email ?? (hasSavedCreds ? _savedEmail : '—');
    final role = _user?.role ??
        (hasSavedCreds ? (_isOnline ? 'Connected' : 'Offline Mode') : '—');
    final initials = (_user?.name != null && _user!.name.isNotEmpty)
        ? _user!.name[0].toUpperCase()
        : (hasSavedCreds ? _savedEmail[0].toUpperCase() : '?');

    return GestureDetector(
      onTap: _openAccountSheet,
      child: _Card(
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [kPurple, kPurpleLight],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                initials,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email,
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    role,
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            // Arrow icon to indicate the card is tappable
            const Icon(
              Icons.chevron_right_rounded,
              color: kTextSecondary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard() {
    return _SectionBlock(
      label: 'CURRENT POS SESSION',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kPurple.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPurple.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [kPurple, kPurpleLight],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.login_rounded,
                color: kTextPrimary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Session',
                    style: TextStyle(
                      color: kTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _selectedSessionName.isNotEmpty
                        ? _selectedSessionName
                        : 'No session selected',
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.check_circle_rounded,
              color: _selectedSessionName.isNotEmpty ? kGreen : kOrange,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncStatusSection() {
    final synced = _syncData?.synced ?? 0;
    final pending = _syncData?.pending ?? 0;
    final failed = _syncData?.failed ?? 0;
    final lastSynced = _syncData?.lastSynced ?? 'Never';

    return _SectionBlock(
      label: 'SYNC STATUS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _SyncBadge(
                  count: synced,
                  label: 'Synced',
                  color: kGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SyncBadge(
                  count: pending,
                  label: 'Pending',
                  color: kOrange,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SyncBadge(
                  count: failed,
                  label: 'Failed',
                  color: kRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Last synced time — tap to refresh
          GestureDetector(
            onTap: _loadSyncStatus,
            child: Row(
              children: [
                const Icon(
                  Icons.access_time_rounded,
                  color: kTextSecondary,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Last synced: $lastSynced',
                    style: const TextStyle(
                      color: kTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                // Tap to refresh icon
                const Icon(
                  Icons.refresh_rounded,
                  color: kTextSecondary,
                  size: 14,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Sync Now button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSyncing ? null : _handleSync,
              style: ElevatedButton.styleFrom(
                backgroundColor: kPurple,
                disabledBackgroundColor: kPurple.withValues(alpha: 0.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
              ),
              child: _isSyncing
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kTextPrimary,
                      ),
                    )
                  : const Text(
                      'Sync Now',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralSection() => _SectionBlock(
        label: 'GENERAL',
        child: Column(
          children: [
            _SettingsTile(
              icon: Icons.language_rounded,
              label: 'Language',
              value: 'English',
            ),
            const _InfoRowDivider(),
            _SettingsTile(
              icon: Icons.receipt_long_rounded,
              label: 'Receipt Printer',
              value: 'Connected',
            ),
            const _InfoRowDivider(),
            _SettingsTile(
              icon: Icons.dark_mode_rounded,
              label: 'Theme',
              value: 'Dark',
            ),
            const _InfoRowDivider(),
            _SettingsTile(
              icon: Icons.notifications_rounded,
              label: 'Notifications',
              value: 'On',
            ),
          ],
        ),
      );

  Widget _buildSignOutButton() => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _signOut,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2A1215),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text(
            'Sign Out',
            style: TextStyle(
              color: kRed,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

// ─────────────────────────────────────────────
// ACCOUNT DETAIL BOTTOM SHEET
// Contains License & Connection + POS Order Configuration.
// Opened when the user taps the profile card on Settings.
// ─────────────────────────────────────────────

class _AccountDetailSheet extends StatefulWidget {
  final bool isOnline;
  final String licenseCode;
  final String expiryDate;
  final int daysRemaining;
  final String adminEmail;
  final TextEditingController deviceCodeCtrl;
  final bool isSavingPos;
  final VoidCallback onSavePosConfig;
  final bool licenseCodeVisible;
  final VoidCallback onToggleLicenseVisibility;

  const _AccountDetailSheet({
    required this.isOnline,
    required this.licenseCode,
    required this.expiryDate,
    required this.daysRemaining,
    required this.adminEmail,
    required this.deviceCodeCtrl,
    required this.isSavingPos,
    required this.onSavePosConfig,
    required this.licenseCodeVisible,
    required this.onToggleLicenseVisibility,
  });

  @override
  State<_AccountDetailSheet> createState() => _AccountDetailSheetState();
}

class _AccountDetailSheetState extends State<_AccountDetailSheet> {
  // Local toggle so the eye icon works without reopening the sheet
  late bool _licenseVisible;

  // Track real-time online status inside the sheet independently.
  // widget.isOnline is only the value at the time the sheet was opened —
  // we need our own listener so the sheet reacts to connectivity changes
  // without needing to be closed and reopened.
  late bool _sheetIsOnline;
  StreamSubscription<List<ConnectivityResult>>? _sheetConnectivitySub;

  @override
  void initState() {
    super.initState();
    _licenseVisible = widget.licenseCodeVisible;

    // Start with the value passed from the parent screen
    _sheetIsOnline = widget.isOnline;

    // Also do a quick real connectivity check on open to catch stale parent value
    OdooService.checkConnection()
        .timeout(const Duration(seconds: 2))
        .then((connected) {
      if (mounted) setState(() => _sheetIsOnline = connected);
    }).catchError((_) {
      if (mounted) setState(() => _sheetIsOnline = false);
    });

    // Listen for live connectivity changes while sheet is open
    _sheetConnectivitySub =
        Connectivity().onConnectivityChanged.listen((result) {
      final isOnline =
          result.isNotEmpty && result.first != ConnectivityResult.none;
      if (mounted && _sheetIsOnline != isOnline) {
        setState(() => _sheetIsOnline = isOnline);
      }
    });
  }

  @override
  void dispose() {
    // Cancel connectivity listener when sheet is closed to avoid memory leaks
    _sheetConnectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasLicense = widget.licenseCode.isNotEmpty;
    final isExpired = widget.daysRemaining <= 0;
    final isWarning = widget.daysRemaining <= 7 && widget.daysRemaining > 0;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: kCardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // Sheet title
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Account Details',
                    style: TextStyle(
                      color: kTextPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Scrollable content
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── LICENSE & CONNECTION SECTION ──
                      _buildSectionLabel('LICENSE & CONNECTION'),
                      const SizedBox(height: 10),
                      _Card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Online / License status badges
                            Row(
                              children: [
                                _StatusBadge(
                                  icon: _sheetIsOnline
                                      ? Icons.cloud_done_rounded
                                      : Icons.cloud_off_rounded,
                                  label: _sheetIsOnline ? 'Online' : 'Offline',
                                  color: _sheetIsOnline ? kGreen : kOrange,
                                ),
                                const Spacer(),
                                _StatusBadge(
                                  icon: hasLicense
                                      ? (isExpired
                                          ? Icons.warning_amber
                                          : Icons.verified_user_rounded)
                                      : Icons.lock_clock_rounded,
                                  label: hasLicense
                                      ? (isExpired ? 'Expired' : 'Active')
                                      : 'Not Activated',
                                  color: hasLicense
                                      ? (isExpired ? kRed : kGreen)
                                      : kOrange,
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Divider(
                                color: kCardBorder, height: 1, thickness: 1),
                            const SizedBox(height: 16),

                            // Admin email field
                            _LicenseField(
                              label: 'Admin Email',
                              value: widget.adminEmail.isNotEmpty
                                  ? widget.adminEmail
                                  : 'Not configured',
                              icon: Icons.mail_rounded,
                              iconColor: kPurple,
                            ),
                            const SizedBox(height: 14),

                            // License code with eye toggle
                            _LicenseField(
                              label: 'License Code',
                              value: widget.licenseCode.isNotEmpty
                                  ? widget.licenseCode
                                  : 'Not activated',
                              icon: Icons.vpn_key_rounded,
                              iconColor: hasLicense ? kGreen : kOrange,
                              isObscured: hasLicense && !_licenseVisible,
                              onToggleObscure: hasLicense
                                  ? () => setState(
                                      () => _licenseVisible = !_licenseVisible)
                                  : null,
                            ),
                            const SizedBox(height: 14),

                            // Expiry date
                            _LicenseField(
                              label: 'Expiry Date',
                              value: widget.expiryDate.isNotEmpty
                                  ? widget.expiryDate
                                  : '—',
                              icon: Icons.calendar_today_rounded,
                              iconColor: isExpired
                                  ? kRed
                                  : (isWarning ? kOrange : kGreen),
                            ),
                            const SizedBox(height: 14),

                            // Days remaining with progress bar
                            Row(
                              children: [
                                Icon(
                                  Icons.hourglass_bottom_rounded,
                                  color: isExpired
                                      ? kRed
                                      : (isWarning ? kOrange : kGreen),
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Days Remaining',
                                        style: TextStyle(
                                          color: kTextSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Text(
                                            '${widget.daysRemaining} days',
                                            style: TextStyle(
                                              color: isExpired
                                                  ? kRed
                                                  : (isWarning
                                                      ? kOrange
                                                      : kGreen),
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value:
                                                    (widget.daysRemaining / 365)
                                                        .clamp(0.0, 1.0),
                                                minHeight: 4,
                                                backgroundColor: kCardBorder,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                        Color>(
                                                  isExpired
                                                      ? kRed
                                                      : (isWarning
                                                          ? kOrange
                                                          : kGreen),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            // Warning banner — expiring soon
                            if (isWarning)
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: _AlertBanner(
                                  icon: Icons.info_outline_rounded,
                                  color: kOrange,
                                  message:
                                      'Your license expires in ${widget.daysRemaining} days',
                                ),
                              ),

                            // Error banner — expired
                            if (isExpired)
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: _AlertBanner(
                                  icon: Icons.warning_rounded,
                                  color: kRed,
                                  message:
                                      'Your license has expired. Please renew to continue using the app.',
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // ── POS ORDER CONFIGURATION SECTION ──
                      _buildSectionLabel('POS ORDER CONFIGURATION'),
                      const SizedBox(height: 10),
                      _Card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Info banner
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: kOrange.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: kOrange.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.info_outline_rounded,
                                    color: kOrange,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Required to place orders from this device.',
                                      style: TextStyle(
                                        color: kOrange.withValues(alpha: 0.9),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            const Text(
                              'Device Code',
                              style: TextStyle(
                                color: kTextSecondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Must match Device Code in Odoo → POS → Devices',
                              style: TextStyle(
                                color: kTextSecondary,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Device code input field
                            // Read-only when offline — user cannot change Device ID without a connection
                            _buildInput(
                              controller: widget.deviceCodeCtrl,
                              hint: 'e.g. DEV001',
                              icon: Icons.point_of_sale_rounded,
                              readOnly: !_sheetIsOnline,
                            ),
                            const SizedBox(height: 8),

                            // Show offline warning below the field when in read-only mode
                            if (!_sheetIsOnline)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: const [
                                    Icon(
                                      Icons.wifi_off_rounded,
                                      color: kOrange,
                                      size: 14,
                                    ),
                                    SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        // Inform user why the field is locked
                                        'Device ID is read-only in offline mode.',
                                        style: TextStyle(
                                          color: kOrange,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 12),

                            // Save button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: widget.isSavingPos
                                    ? null
                                    : widget.onSavePosConfig,
                                icon: widget.isSavingPos
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: kTextPrimary,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.save_outlined,
                                        color: kTextPrimary,
                                        size: 20,
                                      ),
                                label: Text(
                                  widget.isSavingPos
                                      ? 'Saving...'
                                      : 'Save POS Config',
                                  style: const TextStyle(
                                    color: kTextPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: kGreen,
                                  disabledBackgroundColor:
                                      kGreen.withValues(alpha: 0.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  elevation: 0,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Section label helper used inside the sheet
  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: kTextSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SHARED INPUT BUILDER (used in both main screen and sheet)
// ─────────────────────────────────────────────

Widget _buildInput({
  required TextEditingController controller,
  required String hint,
  required IconData icon,
  TextInputType? keyboardType,
  // When true, the field is read-only and cannot be edited by the user
  bool readOnly = false,
}) {
  return TextField(
    controller: controller,
    keyboardType: keyboardType,
    // Disable editing when readOnly is true (e.g. offline mode)
    readOnly: readOnly,
    style: TextStyle(
      // Dim the text color when read-only to visually indicate it's not editable
      color: readOnly ? kTextSecondary : kTextPrimary,
      fontSize: 14,
    ),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: kTextSecondary),
      prefixIcon: Icon(
        icon,
        color: kTextSecondary,
        size: 20,
      ),
      // Use a slightly different background when read-only so user notices the locked state
      filled: true,
      fillColor: readOnly ? kCardBorder.withValues(alpha: 0.5) : kInputBg,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 12,
      ),
      // Show a lock icon as suffix when field is read-only
      suffixIcon: readOnly
          ? const Icon(Icons.lock_outline_rounded,
              color: kTextSecondary, size: 18)
          : null,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kCardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        // Use a muted border color when read-only
        borderSide: BorderSide(color: readOnly ? kCardBorder : kCardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        // Read-only field should not show purple focus border
        borderSide: BorderSide(color: readOnly ? kCardBorder : kPurple),
      ),
    ),
  );
}

// ─────────────────────────────────────────────
// REUSABLE WIDGETS
// ─────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kCardBorder),
      ),
      child: child,
    );
  }
}

class _SectionBlock extends StatelessWidget {
  final String label;
  final Widget child;

  const _SectionBlock({
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kTextSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        _Card(child: child),
      ],
    );
  }
}

class _InfoRowDivider extends StatelessWidget {
  const _InfoRowDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      color: kCardBorder,
      height: 1,
      thickness: 1,
    );
  }
}

class _SyncBadge extends StatelessWidget {
  final int count;
  final String label;
  final Color color;

  const _SyncBadge({
    required this.count,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Text(
            '$count',
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;

  const _SettingsTile({
    required this.icon,
    required this.label,
    this.value,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue =
        value; // Copy to local variable to allow type promotion
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(
            icon,
            color: kTextSecondary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: kTextPrimary,
                fontSize: 14,
              ),
            ),
          ),
          if (displayValue != null)
            Text(
              displayValue,
              style: const TextStyle(
                color: kTextSecondary,
                fontSize: 13,
              ),
            ),
          const SizedBox(width: 6),
          const Icon(
            Icons.chevron_right_rounded,
            color: kTextSecondary,
            size: 18,
          ),
        ],
      ),
    );
  }
}

// Status badge widget (Online/Offline, Active/Expired) used inside the sheet
class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// License info field widget used inside the sheet
class _LicenseField extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final bool isObscured;
  final VoidCallback? onToggleObscure;

  const _LicenseField({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
    this.isObscured = false,
    this.onToggleObscure,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue = isObscured ? '●' * (value.length.clamp(8, 20)) : value;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                displayValue,
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: isObscured ? 10 : 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: isObscured ? 2.5 : 0,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (onToggleObscure != null)
          GestureDetector(
            onTap: onToggleObscure,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                isObscured
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: kTextSecondary,
                size: 20,
              ),
            ),
          ),
      ],
    );
  }
}

// Alert banner widget for warning/expired messages inside the sheet
class _AlertBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;

  const _AlertBanner({
    required this.icon,
    required this.color,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
