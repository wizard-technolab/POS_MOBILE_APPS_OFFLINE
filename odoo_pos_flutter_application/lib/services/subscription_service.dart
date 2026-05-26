import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'app_config.dart';

class SubscriptionService {
  /// The static remote server that manages all global subscriptions.
  static const String _licenseServerUrl = String.fromEnvironment(
    'WT_LICENSE_SERVER_URL',
    defaultValue: 'https://synopses-wreckage-babied.ngrok-free.dev',
  );

  /// Do not commit subscription/HMAC secrets in source code.
  /// Supply at build time:
  /// --dart-define=WT_APP_SECRET_KEY=your_secret
  ///
  /// For backward-compatible deployments, AppConfig.getApiKey() is used as a
  /// secure-storage fallback if this build-time value is empty.
  static const String _appSecretKey = String.fromEnvironment(
    'WT_APP_SECRET_KEY',
    defaultValue: '',
  );

  /// Validate license code against backend.
  /// Sends user email for ownership verification.
  static Future<Map<String, dynamic>> validateLicenseCode(String code) async {
    try {
      // Get user email to verify license ownership
      // Prefer the real email from profile, fallback to login username
      String email = await AppConfig.getUserProfileEmail();
      if (email.isEmpty) email = await AppConfig.getApiEmail();

      if (email.isEmpty) {
        return {
          'status': 'error',
          'message': 'User email not found. Please log in again.',
        };
      }

      final cleanCode = code.trim().toUpperCase();
      final cleanEmail = email.trim().toLowerCase();

      if (kDebugMode) {
        print('🔍 Validating License: $cleanCode for Email: $cleanEmail');
      }

      final appSecretKey = _appSecretKey.isNotEmpty
          ? _appSecretKey
          : await AppConfig.getApiKey();

      if (appSecretKey.isEmpty) {
        return {
          'status': 'error',
          'message': 'Subscription security key is not configured.',
        };
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final Map<String, dynamic> payload = {
        'code': cleanCode,
        'email': cleanEmail,
      };
      final String bodyString = jsonEncode(payload);

      // Generate HMAC signature: hash(secret, body + timestamp)
      final hmac = Hmac(sha256, utf8.encode(appSecretKey));
      final digest = hmac.convert(utf8.encode(bodyString + timestamp));
      final signature = digest.toString();

      final response = await http
          .post(
            Uri.parse('$_licenseServerUrl/api/v1/subscription/validate'),
            headers: {
              'Content-Type': 'application/json',
              'X-WT-SIGNATURE': signature,
              'X-WT-TIMESTAMP': timestamp,
              // We keep the email in header or body as a public identifier
              'X-WT-EMAIL': cleanEmail,
              'ngrok-skip-browser-warning':
                  'true', // For ngrok testing, remove in production
            },
            body: bodyString,
          )
          .timeout(const Duration(seconds: 15));

      if (kDebugMode) {
        print('📡 Server Response (${response.statusCode}): ${response.body}');
      }

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == 'success') {
        return {
          'status': 'success',
          'exp_date': data['data']['exp_date'],
          'days_remaining': data['data']['days_remaining'],
          'message': data['message'] ?? 'License activated successfully',
        };
      } else {
        return {
          'status': 'error',
          'message': data['message'] ?? 'Invalid license code',
        };
      }
    } on http.ClientException catch (e) {
      return {
        'status': 'error',
        'message': 'Connection failed: ${e.message}',
      };
    } catch (e) {
      return {
        'status': 'error',
        'message': 'Connection error: $e',
      };
    }
  }

  /// Check if subscription is valid locally (offline-capable)
  static Future<bool> isSubscriptionValid() async {
    return await AppConfig.isSubscriptionValid();
  }

  /// Get remaining days until expiration (offline-capable)
  static Future<int> getDaysRemaining() async {
    return await AppConfig.getSubscriptionDaysRemaining();
  }

  /// Get subscription expiration date formatted
  static Future<String> getFormattedExpDate() async {
    final expDateStr = await AppConfig.getSubscriptionExpDate();

    if (expDateStr.isEmpty) return 'Not activated';

    try {
      final expDate = DateTime.parse(expDateStr);
      return '${expDate.year}-${expDate.month.toString().padLeft(2, '0')}-${expDate.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'Invalid date';
    }
  }

  /// Clear subscription (on logout or reset)
  static Future<void> clearSubscription() async {
    await AppConfig.clearSubscription();
  }
}
