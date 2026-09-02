/// Push messaging stub.
///
/// When Firebase is linked, uncomment `firebase_core` / `firebase_messaging` in
/// pubspec.yaml and replace this with FCM token registration + foreground handlers.
class PushMessaging {
  PushMessaging._();

  static Future<void> init() async {
    // no-op until firebase_messaging is enabled
  }

  static Future<String?> getToken() async => null;
}
