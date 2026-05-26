import 'package:flutter/material.dart';

import '../services/app_security_service.dart';

class SecurityGate extends StatefulWidget {
  const SecurityGate({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<SecurityGate> createState() => _SecurityGateState();
}

class _SecurityGateState extends State<SecurityGate> {
  late final Future<SecurityStatus> _statusFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = AppSecurityService.checkDeviceIntegrity();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SecurityStatus>(
      future: _statusFuture,
      builder: (context, snapshot) {
        final status = snapshot.data;

        if (status != null &&
            status.isCompromised &&
            SecurityPolicy.blockCompromisedDevices) {
          return _BlockedDeviceScreen(status: status);
        }

        return Stack(
          children: [
            widget.child,
            if (status != null && status.hasWarnings)
              _SecurityWarningBanner(status: status),
          ],
        );
      },
    );
  }
}

class _SecurityWarningBanner extends StatelessWidget {
  const _SecurityWarningBanner({required this.status});

  final SecurityStatus status;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      right: 12,
      top: MediaQuery.of(context).padding.top + 8,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFD97706),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            'Security warning: ${status.issues.take(2).join(', ')}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockedDeviceScreen extends StatelessWidget {
  const _BlockedDeviceScreen({required this.status});

  final SecurityStatus status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0F1C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.security,
                color: Color(0xFFF59E0B),
                size: 56,
              ),
              const SizedBox(height: 20),
              const Text(
                'Device security check failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                status.issues.join('\n'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFCBD5E1),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
