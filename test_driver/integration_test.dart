import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves every `takeScreenshot` of a tour to $ZUNIA_SHOTS (default build/shots).
Future<void> main() {
  final dir = Directory(Platform.environment['ZUNIA_SHOTS'] ?? 'build/shots')
    ..createSync(recursive: true);
  return integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      File('${dir.path}/$name.png').writeAsBytesSync(bytes);
      return true;
    },
  );
}
