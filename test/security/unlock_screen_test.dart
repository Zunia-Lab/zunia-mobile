import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_ui/zunia_ui.dart';

import '../support/kernel.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';

void main() {
  testWidgets('wrong passwords back off with a countdown; the right one unlocks',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = MemorySecretStore();
    final keystore = Keystore(secrets: secrets, runner: runInline);
    // In the test's own zone: a future completed under runAsync would
    // schedule the keystore's queue on the real event loop.
    await keystore.createVault(phrase: _phrase, password: 'right password');
    final container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(keystore),
        biometricVaultProvider.overrideWithValue(
          FakeBiometricVault(available: false),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: const UnlockScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);

    Future<void> attempt(String password) async {
      await tester.enterText(find.byType(TextField), password);
      await tester.pump();
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    await attempt('wrong 1');
    expect(find.text('Wrong password'), findsOneWidget);
    await attempt('wrong 2');
    await attempt('wrong 3');
    expect(
      find.text('Wrong password. Wait 2 s before trying again.'),
      findsOneWidget,
    );
    expect(find.text('Try again in 2 s'), findsOneWidget);

    // Real time has to pass: the backoff compares wall clocks.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Unlock'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'right password');
    await tester.pump();
    await tester.tap(find.text('Unlock'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(container.read(sessionProvider)?.phrases.values, [_phrase]);

    // Unmount so the countdown ticker is disposed.
    await tester.pumpWidget(const SizedBox());
  }, skip: kernelSkip != false);
}
