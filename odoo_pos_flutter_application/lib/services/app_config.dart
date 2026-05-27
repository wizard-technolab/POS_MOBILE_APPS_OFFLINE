import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage_service.dart';

// When session changes in Settings, this notifier tells all screens to reload
final sessionChangeNotifier = ValueNotifier<int>(0);

// Incremented every time an order is placed (online or offline).
final orderPlacedNotifier = ValueNotifier<int>(0);

// Incremented after a successful customer sync (upload or download).
final customerChangedNotifier = ValueNotifier<int>(0);

// Incremented after a successful product delta sync.
final productsChangedNotifier = ValueNotifier<int>(0);

/// Local storage helper for app configuration and auth state.
class AppConfig {
  /// Notifies the UI when the subscription state changes (e.g., invalidated during sync).
  static final subscriptionValidNotifier = ValueNotifier<bool>(true);

  static const _keyServerUrl = 'server_url';
  static const _keyApiKey = 'api_key';
  static const _keyDb = 'odoo_db';
  static const _keyUid = 'odoo_uid';
  static const _keyApiToken = 'api_token';
  static const _keyApiEmail = 'api_email';
  static const _keyUserProfileEmail = 'user_profile_email';
  static const _keyApiPassword = 'api_password';
  static const _keyDeviceCode = 'device_code';
  static const _keySubscriptionCode = 'subscription_code';
  static const _keySubscriptionExpDate = 'subscription_exp_date';
  static const _keySubscriptionEmail = 'subscription_email';
  static const _keySubscriptionLicenseToken = 'subscription_license_token';
  static const _keyFirstLaunchAfterInstall = 'first_launch_after_install';

  /// Shared in-flight token refresh.
  ///
  /// When several API calls detect an expired JWT/401 at the same time, they all
  /// await this same future instead of calling `/api/v1/auth` separately.
  static Future<String>? _refreshingApiToken;

  static Future<String> _getSecureString(String key) async {
    return await SecureStorageService.read(key) ?? '';
  }

  static Future<void> _saveSecureString(String key, String value) async {
    await SecureStorageService.write(key, value);
  }

  static Future<void> _removeSecureString(String key) async {
    await SecureStorageService.delete(key);
  }

  // ── Server URL ──────────────────────────────
  static Future<String> getServerUrl() async {
    return _getSecureString(_keyServerUrl);
  }

  static Future<void> saveServerUrl(String url) async {
    await _saveSecureString(_keyServerUrl, url.trim());
  }

  // ── API Key ─────────────────────────────────
  static Future<String> getApiKey() async {
    return _getSecureString(_keyApiKey);
  }

  static Future<void> saveApiKey(String key) async {
    await _saveSecureString(_keyApiKey, key.trim());
  }

  // ── Database Name ────────────────────────────
  static Future<String> getDb() async {
    return _getSecureString(_keyDb);
  }

  static Future<void> saveDb(String db) async {
    await _saveSecureString(_keyDb, db.trim());
  }

