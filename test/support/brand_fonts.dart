import 'package:flutter/services.dart';

/// Loads Space Grotesk and JetBrains Mono from the app's assets.
///
/// flutter_test otherwise sets every glyph as a square one em wide, which makes
/// a label far wider than it is on a phone; layout checks (320dp, large text)
/// only mean something with the real metrics.
Future<void> loadBrandFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      loader.addFont(rootBundle.load(file));
    }
    await loader.load();
  }

  await family('SpaceGrotesk', [
    'assets/fonts/SpaceGrotesk-Light.ttf',
    'assets/fonts/SpaceGrotesk-Regular.ttf',
    'assets/fonts/SpaceGrotesk-Medium.ttf',
    'assets/fonts/SpaceGrotesk-Bold.ttf',
  ]);
  await family('JetBrainsMono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-Medium.ttf',
  ]);
}
