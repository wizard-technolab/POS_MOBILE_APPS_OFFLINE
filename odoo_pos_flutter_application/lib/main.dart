// lib/main.dart

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:OdoCart/screens/session_screen.dart';
import 'package:OdoCart/screens/subscription_screen.dart';
import 'screens/product_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/cart_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/login_screen.dart';
import 'services/cart_service.dart';
import 'services/db_helper.dart';
import 'services/sync_manager.dart';
import 'services/app_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dbHelper = DatabaseHelper();
  await dbHelper.fixOldProductData();
  // ── Initialize cart from persistence ────────────
  await CartService.instance.initCart();
  await DatabaseHelper().ensureSeedTables();
  // ── Sync all data (products, orders) ────────────
  await SyncManager().syncAll();

  // Load currency symbol from SharedPreferences into the in-memory cache.
  // This must run before runApp() so AppConfig.currencySymbol is correct
  // the first time any screen renders (e.g. cart_screen.dart uses it
  // synchronously inside string interpolations).
  await AppConfig.loadCurrencySymbol();

  // ── Clear cart on session change ─────────────────
  sessionChangeNotifier.addListener(() async {
    await CartService.instance.initCart();
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'POS App',
      theme: ThemeData.dark(),
      home: const AuthGate(), // 🔥 New gate for auth/session checking
    );
  }
}

// ─────────────────────────────────────────────
// AUTH GATE - Login → Subscription → Session → Main
// ─────────────────────────────────────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late Future<Widget> _routeFuture;

  @override
  void initState() {
    super.initState();
    _routeFuture = _determineRoute();
  }

  Future<Widget> _determineRoute() async {
    // ─── STEP 1: Check if user is logged in ───
    final isLoggedIn = await AppConfig.isLoggedIn();

    if (!isLoggedIn) {
      debugPrint('❌ Not logged in → LoginScreen');
      return const LoginScreen();
    }

    debugPrint('✅ Logged in, checking subscription...');

    // ─── STEP 2: Check subscription (OFFLINE-CAPABLE) ───
    // This checks locally saved exp_date vs current device date
    // final isFirstLaunch = await AppConfig.isFirstLaunchAfterInstall();
    // final hasValidSubscription = await AppConfig.isSubscriptionValid();

    // if (isFirstLaunch || !hasValidSubscription) {
    //   debugPrint(
    //       '⚠️ First launch or expired subscription → SubscriptionScreen');
    //   return const SubscriptionScreen();
    // }

    // debugPrint('✅ Subscription valid, checking session...');

    // ─── STEP 3: Check if POS session is selected ───
    final sessionId = await AppConfig.getPosSessionId();

    if (sessionId <= 0) {
      debugPrint('⚠️ No session selected → PosSessionScreen');
      return const PosSessionScreen();
    }

    debugPrint('✅ Session selected (ID: $sessionId) → MainShell');
    return const MainShell();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _routeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0F1C),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
            ),
          );
        }

        if (snapshot.hasError) {
          debugPrint('❌ AuthGate error: ${snapshot.error}');
          return const LoginScreen();
        }

        return snapshot.data ?? const LoginScreen();
      },
    );
  }
}

// ─────────────────────────────────────────────
// COLORS
// ─────────────────────────────────────────────
const kNavBg = Color(0xFF11131F);
const kCardBorder = Color(0xFF1E2235);
const kPurpleLight = Color(0xFF8B83FF);
const kPurple = Color(0xFF6C63FF);
const kTextSecondary = Color(0xFF8B90A7);

// When session changes in Settings, this notifier tells all screens to reload
final sessionChangeNotifier = ValueNotifier<int>(0);

// Incremented every time an order is placed (online or offline).
// OrdersScreen listens to this and reloads automatically — no manual refresh needed.
final orderPlacedNotifier = ValueNotifier<int>(0);

