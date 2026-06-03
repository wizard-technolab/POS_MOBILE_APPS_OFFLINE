import 'package:flutter/foundation.dart';
import 'package:jailbreak_root_detection/jailbreak_root_detection.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Runtime device integrity checks.
///
/// Root/jailbreak checks are defense-in-depth only. They can reduce risk, but
/// any client-side check can be bypassed on a fully compromised device.
class SecurityStatus {
  const SecurityStatus({
    required this.isCompromised,
    required this.isRealDevice,
    required this.issues,
  });

  final bool isCompromised;
  final bool isRealDevice;
  final List<String> issues;

  bool get hasWarnings => issues.isNotEmpty;

  static const safe = SecurityStatus(
    isCompromised: false,
    isRealDevice: true,
    issues: <String>[],
  );
}

class SecurityPolicy {
  /// Keep false initially to avoid breaking genuine devices due to false
  /// positives. Set to true for a stricter production rollout after testing on
  /// your supported Android/iOS devices.
  static const bool blockCompromisedDevices = bool.fromEnvironment(
    'BLOCK_COMPROMISED_DEVICES',
    defaultValue: true,
  );
}

class AppSecurityService {
  static Future<SecurityStatus> checkDeviceIntegrity() async {
    if (kIsWeb) return SecurityStatus.safe;

    final issues = <String>[];
    bool isCompromised = false;
    bool isRealDevice = true;

    try {
      final detector = JailbreakRootDetection.instance;
      final jailBroken = await detector.isJailBroken;
      final notTrusted = await detector.isNotTrust;
      isRealDevice = await detector.isRealDevice;
      final issueList = await detector.checkForIssues;

      if (jailBroken) {
        isCompromised = true;
        issues.add('Root/jailbreak indicators detected');
      }
      if (notTrusted) {
        isCompromised = true;
        issues.add('Device trust check failed');
      }
      if (!isRealDevice) {
        issues.add('Device appears to be an emulator/simulator');
      }
      if (issueList.isNotEmpty) {
        issues.addAll(issueList.map((e) => e.toString()));
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final devMode = await detector.isDevMode;
        final externalStorage = await detector.isOnExternalStorage;
        if (devMode) issues.add('Android developer mode is enabled');
        if (externalStorage) {
          isCompromised = true;
          issues.add('App appears to be running from external storage');
        }
      }

      final packageInfo = await PackageInfo.fromPlatform();
      try {
        final tampered = await detector.isTampered(packageInfo.packageName);
        if (tampered) {
          isCompromised = true;
          issues.add('Application tampering indicators detected');
        }
      } catch (_) {
        // Some tamper checks are platform-specific; ignore unsupported checks.
      }
    } catch (e) {
      issues.add('Device integrity check unavailable: $e');
    }

    return SecurityStatus(
      isCompromised: isCompromised,
      isRealDevice: isRealDevice,
      issues: issues.toSet().toList(growable: false),
    );
  }
}
