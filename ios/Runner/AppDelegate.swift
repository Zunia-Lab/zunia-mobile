import Flutter
import LocalAuthentication
import MachO
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    PrivacyCover.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZuniaHaptics") {
      ZuniaHaptics.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZuniaSecurity") {
      ZuniaSecurity.register(messenger: registrar.messenger())
    }
  }
}

/// `zunia/haptics`: the notification feedback UIKit plays for a result
/// (success, warning, error), which Flutter's HapticFeedback does not expose.
enum ZuniaHaptics {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zunia/haptics", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let kind: UINotificationFeedbackGenerator.FeedbackType
      switch call.method {
      case "success": kind = .success
      case "warning": kind = .warning
      case "error": kind = .error
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      let generator = UINotificationFeedbackGenerator()
      generator.prepare()
      generator.notificationOccurred(kind)
      result(nil)
    }
  }
}

/// `zunia/security`: hardware-bound biometric unlock, basic jailbreak checks
/// and sensitive clipboard copies. `zunia/security/capture`: screen
/// recording / mirroring state and screenshots. Dart side:
/// lib/security/biometric_vault.dart, device_integrity.dart,
/// clipboard_guard.dart, screen_security.dart.
enum ZuniaSecurity {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zunia/security", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "biometric.availability":
        result(ZuniaBiometricVault.availability())
      case "biometric.exists":
        result(ZuniaBiometricVault.exists())
      case "biometric.store":
        guard let secret = args["secret"] as? String, !secret.isEmpty else {
          result(FlutterError(code: "failed", message: "Nothing to store", details: nil))
          return
        }
        ZuniaBiometricVault.store(secret: secret, reason: reason(args), result: result)
      case "biometric.read":
        ZuniaBiometricVault.read(reason: reason(args), result: result)
      case "biometric.delete":
        ZuniaBiometricVault.delete()
        result(nil)
      case "integrity.check":
        result(ZuniaIntegrityCheck.run())
      case "clipboard.copySensitive":
        let text = args["text"] as? String ?? ""
        let seconds = args["expiresInSeconds"] as? Int ?? 30
        // Local only: Universal Clipboard does not hand a recovery phrase to
        // the user's other devices. It also expires by itself.
        UIPasteboard.general.setItems(
          [["public.utf8-plain-text": text]],
          options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(TimeInterval(seconds)),
          ]
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: "zunia/security/capture", binaryMessenger: messenger)
      .setStreamHandler(ZuniaCaptureEvents.shared)
  }

  /// The line Touch ID / Face ID shows under the app name.
  private static func reason(_ args: [String: Any]) -> String {
    (args["title"] as? String) ?? "Unlock Zunia"
  }
}

