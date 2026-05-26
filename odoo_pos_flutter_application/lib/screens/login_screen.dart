// ignore_for_file: non_constant_identifier_names, deprecated_member_use

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:OdoCart/widgets/top_notification.dart';
import 'package:OdoCart/screens/session_screen.dart';
import 'package:OdoCart/screens/subscription_screen.dart';
import '../services/odoo_service.dart';
import '../services/app_config.dart';
import '../services/subscription_service.dart';
import '../services/db_helper.dart';

// ─────────────────────────────────────────────
// COLORS
// ─────────────────────────────────────────────
const kBg = Color(0xFF0D0F1C);
const kCard = Color(0xFF151828);
const kCardBorder = Color(0xFF1E2235);
const kPurple = Color(0xFF6C63FF);
const kPurpleLight = Color(0xFF8B83FF);
const kRed = Color(0xFFE53935);
const kTextPrimary = Color(0xFFFFFFFF);
const kTextSecondary = Color(0xFF8B90A7);
const kInputBg = Color(0xFF1A1D2E);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final dbHelper = DatabaseHelper();

  bool _isLoading = false;
  bool _passwordVisible = false;
  bool _hasOfflineLogin = false;

  String? _errorMsg;

  Future<void> _clearSubscriptionIfEmailChanged(String username) async {
    final previousEmail = await AppConfig.getApiEmail();
    if (previousEmail.isNotEmpty &&
        previousEmail.toLowerCase() != username.toLowerCase()) {
      await AppConfig.clearSubscription();
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // LOAD SAVED DATA
  // ─────────────────────────────────────────────
  Future<void> _loadSavedData() async {
    final url = await AppConfig.getServerUrl();

    if (mounted) {
      _urlController.text = url.isNotEmpty ? url : "";

      if (!kIsWeb) {
        final saved = await DatabaseHelper().getSavedLoginCredentials();
        if (saved != null) {
          _hasOfflineLogin = true;
          _usernameController.text = saved['username'] ?? '';
          _urlController.text = saved['server_url'] ?? _urlController.text;
        }
      }
      setState(() {});
    }
  }

  /// Refresh saved subscription from the license server without breaking
  /// offline/local validity. This must never clear a valid local subscription
  /// just because the server/ngrok/network is unavailable or returns a generic
  /// validation error during login.
  Future<void> _refreshSavedSubscriptionIfNeeded() async {
    final savedCode = await AppConfig.getSubscriptionCode();
    if (savedCode.isEmpty) return;

    final localStillValid = await AppConfig.isSubscriptionValid();
    final email = await AppConfig.getApiEmail();

    // If the saved subscription is still valid locally, allow login to continue
    // immediately. A failed refresh should not force the SubscriptionScreen.
    if (localStillValid) {
      final result = await SubscriptionService.validateLicenseCode(savedCode);

      if (result['status'] == 'success') {
        await AppConfig.saveSubscriptionExpDate(result['exp_date']);
        await AppConfig.saveSubscriptionEmail(email);
      }

      // Keep local subscription for all non-success refresh responses here.
      // Server-side revocation can still be handled by background sync, but
      // login must remain offline-capable.
      return;
    }

    // Local subscription is missing/expired. Try online validation once.
    final result = await SubscriptionService.validateLicenseCode(savedCode);

    if (result['status'] == 'success') {
      await AppConfig.saveSubscriptionExpDate(result['exp_date']);
      await AppConfig.saveSubscriptionEmail(email);
      await AppConfig.markFirstLaunchComplete();
      return;
    }

    final message = (result['message'] ?? '').toString().toLowerCase();
    if (message.contains('connection') ||
        message.contains('server') ||
        message.contains('timeout') ||
        message.contains('network')) {
      // Backend unavailable: do not clear saved subscription data.
      return;
    }

    // Only clear when local subscription is already invalid and backend also
    // rejects it explicitly.
    await AppConfig.clearSubscription();
  }

  // Show a styled dialog for backend errors like "No POS access"
  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.error_outline, color: kRed, size: 28),
            const SizedBox(width: 12),
            const Text(
              'Access Denied',
              style:
                  TextStyle(color: kTextPrimary, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(color: kTextSecondary, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'OK',
              style: TextStyle(color: kPurple, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // Helper to sanitize the URL before sending to Odoo
  String _sanitizeUrl(String url) {
    url = url.trim();
    if (url.isEmpty) return "";
    // Ensure protocol is present, default to https if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    // Remove trailing slash which breaks Odoo API endpoints
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  // ─────────────────────────────────────────────
  // LOGIN LOGIC (JWT ONLY + OFFLINE)
  // ─────────────────────────────────────────────
  Future<void> _handleLogin() async {
    final url = _sanitizeUrl(_urlController.text);
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty) {
      setState(() => _errorMsg = 'Enter Username / Email');
      return;
    }

    await _clearSubscriptionIfEmailChanged(username);

    if (password.isEmpty) {
      setState(() => _errorMsg = 'Enter Password');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    bool success = false;

    // ─────────────────────────────────────────
    // CASE 1: URL EMPTY → DIRECT OFFLINE LOGIN
    // ─────────────────────────────────────────
    if (url.isEmpty && !kIsWeb) {
      final offline = await dbHelper.validateOfflineLogin(
        username: username,
        password: password,
      );

      if (offline != null) {
        await AppConfig.saveServerUrl(offline['server_url'] ?? '');
        await AppConfig.saveApiEmail(offline['username']);
        await AppConfig.saveApiPassword(password);
        await AppConfig.saveUid(offline['uid'] ?? 0);

        OdooService.setSessionInfo(
          username: offline['username'],
          password: password,
        );

        success = true;

        if (mounted) {
          showTopNotification(
            context,
            'Logged in using offline mode.',
            icon: Icons.wifi_off_rounded,
          );
        }
      }
    }

    // ─────────────────────────────────────────
    // CASE 2: ONLINE LOGIN
    // ─────────────────────────────────────────
    if (!success && url.isNotEmpty) {
      try {
        await AppConfig.saveServerUrl(url);

        final jwtLogin = await OdooService.login(
          username: username,
          password: password,
        );

        if (jwtLogin) {
          final realUid = await AppConfig.getUid();

          await AppConfig.saveApiEmail(username);
          await AppConfig.saveApiPassword(password);

          await dbHelper.saveLoginCredentials(
            serverUrl: url,
            dbName: 'jwt_only',
            username: username,
            password: password,
            uid: realUid,
          );

          OdooService.setSessionInfo(
            username: username,
            password: password,
          );

          success = true;
        }
      } catch (e) {
        // Handle specific error messages from Odoo (e.g. POS access restriction)
        if (mounted) {
          final cleanMessage = e.toString().replaceFirst('Exception: ', '');
          _showErrorDialog(cleanMessage);
        }
        success = false;
      }
    }

    // ─────────────────────────────────────────
    // CASE 3: SERVER DOWN → ASK FOR OFFLINE LOGIN
    // ─────────────────────────────────────────
    if (!success && !kIsWeb) {
      final offline = await dbHelper.validateOfflineLogin(
        username: username,
        password: password,
      );

      if (offline != null) {
        final allowOffline = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              backgroundColor: kCard,
              title: const Text(
                'Offline Login',
                style: TextStyle(color: kTextPrimary),
              ),
              content: const Text(
                'Server not online.\nDo you want to login offline?',
                style: TextStyle(color: kTextSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context, false);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context, true);
                  },
                  child: const Text('Login Offline'),
                ),
              ],
            );
          },
        );

        if (allowOffline == true) {
          await AppConfig.saveServerUrl(offline['server_url'] ?? '');
          await AppConfig.saveApiEmail(offline['username']);
          await AppConfig.saveApiPassword(password);
          await AppConfig.saveUid(offline['uid'] ?? 0);

          OdooService.setSessionInfo(
            username: offline['username'],
            password: password,
          );

          success = true;
        }
      }
    }

    if (!mounted) return;

    setState(() => _isLoading = false);

    // if (success) {
    //   Navigator.of(context).pushReplacement(
    //     MaterialPageRoute(
    //       builder: (_) => const PosSessionScreen(),
    //     ),
    //   );
    // } else {
    //   setState(() {
    //     _errorMsg =
    //         'Login failed. Check email, password, saved offline credentials, or internet.';
    //   });
    // }
    if (success) {
      final hadValidSubscriptionBeforeRefresh =
          await AppConfig.isSubscriptionValid();

      await _refreshSavedSubscriptionIfNeeded();

      final hasValidSubscription = await AppConfig.isSubscriptionValid();
      final isFirstLaunch = await AppConfig.isFirstLaunchAfterInstall();

      // If this install already has a valid local subscription, never force the
      // subscription screen just because it is the first route after re-login.
      // Marking first launch complete here prevents the subscription screen from
      // appearing again after logout/login.
      if (hasValidSubscription &&
          (hadValidSubscriptionBeforeRefresh || isFirstLaunch)) {
        await AppConfig.markFirstLaunchComplete();
      }

      if (!hasValidSubscription) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const SubscriptionScreen(),
          ),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const PosSessionScreen(),
          ),
        );
      }
    } else {
      setState(() {
        _errorMsg =
            'Login failed. Check email, password, saved offline credentials, or internet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),

              // ─────────────────────────────────────────
              // LOGO / TITLE
              // ─────────────────────────────────────────
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [kPurple, kPurpleLight],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.point_of_sale_rounded,
                        color: kTextPrimary,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'OdoCart Login',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _hasOfflineLogin
                          ? 'Offline login available'
                          : 'First login requires internet',
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 48),

              // ─────────────────────────────────────────
              // ERROR MESSAGE
              // ─────────────────────────────────────────
              if (_errorMsg != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: kRed.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: kRed,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMsg!,
                          style: const TextStyle(
                            color: kRed,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // ─────────────────────────────────────────
              // SERVER URL — always visible so user can change it anytime
              // ─────────────────────────────────────────
              _fieldLabel('Server URL'),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _urlController,
                hint: 'https://your-odoo.com',
                icon: Icons.dns_rounded,
              ),
              const SizedBox(height: 16),

              // USERNAME
              _fieldLabel('Username / Email'),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _usernameController,
                hint: 'admin@example.com',
                icon: Icons.person_outline_rounded,
              ),
              const SizedBox(height: 16),

              // PASSWORD
              _fieldLabel('Password'),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _passwordController,
                hint: '••••••••',
                icon: Icons.lock_outline_rounded,
                obscure: !_passwordVisible,
                suffix: IconButton(
                  icon: Icon(
                    _passwordVisible ? Icons.visibility_off : Icons.visibility,
                    color: kTextSecondary,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      _passwordVisible = !_passwordVisible;
                    });
                  },
                ),
              ),

              const SizedBox(height: 32),

              // LOGIN BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPurple,
                    disabledBackgroundColor: kPurple.withValues(alpha: 0.6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                    ),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kTextPrimary,
                          ),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(
                            color: kTextPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: kTextSecondary,
        fontSize: 13,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(
        color: kTextPrimary,
        fontSize: 14,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: kTextSecondary,
        ),
        prefixIcon: Icon(
          icon,
          color: kTextSecondary,
          size: 20,
        ),
        suffixIcon: suffix,
        filled: true,
        fillColor: kInputBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: kCardBorder,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: kCardBorder,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: kPurple,
          ),
        ),
      ),
    );
  }
}
