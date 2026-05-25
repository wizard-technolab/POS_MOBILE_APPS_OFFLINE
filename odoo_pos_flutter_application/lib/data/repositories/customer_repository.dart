import 'package:sqflite/sqflite.dart';
import '../../services/db_helper.dart';

class CustomerRepository {
  final dbHelper = DatabaseHelper();

  // ── INSERT / UPDATE CUSTOMERS FROM SERVER ──
  Future<void> insertOrUpdateCustomers(
      List<Map<String, dynamic>> customers) async {
    final db = await dbHelper.database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final c in customers) {
      batch.insert(
        'customers',
        {
          'id': c['id'],
          'name': c['name'] ?? '',
          'phone': c['phone'] ?? '',
          'email': c['email'] ?? '',
          'synced': 1,
          'is_dirty': 0,
          'sync_attempts': 0,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
  }

  // ── CREATE CUSTOMER OFFLINE ──
  // Returns negative ID for local-only customers that will sync later
  Future<int> createCustomerOffline({
    required String name,
    required String phone,
    required String email,
  }) async {
    final db = await dbHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Use negative ID for offline customers (won't conflict with server IDs)
    final localId = -(now ~/ 1000);

    try {
      await db.insert(
        'customers',
        {
          'id': localId,
          'name': name.trim(),
          'phone': phone.trim(),
          'email': email.trim(),
          'synced': 0,
          'is_dirty': 1,
          'sync_attempts': 0,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return localId;
    } catch (e) {
      return 0;
    }
  }

  // ── UPDATE CUSTOMER OFFLINE ──
  Future<bool> updateCustomerOffline({
    required int customerId,
    required String name,
    required String phone,
    required String email,
  }) async {
    final db = await dbHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      final result = await db.update(
        'customers',
        {
          'name': name.trim(),
          'phone': phone.trim(),
          'email': email.trim(),
          'is_dirty': 1,
          'synced': 0,
          'sync_attempts': 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [customerId],
      );
      return result > 0;
    } catch (e) {
      return false;
    }
  }

  // ── GET UNSYNCED CUSTOMERS (for upload to server) ──
  Future<List<Map<String, dynamic>>> getUnsyncedCustomers() async {
    final db = await dbHelper.database;
    return await db.query(
      'customers',
      where: 'synced = 0 OR is_dirty = 1',
      orderBy: 'updated_at ASC',
    );
  }

  // ── MARK CUSTOMER AS SYNCED ──
  Future<void> markCustomerAsSynced(int customerId) async {
    final db = await dbHelper.database;
    await db.update(
      'customers',
      {
        'synced': 1,
        'is_dirty': 0,
        'sync_attempts': 0,
      },
      where: 'id = ?',
      whereArgs: [customerId],
    );
  }

  // ── INCREMENT SYNC ATTEMPTS ──
  Future<void> incrementSyncAttempts(int customerId) async {
    final db = await dbHelper.database;
    await db.rawUpdate(
      'UPDATE customers SET sync_attempts = sync_attempts + 1, last_sync_attempt = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, customerId],
    );
  }

  // ── GET ALL CUSTOMERS (filtered to server customers) ──
  Future<List<Map<String, dynamic>>> getCustomers({String query = ''}) async {
    final db = await dbHelper.database;

    if (query.isEmpty) {
      return await db.query(
        'customers',
        orderBy: 'name ASC',
        limit: 100,
      );
    }

    final q = '%${query.toLowerCase()}%';
    return await db.rawQuery('''
      SELECT * FROM customers
      WHERE (LOWER(name) LIKE ? OR phone LIKE ?)
      ORDER BY name ASC
      LIMIT 100
    ''', [q, q]);
  }

  // ── GET CUSTOMER BY ID ──
  Future<Map<String, dynamic>?> getCustomerById(int customerId) async {
    final db = await dbHelper.database;
    final result = await db.query(
      'customers',
      where: 'id = ?',
      whereArgs: [customerId],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  Future<void> clearCustomers() async {
    final db = await dbHelper.database;
    await db.delete('customers', where: 'id > 0');
  }
}
