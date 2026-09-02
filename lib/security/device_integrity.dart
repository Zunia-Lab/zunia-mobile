import 'package:flutter/foundation.dart';

/// Root / jailbreak detection stub.
///
/// Replace [DeviceIntegrity.check] with Play Integrity / DeviceCheck / a vendor
/// plugin (e.g. freerasp, jailbreak_root_detection) before production.
class DeviceIntegrityReport {
  const DeviceIntegrityReport({
    required this.isCompromised,
    required this.signals,
  });

  final bool isCompromised;
  final List<String> signals;
}

class DeviceIntegrity {
  DeviceIntegrity._();

  /// Best-effort check. Currently returns clean unless [debugForceCompromised].
  static Future<DeviceIntegrityReport> check({
    bool debugForceCompromised = false,
  }) async {
    final signals = <String>[];
    if (debugForceCompromised) {
      signals.add('debug_force');
    }
    // Hook point: Play Integrity (Android) / DeviceCheck / App Attest (iOS).
    if (kDebugMode && signals.isEmpty) {
      // Debug builds never block onboarding on integrity.
    }
    return DeviceIntegrityReport(
      isCompromised: signals.isNotEmpty,
      signals: signals,
    );
  }
}
