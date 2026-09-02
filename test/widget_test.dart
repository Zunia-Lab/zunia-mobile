import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Onboarding shows Zunia branding', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZuniaApp()));
    // Allow appGate FutureProvider to resolve.
    await tester.pumpAndSettle();

    expect(find.text('zunia'), findsWidgets);
    expect(find.text('Create wallet'), findsOneWidget);
  });
}
