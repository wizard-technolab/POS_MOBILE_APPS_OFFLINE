import 'package:flutter/material.dart';
import '../services/subscription_service.dart';
import '../services/app_config.dart';
import 'login_screen.dart';
import 'session_screen.dart';

const kBg = Color(0xFF0D0F1C);
const kCard = Color(0xFF151828);
const kCardBorder = Color(0xFF1E2235);
const kPurple = Color(0xFF6C63FF);
const kPurpleLight = Color(0xFF8B83FF);
const kGreen = Color(0xFF4CAF50);
const kRed = Color(0xFFE53935);
const kTextPrimary = Color(0xFFFFFFFF);
const kTextSecondary = Color(0xFF8B90A7);
const kInputBg = Color(0xFF1A1D2E);

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _codeController = TextEditingController();

  bool _isValidating = false;
  String? _errorMsg;
  String? _successMsg;
  String? _expDate;
  String? _userEmail;
  String? _savedLicenseCode;
  String? _savedSubscriptionEmail;

  @override
  void initState() {
    super.initState();
    _refreshSubscriptionInfo(showResultMessage: false);
  }

  Future<void> _refreshSubscriptionInfo({bool showResultMessage = true}) async {
    final email = await AppConfig.getApiEmail();
    final savedEmail = await AppConfig.getSubscriptionEmail();
    final savedCode = await AppConfig.getSubscriptionCode();
    final expDate = await AppConfig.getSubscriptionExpDate();

    if (!mounted) return;

    setState(() {
      _userEmail = email;
      _savedSubscriptionEmail = savedEmail.isNotEmpty ? savedEmail : null;
      _savedLicenseCode = savedCode.isNotEmpty ? savedCode : null;
      _expDate = expDate.isNotEmpty ? expDate : null;
      _errorMsg = null;
      if (showResultMessage) {
        _successMsg = savedCode.isNotEmpty
            ? 'Loaded saved license for ${_savedSubscriptionEmail ?? _userEmail ?? 'current email'}.'
            : 'No saved license code found for this email.';
      }
    });
  }

  void _exitToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  // VALIDATE LICENSE CODE
  // ─────────────────────────────────────────────
  Future<void> _validateAndActivate() async {
    final code = _codeController.text.trim();

    if (code.isEmpty) {
      setState(() {
        _errorMsg = 'Please enter a license code';
        _successMsg = null;
      });
      return;
    }

    setState(() {
      _isValidating = true;
      _errorMsg = null;
      _successMsg = null;
    });

    try {
      final result = await SubscriptionService.validateLicenseCode(code);

      if (!mounted) return;

      if (result['status'] == 'success') {
        // Save subscription data locally (persists for offline use)
        await AppConfig.saveSubscriptionCode(code.toUpperCase());
        await AppConfig.saveSubscriptionExpDate(result['exp_date']);
        await AppConfig.saveSubscriptionEmail(
          await AppConfig.getApiEmail(),
        );
        final licenseToken = result['license_token']?.toString() ?? '';
        if (licenseToken.isNotEmpty) {
          await AppConfig.saveSubscriptionLicenseToken(licenseToken);
        }

        setState(() {
          _expDate = result['exp_date'];
          _successMsg =
              'License activated! Valid until ${result['exp_date']} (${result['days_remaining']} days remaining)';
          _errorMsg = null;
          _isValidating = false;
        });

        // Wait 2 seconds then redirect to session screen
// Wait 2 seconds then redirect to session screen
        await Future.delayed(const Duration(seconds: 2));

        if (!mounted) return;

        await AppConfig.markFirstLaunchComplete();

        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const PosSessionScreen(),
          ),
        );
      } else {
        setState(() {
          _errorMsg = result['message'] ?? 'Validation failed';
          _successMsg = null;
          _isValidating = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = 'Error: $e';
        _successMsg = null;
        _isValidating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: _exitToLogin,
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: kTextPrimary),
                    tooltip: 'Back to Login',
                  ),
                  IconButton(
                    onPressed: _isValidating ? null : _refreshSubscriptionInfo,
                    icon: const Icon(Icons.refresh, color: kTextPrimary),
                    tooltip: 'Refresh subscription info',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // HEADER
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kPurple, kPurpleLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.lock_open_rounded,
                  color: kTextPrimary,
                  size: 40,
                ),
              ),

              const SizedBox(height: 28),

              const Text(
                'Activate Subscription',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 12),

              const Text(
                'Enter your license code to activate your subscription',
                style: TextStyle(
                  color: kTextSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),

              // Show logged-in email
              if (_userEmail != null && _userEmail!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Logged in as: $_userEmail',
                  style: const TextStyle(
                    color: kPurpleLight,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],

              if (_savedLicenseCode != null &&
                  _savedLicenseCode!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Saved license: $_savedLicenseCode',
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],

              if (_savedSubscriptionEmail != null &&
                  _savedSubscriptionEmail!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Subscription linked to: $_savedSubscriptionEmail',
                  style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 40),

              // SUCCESS MESSAGE
              if (_successMsg != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kGreen.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline,
                          color: kGreen, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _successMsg!,
                          style: const TextStyle(color: kGreen, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // ERROR MESSAGE
              if (_errorMsg != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kRed.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: kRed, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMsg!,
                          style: const TextStyle(color: kRed, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // LICENSE CODE INPUT
              _buildLabel('License Code'),
              const SizedBox(height: 8),
              TextField(
                controller: _codeController,
                enabled: !_isValidating,
                style: const TextStyle(
                  color: kTextPrimary,
                  fontSize: 14,
                  letterSpacing: 1.0,
                ),
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'e.g., LICENSE-ABC123-XYZ789',
                  hintStyle: const TextStyle(color: kTextSecondary),
                  prefixIcon: const Icon(Icons.vpn_key_rounded,
                      color: kTextSecondary, size: 20),
                  filled: true,
                  fillColor: kInputBg,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kCardBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kCardBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kPurple),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // EXPIRATION DATE (readonly, shown after validation)
              if (_expDate != null) ...[
                _buildLabel('Expiration Date'),
                const SizedBox(height: 8),
                TextField(
                  controller: TextEditingController(text: _expDate),
                  enabled: false,
                  style: const TextStyle(color: kGreen, fontSize: 14),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.calendar_today_rounded,
                        color: kGreen, size: 20),
                    filled: true,
                    fillColor: kCard,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kGreen),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // ACTIVATE BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isValidating ? null : _validateAndActivate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPurple,
                    disabledBackgroundColor: kPurple.withValues(alpha: 0.6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  child: _isValidating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kTextPrimary),
                        )
                      : const Text(
                          'Activate License',
                          style: TextStyle(
                            color: kTextPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 12),

              // INFO BOX
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kCardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'About Your License',
                      style: TextStyle(
                        color: kTextPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildInfoLine(
                        '• Your license is tied to your login email'),
                    const SizedBox(height: 6),
                    _buildInfoLine(
                        '• The expiration date is auto-filled after validation'),
                    const SizedBox(height: 6),
                    _buildInfoLine(
                        '• Internet is required to activate the first time'),
                    const SizedBox(height: 6),
                    _buildInfoLine(
                        '• After activation, the app works offline until expiry'),
                    const SizedBox(height: 6),
                    _buildInfoLine(
                        '• Expired licenses will prompt re-activation'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          color: kTextSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInfoLine(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: kTextSecondary,
        fontSize: 12,
        height: 1.4,
      ),
    );
  }
}
