import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../data/repositories/customer_repository.dart';
import '../../../services/app_config.dart';
import '../../../services/api_client.dart';
import '../../../services/db_helper.dart';

/// Customer search, cache, and Odoo API orchestration.
class CustomerService {
  final CustomerRepository _repo = CustomerRepository();

  Future<List<Map<String, dynamic>>> searchLocal(String query) =>
      _repo.getCustomers(query: query);

  Future<List<Map<String, dynamic>>> searchCustomers(String query) async {
    final local = await searchLocal(query);

    try {
      final token = await AppConfig.getApiToken();

      if (token.isEmpty) {
        throw Exception('Offline mode');
      }

      final q = query.isEmpty ? '' : '&query=${Uri.encodeComponent(query)}';

      final response = await ApiClient.get(
        '/api/customers/search?all=1$q',
        timeout: const Duration(seconds: 8),
      );

      final data = jsonDecode(response.body);

      if (data['status'] == 'success' || data['code'] == 200) {
        final list = (data['data'] as List? ?? []).cast<Map<String, dynamic>>();
        await cacheCustomersFromServer(list);
        return list;
      }

      throw Exception('API failed');
    } catch (_) {
      return local;
    }
  }

  Future<void> cacheCustomersFromServer(List<dynamic> data) async {
    final db = await DatabaseHelper().database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final c in data) {
      batch.insert(
        'customers',
        {
          'id': c['id'],
          'name': c['name'],
          'phone': c['phone'],
          'email': c['email'],
          'synced': 1,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
  }

  Future<bool> checkServerOnline() async {
    final token = await AppConfig.getApiToken();
    if (token.isEmpty) return false;
    try {
      final healthCheck = await ApiClient.get(
        '/web/health',
        authenticated: false,
        timeout: const Duration(seconds: 5),
      );
      return healthCheck.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> buildCustomerBody({
    required String name,
    required String phone,
    required String email,
  }) async {
    return {
      'name': name.trim(),
      'phone': phone.trim(),
      'email': email.trim(),
    };
  }

  /// Create or update customer online then locally; falls back to offline repo.
  Future<int> saveCustomer({
    required Map<String, String> body,
    Map<String, dynamic>? existing,
  }) async {
    final custRepo = CustomerRepository();
    final db = await DatabaseHelper().database;
    final isEdit = existing != null;

    int savedId = 0;
    final isOnline = await checkServerOnline();
    final token = await AppConfig.getApiToken();

    if (isOnline && token.isNotEmpty) {
      try {
        if (isEdit) {
          final id = existing['id'] as int;
          final response = await ApiClient.put(
            '/api/customers/$id/update',
            headers: {'Content-Type': 'application/json'},
            body: body,
            timeout: const Duration(seconds: 10),
          );

          final data = jsonDecode(response.body);
          final isSuccess = data['status'] == 'success' ||
              data['message'] == 'Customer updated successfully.';

          if (isSuccess) {
            await db.update(
              'customers',
              {
                'name': body['name']!,
                'phone': body['phone']!,
                'email': body['email']!,
                'synced': 1,
                'is_dirty': 0,
                'sync_attempts': 0,
                'updated_at': DateTime.now().millisecondsSinceEpoch,
              },
              where: 'id = ?',
              whereArgs: [id],
            );
            savedId = id;
          }
        } else {
          final response = await ApiClient.post(
            '/api/customers/create',
            headers: {'Content-Type': 'application/json'},
            body: body,
            timeout: const Duration(seconds: 10),
          );

          final data = jsonDecode(response.body);
          final isSuccess = data['status'] == 'success' ||
              data['message'] == 'Customer created' ||
              data['message'] == 'Customer exists';

          if (isSuccess) {
            final responseData = data['data'] ?? {};
            final serverId = responseData['id'] as int? ?? 0;

            if (serverId > 0) {
              final now = DateTime.now().millisecondsSinceEpoch;
              await db.insert(
                'customers',
                {
                  'id': serverId,
                  'name': body['name']!,
                  'phone': body['phone']!,
                  'email': body['email']!,
                  'synced': 1,
                  'is_dirty': 0,
                  'sync_attempts': 0,
                  'created_at': now,
                  'updated_at': now,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              savedId = serverId;
            }
          }
        }
      } catch (_) {}
    }

    if (savedId == 0) {
      if (isEdit) {
        final customerId = existing['id'] as int;
        final success = await custRepo.updateCustomerOffline(
          customerId: customerId,
          name: body['name']!,
          phone: body['phone']!,
          email: body['email']!,
        );
        savedId = success ? customerId : 0;
      } else {
        savedId = await custRepo.createCustomerOffline(
          name: body['name']!,
          phone: body['phone']!,
          email: body['email']!,
        );
      }
    }

    return savedId;
  }
}
