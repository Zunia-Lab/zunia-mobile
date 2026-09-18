import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a fresh install lands on the welcome step', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZuniaApp()));
    // Allow the appGate FutureProvider to resolve.
    await tester.pumpAndSettle();

    // Assert the copy the screen actually renders. The previous version looked
    // for the text 'zunia', which stopped existing the day the wordmark became
    // artwork, and for a 'Create wallet' label that has always read
    // 'Create a new wallet' — so it failed for reasons that said nothing about
    // whether onboarding works.
    expect(find.text('Your keys.\nEvery chain.'), findsOneWidget);
    expect(find.text('Create a new wallet'), findsOneWidget);
  });
}