  // ── User ID ──────────────────────────────────
  static Future<int> getUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyUid) ?? 0;
  }

  static Future<void> saveUid(int uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUid, uid);
  }

  // ── JWT API Token ────────────────────────────
  /// Returns a usable JWT token.
  ///
  /// Existing code across the app calls this method before making Odoo API
  /// requests. Keeping the refresh logic here makes token recovery central and
  /// backward-compatible with those existing call sites.
  static Future<String> getApiToken({bool refreshIfNeeded = true}) async {
    final token = await _getSecureString(_keyApiToken);

    if (!refreshIfNeeded) return token;

    if (token.isNotEmpty && !isJwtExpired(token)) {
      return token;
    }

    return refreshApiToken();
  }

  /// Returns the stored JWT exactly as saved, without attempting refresh.
  static Future<String> getRawApiToken() async {
    return _getSecureString(_keyApiToken);
  }

  /// Re-authenticates using the saved Odoo credentials and stores a fresh JWT.
  ///
  /// This app's backend does not currently expose a separate refresh-token
  /// endpoint, so refresh means secure auto re-login using saved credentials.
  ///
  /// A refresh guard is used so parallel expired-token requests share one
  /// authentication request instead of firing multiple `/api/v1/auth` calls.
  static Future<String> refreshApiToken() async {
    final inFlightRefresh = _refreshingApiToken;
    if (inFlightRefresh != null) {
      return inFlightRefresh;
    }

    final refreshFuture = _refreshApiTokenInternal();
    _refreshingApiToken = refreshFuture;

    try {
      return await refreshFuture;
    } finally {
      if (identical(_refreshingApiToken, refreshFuture)) {
        _refreshingApiToken = null;
      }
    }
  }

  static Future<String> _refreshApiTokenInternal() async {
    final serverUrl = await getServerUrl();
    final email = await getApiEmail();
    final password = await getApiPassword();

    if (serverUrl.isEmpty || email.isEmpty || password.isEmpty) {
      await clearApiToken();
      return '';
    }

    final deviceCode = await getDeviceCode();

    try {
      final response = await http
          .post(
            Uri.parse('$serverUrl/api/v1/auth'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
              if (deviceCode.isNotEmpty) 'device_code': deviceCode,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 &&
          data is Map<String, dynamic> &&
          data['status'] == 'success' &&
          data['token'] != null) {
        final freshToken = data['token'].toString();
        await saveApiToken(freshToken);

        final rawUid = data['user_id'];
        if (rawUid is int && rawUid > 0) {
          await saveUid(rawUid);
        }

        return freshToken;
      }
    } catch (_) {
      // Keep callers stable: an empty token lets existing screens show their
      // current connection/authentication error handling.
    }

    await clearApiToken();
    return '';
  }

  static Future<void> saveApiToken(String token) async {
    await _saveSecureString(_keyApiToken, token);
  }

  static Future<void> clearApiToken() async {
    await _removeSecureString(_keyApiToken);
  }

  static bool isJwtExpired(
    String token, {
    Duration leeway = const Duration(minutes: 1),
  }) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;

      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(parts[1])),
        ),
      ) as Map<String, dynamic>;

      final exp = payload['exp'];
      if (exp is! int) return true;

      final expiry = DateTime.fromMillisecondsSinceEpoch(
        exp * 1000,
        isUtc: true,
      );
      return DateTime.now().toUtc().isAfter(expiry.subtract(leeway));
    } catch (_) {
      return true;
    }
  }

  // ── API Email ────────────────────────────────  ← NEW
  static Future<String> getApiEmail() async {
    return _getSecureString(_keyApiEmail);
  }

  static Future<void> saveApiEmail(String email) async {
    await _saveSecureString(
      _keyApiEmail,
      email.trim().toLowerCase(),
    );
  }

  // ── User Profile Email ───────────────────────
  static Future<String> getUserProfileEmail() async {
    return _getSecureString(_keyUserProfileEmail);
  }

  static Future<void> saveUserProfileEmail(String email) async {
    await _saveSecureString(
      _keyUserProfileEmail,
      email.trim().toLowerCase(),
    );
  }

  // ─────────────────────────────────────────────
  // API Password ─────────────────────────────  ← NEW
  static Future<String> getApiPassword() async {
    return _getSecureString(_keyApiPassword);
  }

  static Future<void> saveApiPassword(String password) async {
    await _saveSecureString(_keyApiPassword, password);
  }

  // ─────────────────────────────────────────────
  // DEVICE CODE
  // ─────────────────────────────────────────────

  static Future<String> getDeviceCode() async {
    return _getSecureString(_keyDeviceCode);
  }

  static Future<void> saveDeviceCode(String code) async {
    await _saveSecureString(_keyDeviceCode, code.trim());
  }

  // ─────────────────────────────────────────────
  // AUTH STATE (FIXED)
  // ─────────────────────────────────────────────

  static Future<bool> isLoggedIn() async {
    final uid = await getUid();

    // Login state must not depend on the JWT being present or unexpired.
    // JWT expiry should trigger re-auth/refresh, not force the user back
    // through subscription activation.
    return uid > 0;
  }

