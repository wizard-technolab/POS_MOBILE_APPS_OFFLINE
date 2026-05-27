import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/repositories/order_repository.dart';
import '../../../services/app_config.dart';
import '../../../services/connectivity_service.dart';
import '../../../services/odoo_service.dart';
import '../domain/order.dart';
import 'order_detail_sheet.dart';
import 'widgets/order_card.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<OrderModel> _allOrdersForCurrentFilter =
      []; // Stores orders filtered by status
  List<OrderModel> _displayedOrders =
      []; // Stores orders filtered by search query
  // Use a ValueNotifier to isolate list rebuilds from the rest of the UI
  final ValueNotifier<Map<String, List<OrderModel>>> _groupedOrdersNotifier =
      ValueNotifier({});
  bool _loading = true;
  bool _isOffline = false;
  String _error = '';
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _filter = 'all';

  final OrderRepository _orderRepo = OrderRepository();

  @override
  void initState() {
    super.initState();
    _loadOrders();
    // Reload orders when session changes in Settings
    _searchController.addListener(_onSearchChanged);
    sessionChangeNotifier.addListener(_onSessionChanged);
    // Reload orders automatically after every successful payment (online or offline)
    orderPlacedNotifier.addListener(_onOrderPlaced);

    // Use the global connectivity service
    ConnectivityService().initialize();
    ConnectivityService().isOfflineNotifier.addListener(_onConnectivityChanged);
    _isOffline = ConnectivityService().isOfflineNotifier.value;
  }

  void _onSessionChanged() {
    debugPrint('🔄 Session changed → reloading orders');
    if (mounted) _loadOrders();
  }

  // Called whenever cart_screen places an order successfully
  void _onOrderPlaced() {
    debugPrint('✅ New order placed → reloading orders list automatically');
    if (mounted) _loadOrders();
  }

  void _onConnectivityChanged() {
    if (mounted) {
      setState(
          () => _isOffline = ConnectivityService().isOfflineNotifier.value);
    }
  }

  void _onSearchChanged() {
    // Cancel previous timer if user is still typing
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();

    // Immediate clear if empty for better responsiveness
    if (_searchController.text.isEmpty) {
      _applySearchFilter();
      return;
    }

    // Wait 300ms before filtering to prevent "jumping" UI
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _applySearchFilter();
    });
  }

  Timer? _searchDebounce;

  @override
  void dispose() {
    ConnectivityService()
        .isOfflineNotifier
        .removeListener(_onConnectivityChanged);
    sessionChangeNotifier.removeListener(_onSessionChanged);
    orderPlacedNotifier
        .removeListener(_onOrderPlaced); // Clean up to avoid memory leaks
    _searchDebounce?.cancel();
    super.dispose();
    _groupedOrdersNotifier.dispose();
    _searchFocusNode.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
  }

  Future<void> _loadOrders() async {
    // Check real connectivity before loading.
    // Do NOT hardcode _isOffline = false here because the connectivity listener
    // may have already set the correct offline state — resetting it blindly
    // breaks the banner on the orders screen (unlike product screen which does not reset it).
    final connectivityResult = await Connectivity().checkConnectivity();
    final currentlyOffline = connectivityResult.isEmpty ||
        connectivityResult.first == ConnectivityResult.none;

    setState(() {
      _loading = true;
      _error = '';
      _isOffline = currentlyOffline;
    });

    try {
      final currentSessionId = await AppConfig.getPosSessionId();

      // Step 1: Fetch server orders first
      final rawOrders = await OdooService.fetchOrders(
        filter: _filter,
        limit: 100,
        sessionId: currentSessionId,
      );

      await _orderRepo.insertOrUpdateOrders(
        rawOrders,
        currentSessionId: currentSessionId,
      );

      // Step 1b: Fetch server pending (draft) orders and save to local DB.
      //
      // WHY THIS IS NEEDED:
      //   /api/orders returns paid/done orders by default.
      //   Draft orders placed from Odoo backend or another device are NOT
      //   included in that response. So when the app goes offline, those
      //   pending orders are missing from local DB and don't show on screen.
      //
      //   Fix: separately call /api/orders/pending and insert each server
      //   draft order into local SQLite so offline mode can display them.
      //   If the order is already in local DB (matched by odoo_order_id),
      //   insertOrUpdateOrders handles deduplication — no duplicates.
      try {
        final rawPendingOrders =
            await OdooService.fetchPendingOrders(sessionId: currentSessionId);
        if (rawPendingOrders.isNotEmpty) {
          // Map server pending response to the same shape insertOrUpdateOrders expects.
          // /api/orders/pending returns 'lines' as a list of line dicts — same structure.
          final mappedPending = rawPendingOrders.map((order) {
            return {
              ...order,
              // Ensure state is set so _mapServerStatus maps it correctly
              'state': order['state'] ?? 'draft',
              // external_pos_id may not be in pending response — default to empty
              'external_pos_id':
                  order['external_pos_id'] ?? order['external_id'] ?? '',
            };
          }).toList();

          await _orderRepo.insertOrUpdateOrders(
            mappedPending,
            currentSessionId: currentSessionId,
          );
          debugPrint(
              '✅ Synced ${rawPendingOrders.length} server pending orders to local DB');
        }
      } catch (e) {
        // Non-fatal: pending order sync failure should not break the main order list
        debugPrint('⚠️ fetchPendingOrders sync error (non-fatal): $e');
      }

      // Build local pending list:
      // 1. Local-only drafts (odoo_order_id=0) — not yet on server
      // 2. Paid-offline orders waiting to sync (status='pending')
      // Server-synced drafts (odoo_order_id>0) are shown via serverOrders loop below.
      List<OrderModel> localPending = [];
      if (_filter == 'all' || _filter == 'pending') {
        final currentSessionId = await AppConfig.getPosSessionId();
        // Local-only drafts: odoo_order_id=0, not yet synced to server
        final draftRows =
            await _orderRepo.getLocalPendingOrders(sessionId: currentSessionId);
        // Paid offline orders waiting to sync
        final paidOfflineRows = await _orderRepo.getOrdersWithStatus('pending',
            sessionId: currentSessionId);
        localPending = [
          ...draftRows.map((r) => OrderModel.fromLocalDb(r)),
          ...paidOfflineRows.map((r) => OrderModel.fromLocalDb(r)),
        ];
      }

      // Build a set of external_ids from local draft orders so we can deduplicate.
      // When a local draft is synced to Odoo (syncLocalDraftToOdoo), Odoo creates
      // a draft order with state='draft'. Without deduplication, both the local
      // SQLite draft AND the Odoo server draft appear in the pending list — same
      // order shown twice. We remove server-side draft orders whose external_pos_id
      // matches a local draft external_id so only the local version is shown.
      final localDraftExternalIds = <String>{};
      if (_filter == 'all' || _filter == 'pending') {
        final currentSessionId = await AppConfig.getPosSessionId();
        final draftRows =
            await _orderRepo.getLocalPendingOrders(sessionId: currentSessionId);
        for (final row in draftRows) {
          final extId = row['external_id'] as String?;
          if (extId != null && extId.isNotEmpty) {
            localDraftExternalIds.add(extId);
          }
        }

        // 2. Recently paid orders (done) — suppress their server draft twin
        //    so the just-paid order does not reappear as Pending while Odoo
        //    is still processing the payment (eventual consistency gap).
        final doneRows = await _orderRepo.getOrdersWithStatus('done',
            sessionId: currentSessionId);
        for (final row in doneRows) {
          final extId = row['external_id'] as String?;
          if (extId != null && extId.isNotEmpty) {
            localDraftExternalIds.add(extId);
          }
        }

        // 3. Paid-offline orders waiting to sync — same reason as above
        final pendingRows = await _orderRepo.getOrdersWithStatus('pending',
            sessionId: currentSessionId);
        for (final row in pendingRows) {
          final extId = row['external_id'] as String?;
          if (extId != null && extId.isNotEmpty) {
            localDraftExternalIds.add(extId);
          }
        }
      }

      // Filter server orders: remove draft orders that already exist as local drafts.
      // Non-draft server orders (paid, done, cancelled) are always included.
      //
      // PAYMENT METHOD FIX:
      // Odoo's GET /api/orders sometimes returns payment_methods: [] for recently
      // placed orders because the pos.payment records take a moment to propagate.
      // fromJson falls back to 'Cash' when the list is empty — even if the cashier
      // selected 'Bank'. To avoid this, we read the payment_method that was already
      // saved to local SQLite (by insertSyncedOrder at order-placement time) and
      // override the server value whenever the server list is empty.
      final filteredRaw = rawOrders.where((j) {
        final state = j['state'] as String? ?? '';
        final serverExtId = j['external_pos_id'] as String? ?? '';
        if (state == 'draft' && localDraftExternalIds.contains(serverExtId)) {
          return false; // duplicate — local draft already shown
        }
        return true;
      }).toList();

      // Build server order models, preferring local DB payment_method when server
      // returns an empty payment_methods list for a recently paid order.
      // CRITICAL: Use local SQLite ID, not server ID, for proper order_lines association
      final serverOrders = <OrderModel>[];
      for (final j in filteredRaw) {
        final serverId = j['id'] as int?;
        if (serverId == null) continue;

        // 🔒 SESSION ISOLATION: Verify order belongs to current session BEFORE lookup
        final serverSessionId = _extractSessionId(j);
        if (serverSessionId != 0 && serverSessionId != currentSessionId) {
          debugPrint(
              '⚠️ Skipping order $serverId - server says session $serverSessionId but current is $currentSessionId');
          continue;
        }

        // Look up the local SQLite ID and cached data for this server order
        final localRow = await _orderRepo.getOrderByOdooId(serverId,
            sessionId: currentSessionId);

        if (localRow == null) {
          debugPrint(
              '⚠️ Server order $serverId not found in local DB for session $currentSessionId, skipping');
          continue;
        }

        // 🔒 DOUBLE-CHECK session isolation at local level
        final localSessionId = (localRow['session_id'] as int?) ?? 0;
        if (localSessionId != currentSessionId && localSessionId != 0) {
          debugPrint(
              '🚨 CRITICAL: Order $serverId in WRONG session - local says $localSessionId but current is $currentSessionId. Skipping to prevent data corruption.');
          continue;
        }

        final localId = localRow['id'] as int;

        // Build model using local SQLite ID for order_lines association
        OrderModel model = OrderModel(
          id: localId, // ✅ Use LOCAL SQLite ID, not server ID
          odooOrderId: serverId,
          name: j['name'] as String? ?? 'ORDER-${j['id']}',
          state: j['state'] as String? ?? 'draft',
          dateOrder: j['date_order'] as String? ?? '',
          amountTotal: (j['amount_total'] as num?)?.toDouble() ?? 0.0,
          customerName: _getEffectiveCustomerName(j, localRow),
          customerNote: j['customer_note'] as String? ?? '',
          lineCount: (localRow['line_count'] as int?) ?? 0,
          paymentMethod: _getPaymentMethodForOrder(j, localRow),
          companyName: localRow['company_name'] as String? ?? '',
          isLocal: false,
        );

        serverOrders.add(model);
      }

      // Merge all orders then sort by date descending so newest (today's) orders
      // always appear at the top — regardless of whether they are local or server,
      // before applying search filter.
      final merged = [...localPending, ...serverOrders];
      merged.sort((a, b) {
        final dtA = DateTime.tryParse(a.dateOrder) ?? DateTime(2000);
        final dtB = DateTime.tryParse(b.dateOrder) ?? DateTime(2000);
        return dtB.compareTo(dtA); // descending: newest first
      });
      setState(() {
        _allOrdersForCurrentFilter = merged;
        _loading = false;
        _isOffline = false;
        _applySearchFilter(); // Ensure display list and grouping are updated
      });
    } catch (e) {
      await _loadLocalOrders();
    }
  }

