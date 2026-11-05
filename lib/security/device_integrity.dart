import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Basic root and jailbreak checks, run natively (`integrity.check` on the
/// `zunia/security` channel):
/// - iOS: jailbreak files and apps (Cydia, Sileo, MobileSubstrate, `/var/jb`
///   of rootless jailbreaks, `apt`, `sshd`), a write outside the sandbox, and
///   hooking libraries loaded into the process.
/// - Android: `su` binaries on the usual paths, a build signed with
///   test-keys, Magisk's directories, and `ro.debuggable` / `ro.secure`.
///
/// These are the checks a determined attacker hides from first, so a clean
/// result means "no obvious sign", never "safe". Nothing here is Play
/// Integrity or App Attest; the screen says so.
@immutable
class DeviceIntegrityReport {
  const DeviceIntegrityReport({
    required this.checked,
    required this.isCompromised,
    required this.signals,
    this.emulator = false,
  });

  /// The checks could not run (no native side). Says nothing either way.
  static const notChecked =
      DeviceIntegrityReport(checked: false, isCompromised: false, signals: []);

  final bool checked;
  final bool isCompromised;

  /// What was found, in plain words (e.g. "su binary at /system/xbin/su").
  final List<String> signals;

  /// Simulator or emulator: expected in development, not a compromise.
  final bool emulator;
}

class DeviceIntegrity {
  DeviceIntegrity._();

  static const _channel = MethodChannel('zunia/security');
  static DeviceIntegrityReport? _cached;

  /// Runs the native checks once per launch.
  static Future<DeviceIntegrityReport> check({bool refresh = false}) async {
    final cached = _cached;
    if (cached != null && !refresh) return cached;
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return DeviceIntegrityReport.notChecked;
    }
    try {
      final map =
          await _channel.invokeMapMethod<String, Object?>('integrity.check');
      if (map == null) return DeviceIntegrityReport.notChecked;
      final report = DeviceIntegrityReport(
        checked: true,
        isCompromised: map['compromised'] == true,
        signals: [
          for (final s in (map['signals'] as List<Object?>? ?? const []))
            if (s is String) s,
        ],
        emulator: map['emulator'] == true,
      );
      return _cached = report;
    } on MissingPluginException {
      return DeviceIntegrityReport.notChecked;
    } on PlatformException {
      return DeviceIntegrityReport.notChecked;
    }
  }
}
