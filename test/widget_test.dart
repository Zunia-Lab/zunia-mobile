import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/main.dart';

void main() {
  testWidgets('Home screen shows Zunia branding', (tester) async {
    await tester.pumpWidget(const ZuniaApp());
    await tester.pump();

    expect(find.text('zunia'), findsOneWidget);
    expect(find.text('Create wallet'), findsOneWidget);
  });
}