// ─────────────────────────────────────────────────────
// UPDATED _loadLocalOrders()
// orders_screen.dart
// ─────────────────────────────────────────────────────

  Future<void> _loadLocalOrders() async {
    try {
      List<Map<String, dynamic>> localOrders = [];

      // Fetch current session ID once — used for all queries so each
      // status filter only returns orders belonging to THIS session.
      final currentSessionId = await AppConfig.getPosSessionId();

      if (_filter == 'all' || _filter == 'synced') {
        localOrders.addAll(await _orderRepo.getOrdersWithStatus('done',
            sessionId: currentSessionId));
        localOrders.addAll(await _orderRepo.getOrdersWithStatus('paid',
            sessionId: currentSessionId));
      }

      if (_filter == 'all' || _filter == 'pending') {
        // Local-only drafts (odoo_order_id=0): cart saved locally, not yet on server
        localOrders.addAll(await _orderRepo.getLocalPendingOrders(
            sessionId: currentSessionId));
        // Server-synced drafts (odoo_order_id>0): pending orders from Odoo or
        // other devices — cached in local DB by fetchPendingOrders() when online.
        // Without this, going offline hides pending orders placed from Odoo backend.
        localOrders.addAll(await _orderRepo.getServerSyncedDraftOrders(
            sessionId: currentSessionId));
        // Paid offline orders waiting to sync to Odoo
        localOrders.addAll(await _orderRepo.getOrdersWithStatus('pending',
            sessionId: currentSessionId));
      }

      if (_filter == 'all' || _filter == 'cancelled') {
        localOrders.addAll(await _orderRepo.getOrdersWithStatus('cancel',
            sessionId: currentSessionId));
      }

      final models =
          localOrders.map((row) => OrderModel.fromLocalDb(row)).toList();

      // Sort all local orders by date descending so newest (today's) orders
      // always appear at the top — same behaviour as the online merge.
      models.sort((a, b) {
        final dtA = DateTime.tryParse(a.dateOrder) ?? DateTime(2000);
        final dtB = DateTime.tryParse(b.dateOrder) ?? DateTime(2000);
        return dtB.compareTo(dtA); // descending: newest first
      });

      setState(() {
        _allOrdersForCurrentFilter = models;
        _loading = false;
        _isOffline = true;
        // Keep _isOffline as-is — do not force offline banner when called
        // after order placement (we will do a server refresh in 2 seconds)
        _error = '';
        _applySearchFilter(); // Apply search filter after loading
      });
    } catch (e) {
      setState(() {
        _error = 'No orders available. Check your connection.';
        _loading = false;
        _isOffline = true;
      });
    }
  }

  // Applies the current search query to the _allOrdersForCurrentFilter list
  // and updates _displayedOrders.
  void _applySearchFilter() {
    final query = _searchController.text.trim().toLowerCase();

    if (query.isEmpty) {
      _displayedOrders = _allOrdersForCurrentFilter;
    } else {
      _displayedOrders = _allOrdersForCurrentFilter.where((order) {
        return order.name.toLowerCase().contains(query) ||
            order.customerName.toLowerCase().contains(query) ||
            order.paymentMethod.toLowerCase().contains(query);
      }).toList();
    }

    // Pre-calculate grouping once here instead of inside build()
    final Map<String, List<OrderModel>> newGroups = {};
    for (final o in _displayedOrders) {
      newGroups.putIfAbsent(o.dateGroup, () => []).add(o);
    }

    // Notify the builder to update only the list part of the screen
    _groupedOrdersNotifier.value = newGroups;
  }

  Future<void> _refresh() => _loadOrders();

  int get _todayCount {
    final now = DateTime.now();
    return _allOrdersForCurrentFilter.where((o) {
      try {
        final dt = DateTime.parse(o.dateOrder).toLocal();
        return dt.year == now.year &&
            dt.month == now.month &&
            dt.day == now.day;
      } catch (_) {
        return false;
      }
    }).length;
  }

  int get _syncedCount =>
      _allOrdersForCurrentFilter.where((o) => o.isSynced).length;
  int get _pendingCount =>
      _allOrdersForCurrentFilter.where((o) => o.state == 'draft').length;

  void _openOrderDetail(OrderModel order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      useSafeArea: true,
      builder: (ctx) => OrderDetailSheet(order: order),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset:
          false, // Prevents keyboard from pushing up the entire layout
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            _buildStatsRow(),
            _buildFilterChips(),
            if (_isOffline) _buildOfflineBanner(),
            _buildSearchBar(), // Add search bar here
            const SizedBox(height: 4),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // ── Offline Banner ─────────────────────────────
  Widget _buildOfflineBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.orangeAlt.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.orangeAlt.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded,
                color: AppColors.orangeAlt, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: const Text(
                'Offline - Showing local orders',
                style: TextStyle(color: AppColors.orangeAlt, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title + Session name (stacked vertically) ──
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Order History',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              // ── POS Session name (same style as product screen) ──
              FutureBuilder<String>(
                future: AppConfig.getPosSessionName(),
                builder: (_, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SizedBox.shrink();
                  }

                  if (snap.data?.isNotEmpty ?? false) {
                    // Session active — green icon + name
                    return Row(
                      children: [
                        const Icon(
                          Icons.point_of_sale_rounded,
                          color: AppColors.green,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          snap.data!,
                          style: const TextStyle(
                            color: AppColors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    );
                  }

                  // No session — orange warning
                  return const Text(
                    'No POS session selected',
                    style: TextStyle(
                      color: AppColors.orangeAlt,
                      fontSize: 11,
                    ),
                  );
                },
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }

  // ── Search Bar ────────────────────────────────
  Widget _buildSearchBar() {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          // Automatically dismisses keyboard when tapping outside the search input
          onTapOutside: (_) => _searchFocusNode.unfocus(),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search orders by name or customer...',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            prefixIcon: const Icon(Icons.search_rounded,
                color: AppColors.textSecondary, size: 20),
            // ValueListenableBuilder isolates rebuilds to just the suffix icon,
            // preventing the "every character bounce" on the whole screen.
            suffixIcon: ValueListenableBuilder(
              valueListenable: _searchController,
              builder: (context, value, child) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: const Icon(Icons.clear_rounded,
                      color: AppColors.textSecondary, size: 18),
                  onPressed: () => _searchController.clear(),
                );
              },
            ),
            filled: true,
            fillColor: AppColors.inputBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.purple)),
          ),
        ));
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _statCard('Today', '$_todayCount', AppColors.purple),
          const SizedBox(width: 10),
          _statCard('Synced', '$_syncedCount', AppColors.green),
          const SizedBox(width: 10),
          _statCard('Pending', '$_pendingCount', AppColors.orangeAlt),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    const filters = [
      {'key': 'all', 'label': 'All'},
      {'key': 'synced', 'label': 'Synced'},
      {'key': 'pending', 'label': 'Pending'},
      {'key': 'cancelled', 'label': 'Cancelled'},
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: filters.map((f) {
            final selected = _filter == f['key'];
            return GestureDetector(
              onTap: () {
                setState(() => _filter = f['key']!);
                _loadOrders();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? AppColors.purple : AppColors.inputBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected ? AppColors.purple : AppColors.cardBorder,
                  ),
                ),
                child: Text(
                  f['label']!,
                  style: TextStyle(
                    color: selected ? Colors.white : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.purple));
    }

    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.red, size: 48),
              const SizedBox(height: 12),
              Text(
                _error,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _refresh,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.purple,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.purple,
      backgroundColor: AppColors.card,
      onRefresh: _refresh,
      child: ValueListenableBuilder<Map<String, List<OrderModel>>>(
        valueListenable: _groupedOrdersNotifier,
        builder: (context, groupedOrders, _) {
          if (groupedOrders.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_outlined,
                      color: AppColors.textSecondary.withValues(alpha: 0.4),
                      size: 64),
                  const SizedBox(height: 16),
                  const Text('No orders found',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 16)),
                ],
              ),
            );
          }

          return ListView(
            // Use manual padding at the bottom for the keyboard since resizeToAvoidBottomInset is false
            padding: EdgeInsets.fromLTRB(
                16, 8, 16, MediaQuery.of(context).viewInsets.bottom + 32),
            physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics()),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: groupedOrders.entries.map((entry) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  ...entry.value.map(
                    (o) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: GestureDetector(
                        onTap: () => _openOrderDetail(o),
                        child: OrderCard(order: o),
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
          );
        },
      ),
    );
  }

  /// Decides which customer name to show, prioritizing a real name from local DB
  /// over the server's "Walk-in" fallback.
  String _getEffectiveCustomerName(
      Map<String, dynamic> serverJson, Map<String, dynamic> localRow) {
    // 1. If server provided a name that isn't "Walk-in", use it.
    final serverName = serverJson['customer_name'] as String?;
    if (serverName != null &&
        serverName.isNotEmpty &&
        serverName != 'Walk-in') {
      return serverName;
    }

    // 2. Otherwise, check if local SQLite has a real name (e.g. from cart placement).
    final localName = localRow['customer_name'] as String?;
    if (localName != null && localName.isNotEmpty && localName != 'Walk-in') {
      return localName;
    }

    // 3. Final fallback: use server name if any, else try resolving partner_id list
    return serverName ?? _extractCustomerName(serverJson);
  }

  /// Extract customer name from Odoo server order data
  String _extractCustomerName(Map<String, dynamic> order) {
    // Priority 1: Check if server already provided the string
    final directName = order['customer_name'] as String?;
    if (directName != null && directName.isNotEmpty) {
      return directName;
    }

    final partner = order['partner_id'];
    if (partner is List && partner.length > 1) {
      return partner[1].toString();
    }
    return 'Walk-in';
  }

  /// Extract session ID from server order response with safe type handling
  int _extractSessionId(Map<String, dynamic> order) {
    final rawSid = order['session_id'];

    // Handle Odoo's common format: session_id as [id, name] tuple
    if (rawSid is List && rawSid.isNotEmpty) {
      return int.tryParse(rawSid[0].toString()) ?? 0;
    }

    // Handle direct integer
    if (rawSid is int) {
      return rawSid;
    }

    // Try parsing as string
    if (rawSid is String) {
      return int.tryParse(rawSid) ?? 0;
    }

    return 0; // Unknown or missing
  }

  /// Get payment method for server order, preferring local DB value when server
  /// hasn't propagated payment records yet (Odoo eventual consistency issue)
  String _getPaymentMethodForOrder(
    Map<String, dynamic> serverOrder,
    Map<String, dynamic> localRow,
  ) {
    // Priority 1: Use server payment methods if available (Source of truth for synced orders)
    final serverMethods = serverOrder['payment_methods'];
    if (serverMethods is List && serverMethods.isNotEmpty) {
      return (serverMethods).join(' · ');
    }

    // Priority 2: Check local DB (relevant for offline orders not yet synced)
    final localMethod = localRow['payment_method'] as String?;
    if (localMethod != null &&
        localMethod.isNotEmpty &&
        localMethod != 'Cash') {
      return localMethod;
    }

    return 'Cash';
  }
}