/// The wallet password in a Keychain item only a biometric match releases.
///
/// Access control `.biometryCurrentSet` with
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`: the Secure Enclave
/// releases the item only after Face ID / Touch ID / Optic ID matches one of
/// the biometrics enrolled when it was written. Enrolling another face or
/// finger, or removing the passcode, makes it unreadable for good (biometric
/// unlock is then set up again with the password). No passcode fallback, never
/// synced to iCloud, never in a backup restored to another device.
enum ZuniaBiometricVault {
  private static let service = "com.zunialab.zunia.biometric-vault"
  private static let account = "wallet-password"

  private enum Outcome {
    case value(String)
    case failure(FlutterError)
  }

  static func availability() -> [String: Any] {
    let context = LAContext()
    var error: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    var kind = "none"
    switch context.biometryType {
    case .faceID: kind = "face"
    case .touchID: kind = "fingerprint"
    default:
      if #available(iOS 17.0, *), context.biometryType == .opticID { kind = "optic" }
    }
    var reason: Any = NSNull()
    if !available, let error = error {
      switch LAError.Code(rawValue: error.code) {
      case .biometryNotEnrolled: reason = "none_enrolled"
      case .passcodeNotSet: reason = "passcode_not_set"
      case .biometryLockout: reason = "locked_out"
      default: reason = "no_hardware"
      }
    }
    return ["available": available, "kind": kind, "reason": reason]
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Attributes only: reading them never needs the biometric check.
  static func exists() -> Bool {
    var query = baseQuery()
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  static func delete() {
    SecItemDelete(baseQuery() as CFDictionary)
  }

  static func store(secret: String, reason: String, result: @escaping FlutterResult) {
    PrivacyCover.suppressed = true
    DispatchQueue.global(qos: .userInitiated).async {
      delete()
      var error: Unmanaged<CFError>?
      guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        .biometryCurrentSet,
        &error
      ) else {
        finish(result, FlutterError(code: "unavailable", message: "No access control", details: nil))
        return
      }
      var add = baseQuery()
      add[kSecAttrAccessControl as String] = access
      add[kSecValueData as String] = Data(secret.utf8)
      let status = SecItemAdd(add as CFDictionary, nil)
      guard status == errSecSuccess else {
        finish(result, flutterError(status))
        return
      }
      // Read it back once: turning biometric unlock on takes a real match,
      // and proves the item opens before the app relies on it.
      switch copy(reason: reason) {
      case .value(let value) where value == secret:
        finish(result, nil)
      case .value:
        delete()
        finish(result, FlutterError(code: "failed", message: "Read back differs", details: nil))
      case .failure(let failure):
        delete()
        finish(result, failure)
      }
    }
  }

  static func read(reason: String, result: @escaping FlutterResult) {
    PrivacyCover.suppressed = true
    DispatchQueue.global(qos: .userInitiated).async {
      switch copy(reason: reason) {
      case .value(let value): finish(result, value)
      case .failure(let failure): finish(result, failure)
      }
    }
  }

  /// Blocks while the system prompt is up: never on the main thread.
  private static func copy(reason: String) -> Outcome {
    let context = LAContext()
    context.localizedReason = reason
    // No "Enter Passcode": the item does not accept it, and the app's own
    // password field is the fallback.
    context.localizedFallbackTitle = ""
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else { return .failure(flutterError(status)) }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      return .failure(FlutterError(code: "failed", message: "Unreadable item", details: nil))
    }
    return .value(value)
  }

  private static func flutterError(_ status: OSStatus) -> FlutterError {
    let code: String
    switch status {
    case errSecUserCanceled:
      code = "cancelled"
    case errSecItemNotFound:
      // Also what an item invalidated by a change of enrolment reads as.
      code = "not_found"
    case errSecInteractionNotAllowed, errSecNotAvailable:
      code = "unavailable"
    case errSecAuthFailed:
      var error: NSError?
      let lockedOut = !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        && LAError.Code(rawValue: error?.code ?? 0) == .biometryLockout
      code = lockedOut ? "lockout" : "failed"
    default:
      code = "failed"
    }
    return FlutterError(code: code, message: "OSStatus \(status)", details: nil)
  }

  private static func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async {
      result(value)
      // The scene turns active again just after the prompt goes away.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PrivacyCover.suppressed = false }
    }
  }
}

/// Covers the window with the launch screen whenever the scene resigns
/// active, so the app switcher's snapshot shows no balance or address. Native
/// because iOS takes the snapshot before a Flutter frame drawn now would land.
enum PrivacyCover {
  /// Up while Zunia's own biometric prompt shows: the app is only inactive.
  static var suppressed = false
  private static var cover: UIView?

  static func install() {
    let center = NotificationCenter.default
    center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { note in
      guard !suppressed, let scene = note.object as? UIWindowScene else { return }
      show(in: scene)
    }
    center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
      hide()
    }
  }

  private static func show(in scene: UIWindowScene) {
    guard cover == nil,
          let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    else { return }
    let view = UIStoryboard(name: "LaunchScreen", bundle: nil).instantiateInitialViewController()?.view
      ?? UIView()
    if view.backgroundColor == nil {
      view.backgroundColor = UIColor(red: 11 / 255, green: 10 / 255, blue: 9 / 255, alpha: 1)
    }
    view.frame = window.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(view)
    cover = view
  }

  private static func hide() {
    cover?.removeFromSuperview()
    cover = nil
  }
}

/// Screen capture state and screenshots, for the phrase screens: iOS cannot
/// block either, so the app hides the phrase while recording and warns after
/// a screenshot.
final class ZuniaCaptureEvents: NSObject, FlutterStreamHandler {
  static let shared = ZuniaCaptureEvents()

  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.sendCaptured() })
    observers.append(center.addObserver(
      forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.sink?(["type": "screenshot"]) })
    sendCaptured()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    sink = nil
    return nil
  }

  private func sendCaptured() {
    let captured = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .contains { $0.screen.isCaptured }
    sink?(["type": "captured", "value": captured])
  }
}

/// Basic jailbreak checks. Each is easy for a determined attacker to hide, so
/// a clean result is reported as "no obvious sign", never as safe.
enum ZuniaIntegrityCheck {
  static func run() -> [String: Any] {
    #if targetEnvironment(simulator)
    // The simulator sees the Mac's file system: every path check would fire.
    return ["compromised": false, "signals": [String](), "emulator": true]
    #else
    var signals: [String] = []
    let paths = [
      "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
      "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd", "/usr/bin/sshd",
      "/etc/apt", "/private/var/lib/apt/", "/bin/bash", "/usr/libexec/sftp-server",
      "/var/jb", "/private/var/jb", "/var/binpack", "/private/preboot/jb",
    ]
    for path in paths where FileManager.default.fileExists(atPath: path) {
      signals.append("jailbreak file at \(path)")
    }
    // A stock device keeps an app inside its sandbox.
    let probe = "/private/zunia-sandbox-probe-\(UUID().uuidString)"
    if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
      signals.append("the app could write outside its sandbox")
      try? FileManager.default.removeItem(atPath: probe)
    }
    // Hooking frameworks loaded into this process.
    let hooks = ["mobilesubstrate", "substrateloader", "libhooker", "tweakinject", "ellekit",
                 "libsubstitute", "cycript", "frida", "sslkillswitch"]
    var found = Set<String>()
    for i in 0..<_dyld_image_count() {
      guard let raw = _dyld_get_image_name(i) else { continue }
      let name = String(cString: raw).lowercased()
      for hook in hooks where name.contains(hook) { found.insert(hook) }
    }
    for hook in found.sorted() { signals.append("\(hook) loaded into the app") }
    return ["compromised": !signals.isEmpty, "signals": signals, "emulator": false]
    #endif
  }
}
