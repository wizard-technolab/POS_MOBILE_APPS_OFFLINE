import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Central wrapper for secrets and sensitive preferences.
///
/// Android stores values with Android Keystore-backed encryption. iOS stores
/// values in Keychain and keeps them on the same device.
///
/// This clean version intentionally does not migrate old SharedPreferences
/// values because the app is not deployed yet and the local DB can be reset.
class SecureStorageService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      migrateWithBackup: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static Future<String?> read(String key) {
    return _storage.read(key: key);
  }

  static Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      await delete(key);
      return;
    }
    await _storage.write(key: key, value: value);
  }

  static Future<void> delete(String key) {
    return _storage.delete(key: key);
  }

  static Future<void> deleteAll() {
    return _storage.deleteAll();
  }
}
