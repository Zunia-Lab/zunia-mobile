import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/change_password_screen.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/screens/remove_wallet_screen.dart';
import 'package:zunia_mobile/screens/reveal_phrase_screen.dart';
import 'package:zunia_mobile/screens/security_screen.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/screens/wallets_screen.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_ui/zunia_ui.dart';

import '../support/kernel.dart';

/// Every security screen at 320 dp wide with large text (1.3), on both
/// platform idioms: no overflow, nothing thrown.
void main() {
  // The real fonts: the test font draws every glyph a full em wide, which
  // overflows any label and says nothing about the app.
  setUpAll(() async {
    for (final (family, files) in [
      ('SpaceGrotesk', ['Light', 'Regular', 'Medium', 'Bold']),
      ('JetBrainsMono', ['Regular', 'Medium']),
    ]) {
      final loader = FontLoader(family);
      for (final weight in files) {
        final bytes = File('assets/fonts/$family-$weight.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  final screens = <String, Widget Function()>{
    'unlock': () => const UnlockScreen(),
    'onboarding welcome': () => const OnboardingScreen(),
    'security': () => const SecurityScreen(),
    'accounts': () => const WalletsScreen(),
    'change password': () => const ChangePasswordScreen(),
    'remove wallet': () => const RemoveWalletScreen(),
    'forgot password': () => const RemoveWalletScreen(forgotPassword: true),
    'reveal phrase': () => const RevealPhraseScreen(),
  };

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} fits 320 dp at 1.3x (${platform.name})',
          (tester) async {
        await _pump(tester, platform, entry.value());
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('create and restore steps fit 320 dp at 1.3x (${platform.name})',
        (tester) async {
      await _pump(tester, platform, const OnboardingScreen());
      await tester.tap(find.text('Create a new wallet'));
      await tester.pumpAndSettle();
      expect(find.text('I have written it down'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());

      await _pump(
        tester,
        platform,
        const OnboardingScreen(initialMode: OnboardingMode.import),
      );
      expect(find.text('Restore wallet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, skip: kernelSkip != false);
  }
}

Future<void> _pump(WidgetTester tester, TargetPlatform platform, Widget screen) async {
  SharedPreferences.setMockInitialValues({
    'zunia.wallet.accounts': jsonEncode([
      {'id': 'acct-a', 'name': 'A rather long account name', 'index': 0, 'phraseId': 'p-1'},
      {'id': 'acct-b', 'name': 'Old two', 'index': 1, 'phraseId': 'p-1'},
    ]),
    'zunia.wallet.activeAccount': 'acct-a',
    'zunia.wallet.phrases': jsonEncode({
      'p-1': {'words': 12, 'createdAt': 0, 'verified': false},
    }),
  });
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keystoreProvider.overrideWithValue(
          Keystore(secrets: MemorySecretStore(), runner: runInline),
        ),
        biometricVaultProvider.overrideWithValue(FakeBiometricVault()),
        walletConnectProvider.overrideWithValue(StubWalletConnectService()),
        nativeConnectProvider.overrideWithValue(NativeConnectService()),
      ],
      child: MaterialApp(
        theme: ZuniaTheme.dark().copyWith(platform: platform),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
