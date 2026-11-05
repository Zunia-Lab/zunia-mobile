/// The status and navigation bars follow the app's theme, on both platforms.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/main.dart';

void main() {
  test('dark theme: light icons (Android) and a dark status bar (iOS)', () {
    final style = systemBarsFor(Brightness.dark);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
    expect(style.statusBarColor, Colors.transparent);
  });

  test('light theme: dark icons (Android) and a light status bar (iOS)', () {
    final style = systemBarsFor(Brightness.light);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    expect(style.systemNavigationBarColor, Colors.transparent);
  });

  testWidgets('the app shell annotates the bars from the resolved theme', (tester) async {
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: systemBarsFor(Theme.of(context).brightness),
            child: child!,
          ),
          home: const SizedBox.expand(),
        ),
      );
      // MaterialApp animates a theme change; read the settled one.
      await tester.pumpAndSettle();
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
      );
      expect(
        region.value.statusBarIconBrightness,
        mode == ThemeMode.dark ? Brightness.light : Brightness.dark,
      );
    }
  });
}
