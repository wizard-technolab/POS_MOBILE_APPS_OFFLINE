import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'app_config.dart';
import 'delta_sync_manager.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// Exposes the current offline status to any UI component.
  final ValueNotifier<bool> isOfflineNotifier = ValueNotifier<bool>(false);

  bool _initialized = false;

  /// Starts the connectivity listener. Ideally called at app startup (e.g., in MainShell).
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Check initial connectivity status
    final initial = await Connectivity().checkConnectivity();
    isOfflineNotifier.value =
        initial.isEmpty || initial.first == ConnectivityResult.none;

    _subscription =
        Connectivity().onConnectivityChanged.listen((results) async {
      final isOffline =
          results.isEmpty || results.first == ConnectivityResult.none;
      final wasOffline = isOfflineNotifier.value;

      // Update the global notifier so UI components can react (e.g. banners)
      isOfflineNotifier.value = isOffline;

      // When connection restores from offline to online, trigger background sync
      if (wasOffline && !isOffline) {
        debugPrint(
            '🌐 ConnectivityService: Connection restored -> triggering background delta sync');
        final sessionId = await AppConfig.getPosSessionId();
        if (sessionId > 0) {
          // Run sync in the background
          await DeltaSyncManager().deltaSyncOrders(sessionId: sessionId);
          // Also sync customers (upload offline changes)
          await DeltaSyncManager().deltaSyncCustomers();
          // And products
          await DeltaSyncManager().deltaSyncProducts(sessionId: sessionId);
        }
      }
    });
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _initialized = false;
  }
}
