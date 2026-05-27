import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test setup shared by service/widget tests.
///
/// It provides in-memory mocks for SharedPreferences and flutter_secure_storage
/// so most tests can run on your computer without Android/iOS device plugins.
class TestSecureStorage {
  static final Map<String, String> values = <String, String>{};

  static const MethodChannel _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  static void install() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    values.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
      final Map<dynamic, dynamic> args =
          (call.arguments as Map<dynamic, dynamic>?) ?? <dynamic, dynamic>{};
      final String key = (args['key'] ?? '').toString();

      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key] = (args['value'] ?? '').toString();
          return null;
        case 'delete':
          values.remove(key);
          return null;
        case 'deleteAll':
          values.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
        case 'containsKey':
          return values.containsKey(key);
        default:
          return null;
      }
    });
  }
}