// ── POS Session ──────────────────────────────────
  static const _keyPosSessionId = 'pos_session_id';
  static const _keyPosSessionName = 'pos_session_name';
  static const _keyPosRawSessionName = 'pos_raw_session_name';

  // In-memory cache for currency symbol so it can be read synchronously
  // from anywhere in the UI (e.g. cart_screen string interpolations).
  // Default is ₹ (INR). Loaded from SharedPreferences at app startup
  // via loadCurrencySymbol(), and updated whenever a session is selected.
  static String _currencySymbol = '₹';

  // Synchronous getter — returns the in-memory cached value.
  // Always call loadCurrencySymbol() at startup so this is populated.
  static String get currencySymbol => _currencySymbol;

  // Load currency symbol from SharedPreferences into the in-memory cache.
  // Call this once in main() before runApp() so the value is ready
  // before any screen tries to read it.
  static Future<void> loadCurrencySymbol() async {
    final prefs = await SharedPreferences.getInstance();
    _currencySymbol = prefs.getString('currency_symbol') ?? '₹';
  }

  static Future<int> getPosSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyPosSessionId) ?? 0; // 0 = not selected
  }

  static Future<void> savePosSessionId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyPosSessionId, id);
    // Notify ProductScreen and OrdersScreen to reload automatically
    sessionChangeNotifier.value = id;
  }

  static Future<String> getPosSessionName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPosSessionName) ?? '';
  }

  static Future<String> getRawPosSessionName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPosRawSessionName) ?? '';
  }

  static Future<void> saveRawPosSessionName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPosRawSessionName, name.trim());
  }

  static Future<void> savePosSessionName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPosSessionName, name.trim());
  }

  static Future<void> clearPosSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPosSessionId);
    await prefs.remove(_keyPosSessionName);
  }

  static Future<int> getSequenceResetTime(int sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('sequence_reset_time_$sessionId') ?? 0;
  }

  static Future<void> resetSequence(int sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sequence_reset_time_$sessionId',
        DateTime.now().millisecondsSinceEpoch);
  }

  // ── SUBSCRIPTION CODE ────────────────────────
  static Future<String> getSubscriptionCode() async {
    return _getSecureString(_keySubscriptionCode);
  }

  /// Save subscription code locally for offline access
  static Future<void> saveSubscriptionCode(String code) async {
    await _saveSecureString(_keySubscriptionCode, code.trim().toUpperCase());
    subscriptionValidNotifier.value = true;
  }

  /// Get the saved subscription expiration date string (persisted locally)
  static Future<String> getSubscriptionExpDate() async {
    return _getSecureString(_keySubscriptionExpDate);
  }

  /// Save subscription expiration date locally for offline access
  static Future<void> saveSubscriptionExpDate(String expDate) async {
    await _saveSecureString(_keySubscriptionExpDate, expDate);
  }

  static Future<String> getSubscriptionEmail() async {
    return _getSecureString(_keySubscriptionEmail);
  }

  static Future<void> saveSubscriptionEmail(String email) async {
    await _saveSecureString(_keySubscriptionEmail, email.trim().toLowerCase());
  }

  static Future<String> getSubscriptionLicenseToken() async {
    return _getSecureString(_keySubscriptionLicenseToken);
  }

  static Future<void> saveSubscriptionLicenseToken(String token) async {
    await _saveSecureString(_keySubscriptionLicenseToken, token.trim());
  }

  /// Check if subscription is valid LOCALLY (works offline).
  /// Compares stored expiration date against current device date.
  ///
  /// Email validation logic:
  /// - If currentEmail is empty (offline mode): Allow subscription check to continue
  /// - If both emails exist: Must match (case-insensitive)
  /// - If only savedEmail exists: Allow (offline scenario)
  static Future<bool> isSubscriptionValid() async {
    final code = await getSubscriptionCode();
    final expDateStr = await getSubscriptionExpDate();
    final savedEmail = await getSubscriptionEmail();
    final currentEmail = await getApiEmail();

    // No subscription data saved → not valid
    if (code.isEmpty || expDateStr.isEmpty) {
      debugPrint('❌ isSubscriptionValid: No subscription data found');
      return false;
    }

    // ✅ FIX: Improved email validation logic
    // Only validate email match if BOTH emails are present
    // Allow offline mode where currentEmail may not be loaded yet
    if (savedEmail.isNotEmpty && currentEmail.isNotEmpty) {
      if (savedEmail.toLowerCase() != currentEmail.toLowerCase()) {
        debugPrint(
            '❌ isSubscriptionValid: Email mismatch - saved: $savedEmail, current: $currentEmail');
        return false;
      }
    } else if (savedEmail.isNotEmpty && currentEmail.isEmpty) {
      debugPrint(
          '⚠️  isSubscriptionValid: currentEmail empty but savedEmail exists - allowing check (offline mode?)');
      // Allow the check to continue - offline mode may not have loaded email yet
    }

    try {
      final expDate = DateTime.parse(expDateStr);
      final today = DateTime.now();

      // Compare date only (ignore time)
      final expDateOnly = DateTime(expDate.year, expDate.month, expDate.day);
      final todayOnly = DateTime(today.year, today.month, today.day);

      // Valid if expiration is today or in the future
      final isValid = !expDateOnly.isBefore(todayOnly);
      if (isValid) {
        debugPrint(
            '✅ isSubscriptionValid: Subscription is VALID until $expDateStr');
      } else {
        debugPrint(
            '❌ isSubscriptionValid: Subscription EXPIRED on $expDateStr');
      }
      return isValid;
    } catch (e) {
      debugPrint(
          '❌ isSubscriptionValid: Failed to parse expiration date: $expDateStr, error: $e');
      return false;
    }
  }

  /// Get days remaining until subscription expires (works offline)
  static Future<int> getSubscriptionDaysRemaining() async {
    final expDateStr = await getSubscriptionExpDate();

    if (expDateStr.isEmpty) return 0;

    try {
      final expDate = DateTime.parse(expDateStr);
      final today = DateTime.now();
      final difference = expDate.difference(today).inDays;
      return difference > 0 ? difference : 0;
    } catch (_) {
      return 0;
    }
  }

  // ── FIRST LAUNCH CHECK ──────────────────────
  static Future<bool> isFirstLaunchAfterInstall() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyFirstLaunchAfterInstall) ?? true;
  }

  static Future<void> markFirstLaunchComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFirstLaunchAfterInstall, false);
  }

  // ── CLEAR SUBSCRIPTION (but keep data for offline expiration check) ──
  static Future<void> clearSubscription() async {
    await _removeSecureString(_keySubscriptionCode);
    await _removeSecureString(_keySubscriptionExpDate);
    await _removeSecureString(_keySubscriptionEmail);
    await _removeSecureString(_keySubscriptionLicenseToken);
    subscriptionValidNotifier.value = false;
  }

  /// Clear auth tokens only (keep server_url, email, password, subscription)
  /// Clear auth tokens only (keep server_url, email, password, subscription)
  /// This allows re-login with saved credentials and offline subscription validation.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUid);
    await _removeSecureString(_keyApiToken);

    debugPrint('🔐 AppConfig.clear(): Removed UID & API token');
    debugPrint(
        '✅ Preserved: server_url, api_email, api_password, subscription data');

    // Intentionally KEEP these fields for re-login and offline scenarios:
    // - _keyServerUrl → server address for next login
    // - _keyApiEmail → email for subscription validation match
    // - _keyApiPassword → password for next login
    // - _keySubscriptionCode → license code for offline expiry check
    // - _keySubscriptionExpDate → expiry date for offline expiry check
    // - _keySubscriptionEmail → email subscription was tied to
    // - _keySubscriptionLicenseToken → license token for re-validation
  }

  // Save currency symbol to SharedPreferences AND update the in-memory
  // cache so the sync getter reflects the new value immediately.
  // Call this when a POS session is selected (session_screen.dart).
  static Future<void> setCurrencySymbol(String symbol) async {
    _currencySymbol = symbol.isNotEmpty ? symbol : '₹'; // update cache first
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currency_symbol', _currencySymbol);
  }

  static Future<String> getCurrencySymbol() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('currency_symbol') ?? '₹'; // fallback ₹
  }

  // ── COMPANY NAME ─────────────────────────────────────────────
  // Key used to store the company name in SharedPreferences.
  // This is populated when the user selects a POS session.
  static const _keyCompanyName = 'pos_company_name';

  /// Save the company name for the currently selected POS session.
  /// Called in session_screen.dart when a session is selected.
  static Future<void> saveCompanyName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCompanyName, name.trim());
  }

  /// Get the saved company name.
  /// Returns empty string if no company name has been saved yet.
  static Future<String> getCompanyName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCompanyName) ?? '';
  }

  static Future<SharedPreferences> get preferences async {
    return await SharedPreferences.getInstance();
  }
}