// ─────────────────────────────────────────────
// MAIN SHELL
// ─────────────────────────────────────────────
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // Tracks the order in which tabs were visited, like a back-stack.
  // When the user presses back, we pop to the previous tab instead of closing the app.
  // Always starts with Products tab (index 0) as the root — it can never be popped.
  final List<int> _tabHistory = [0];

  late final List<Widget> _screens;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _periodicSyncTimer; // New: Timer for periodic online sync

  @override
  void initState() {
    super.initState();

    _screens = [
      // Pass _navigateToTab so ProductScreen cart button adds to history stack
      ProductScreen(onCartTap: () => _navigateToTab(1)),
      const CartScreen(),
      const OrdersScreen(),
      const SettingsScreen(),
    ];

    _startConnectivityListener();
    AppConfig.subscriptionValidNotifier.addListener(_onSubscriptionChanged);

    // Listen for "Add back to cart" signal from OrderDetailSheet.
    // When a pending order is restored, CartService fires this notifier and
    // MainShell switches to the Cart tab (index 1) automatically.
    CartService.instance.navigateToCartNotifier.addListener(_onNavigateToCart);
  }

  // ─────────────────────────────────────────────
  // SUBSCRIPTION MONITORING
  // ─────────────────────────────────────────────

  // Switches to [index] tab and pushes it onto the history stack.
  // If the same tab is tapped again, we do not add a duplicate entry.
  void _navigateToTab(int index) {
    if (_currentIndex == index) return;
    setState(() {
      _tabHistory.add(index);
      _currentIndex = index;
    });
  }

  void _onSubscriptionChanged() {
    if (!AppConfig.subscriptionValidNotifier.value && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
        (route) => false,
      );
    }
  }

  // ─────────────────────────────────────────────
  // AUTO INTERNET RESTORE DETECTION
  // ─────────────────────────────────────────────
  bool _syncRunning = false;
  DateTime? _lastSyncTime;

  void _startConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (result) async {
        final hasInternet =
            result.isNotEmpty && result.first != ConnectivityResult.none;

        if (!hasInternet) {
          debugPrint('📴 Internet disconnected');
          return;
        }

        // Prevent duplicate syncs
        if (_syncRunning) {
          debugPrint('⏳ Sync already running');
          return;
        }

        // Prevent sync spam
        final now = DateTime.now();

        if (_lastSyncTime != null &&
            now.difference(_lastSyncTime!) < const Duration(minutes: 2)) {
          debugPrint('⏭️ Recent sync exists → skipping');
          return;
        }

        try {
          _syncRunning = true;

          debugPrint('🌐 Internet restored → starting auto sync');

          await SyncManager().syncAll();

          _lastSyncTime = DateTime.now();

          await AppConfig.loadCurrencySymbol();

          _startPeriodicSync();
        } finally {
          _syncRunning = false;
        }
      },
    );
  }

  void _startPeriodicSync() {
    // Cancel any existing timer to avoid duplicates
    _periodicSyncTimer?.cancel();

    // FIX: Increase interval to 5 minutes to prevent excessive data usage
    _periodicSyncTimer =
        Timer.periodic(const Duration(minutes: 5), (timer) async {
      debugPrint('🔄 Periodic online sync triggered');
      // Only sync if actually online
      final isOnline = await SyncManager().isConnected();
      if (isOnline) {
        await SyncManager().syncAll();
      } else {
        debugPrint('⚠️ Periodic sync skipped: device is offline');
      }
    });
  }

  // Switches to Cart tab when a pending order is restored via "Add back to cart".
  void _onNavigateToCart() {
    _navigateToTab(1);
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _periodicSyncTimer?.cancel(); // Cancel periodic timer on dispose
    AppConfig.subscriptionValidNotifier.removeListener(_onSubscriptionChanged);
    CartService.instance.navigateToCartNotifier
        .removeListener(_onNavigateToCart);
    super.dispose();
  }

  final List<(IconData, String)> _navItems = const [
    (Icons.grid_view_rounded, 'Products'),
    (Icons.shopping_cart_outlined, 'Cart'),
    (Icons.receipt_outlined, 'Orders'),
    (Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop is true only when there is no tab history left to go back through.
      // As long as the user has visited more than one tab, back button pops tabs, not the app.
      canPop: _tabHistory.length <= 1,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop)
          return; // system already handled it (history empty → app exit)
        // Pop the current tab from history and go back to the previous one
        setState(() {
          _tabHistory.removeLast();
          _currentIndex = _tabHistory.last;
        });
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0F1C),
        body: IndexedStack(index: _currentIndex, children: _screens),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: kNavBg,
            border: Border(top: BorderSide(color: kCardBorder, width: 1)),
          ),
          padding: const EdgeInsets.only(top: 12, bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_navItems.length, (i) {
              final selected = _currentIndex == i;
              return GestureDetector(
                onTap: () => _navigateToTab(i),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          _navItems[i].$1,
                          color: selected ? kPurpleLight : kTextSecondary,
                          size: 22,
                        ),
                        if (i == 1)
                          ValueListenableBuilder(
                            valueListenable: CartService.instance.cartNotifier,
                            builder: (_, __, ___) {
                              return ValueListenableBuilder(
                                valueListenable:
                                    CartService.instance.comboCartNotifier,
                                builder: (_, __, ___) {
                                  final count =
                                      CartService.instance.totalItemCount;
                                  if (count == 0) {
                                    return const SizedBox.shrink();
                                  }
                                  return Positioned(
                                    right: -8,
                                    top: -6,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                        color: kPurple,
                                        shape: BoxShape.circle,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 16,
                                        minHeight: 16,
                                      ),
                                      child: Text(
                                        count > 99 ? '99+' : '$count',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _navItems[i].$2,
                      style: TextStyle(
                        color: selected ? kPurpleLight : kTextSecondary,
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ), // closes Scaffold (child of PopScope)
    ); // closes PopScope
  }
}
