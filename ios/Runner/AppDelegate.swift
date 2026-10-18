import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Lets flutter_local_notifications show a notice while the app is open
    // and hear which one was tapped (FlutterAppDelegate forwards both).
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZuniaHaptics") {
      ZuniaHaptics.register(messenger: registrar.messenger())
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
