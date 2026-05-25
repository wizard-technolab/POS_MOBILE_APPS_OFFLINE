import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _keyFirstLaunchAfterInstall = 'first_launch_after_install';

  // ── Server URL ──────────────────────────────
  static Future<String> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyServerUrl) ?? '';
  }

  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, url.trim());
  }

  // ── API Key ─────────────────────────────────
  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey) ?? '';
  }

  static Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiKey, key.trim());
  }

  // ── Database Name ────────────────────────────
  static Future<String> getDb() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDb) ?? '';
  }

  static Future<void> saveDb(String db) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDb, db.trim());
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
  static Future<String> getApiToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiToken) ?? '';
  }

  static Future<void> saveApiToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiToken, token);
  }

  static Future<void> clearApiToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyApiToken);
  }

  // ── API Email ────────────────────────────────  ← NEW
  static Future<String> getApiEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiEmail) ?? '';
  }

  static Future<void> saveApiEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyApiEmail,
      email.trim().toLowerCase(),
    );
  }

  // ── User Profile Email ───────────────────────
  static Future<String> getUserProfileEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserProfileEmail) ?? '';
  }

  static Future<void> saveUserProfileEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyUserProfileEmail,
      email.trim().toLowerCase(),
    );
  }

  // ─────────────────────────────────────────────
  // API Password ─────────────────────────────  ← NEW
  static Future<String> getApiPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiPassword) ?? '';
  }

  static Future<void> saveApiPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiPassword, password);
  }

  // ─────────────────────────────────────────────
  // DEVICE CODE
  // ─────────────────────────────────────────────

  static Future<String> getDeviceCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceCode) ?? '';
  }

  static Future<void> saveDeviceCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDeviceCode, code.trim());
  }

  // ─────────────────────────────────────────────
  // AUTH STATE (FIXED)
  // ─────────────────────────────────────────────

  static Future<bool> isLoggedIn() async {
    final uid = await getUid();
    final token = await getApiToken();

    return uid > 0 && token.isNotEmpty;
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
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySubscriptionCode) ?? '';
  }

  /// Save subscription code locally for offline access
  static Future<void> saveSubscriptionCode(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySubscriptionCode, code.trim().toUpperCase());
    subscriptionValidNotifier.value = true;
  }

  /// Get the saved subscription expiration date string (persisted locally)
  static Future<String> getSubscriptionExpDate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySubscriptionExpDate) ?? '';
  }

  /// Save subscription expiration date locally for offline access
  static Future<void> saveSubscriptionExpDate(String expDate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySubscriptionExpDate, expDate);
  }

  static Future<String> getSubscriptionEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySubscriptionEmail) ?? '';
  }

  static Future<void> saveSubscriptionEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySubscriptionEmail, email.trim().toLowerCase());
  }

  /// Check if subscription is valid LOCALLY (works offline).
  /// Compares stored expiration date against current device date.
  static Future<bool> isSubscriptionValid() async {
    final code = await getSubscriptionCode();
    final expDateStr = await getSubscriptionExpDate();
    final savedEmail = await getSubscriptionEmail();
    final currentEmail = await getApiEmail();

    // No subscription data saved → not valid
    if (code.isEmpty || expDateStr.isEmpty) {
      return false;
    }

    if (savedEmail.isNotEmpty &&
        currentEmail.isNotEmpty &&
        savedEmail.toLowerCase() != currentEmail.toLowerCase()) {
      return false;
    }

    try {
      final expDate = DateTime.parse(expDateStr);
      final today = DateTime.now();

      // Compare date only (ignore time)
      final expDateOnly = DateTime(expDate.year, expDate.month, expDate.day);
      final todayOnly = DateTime(today.year, today.month, today.day);

      // Valid if expiration is today or in the future
      return !expDateOnly.isBefore(todayOnly);
    } catch (_) {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySubscriptionCode);
    await prefs.remove(_keySubscriptionExpDate);
    await prefs.remove(_keySubscriptionEmail);
    subscriptionValidNotifier.value = false;
  }

  /// Clear auth tokens only (keep server_url, email, password, subscription)
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUid);
    await prefs.remove(_keyApiToken);
    // Intentionally keep:
    // server_url, email, password → for re-login
    // subscription_code, subscription_exp_date → for offline expiry check
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
