import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/main.dart';
import 'package:zunia_mobile/screens/splash_screen.dart';
import 'package:zunia_mobile/screens/welcome_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The vault lives in secure storage; an empty one is a fresh install.
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('a fresh install opens on the splash, then the welcome screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZuniaApp()));
    expect(find.byType(SplashScreen), findsWidgets);

    // The welcome screen idles with a looping animation, so it never
    // "settles": step past the splash (intro + dissolve, under 900 ms).
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('Create a new wallet'), findsOneWidget);
    expect(find.text('I already have a wallet'), findsOneWidget);
  });
}
