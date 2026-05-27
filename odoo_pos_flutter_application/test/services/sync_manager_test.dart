import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/services/sync_manager.dart';

void main() {
  test('starts with safe default sync state', () {
    final manager = SyncManager();

    expect(manager.isSyncing, isFalse);
    expect(manager.isOnline, isFalse);
    expect(manager.syncedCount, 0);
    expect(manager.failedCount, 0);
    expect(manager.pendingCount, 0);
    expect(manager.lastError, isEmpty);
    expect(manager.lastSyncTime, isNull);
  });

  test('background sync timer can be started and stopped without throwing', () {
    final manager = SyncManager();

    expect(
      () {
        manager.startBackgroundSync(interval: const Duration(minutes: 30));
        manager.stopBackgroundSync();
      },
      returnsNormally,
    );
  });
}
