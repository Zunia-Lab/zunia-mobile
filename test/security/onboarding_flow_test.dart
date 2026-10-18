import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

import '../support/kernel.dart';

const _restore =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';

/// Onboarding end to end: create (acknowledge, reveal, verify, password,
/// networks) and restore (validation, never auto-verified).
void main() {
  late ProviderContainer container;
  late MemorySecretStore secrets;

  Future<void> pump(WidgetTester tester, Widget screen) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(ChainCatalog.load);
    secrets = MemorySecretStore();
    container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(
          Keystore(secrets: secrets, runner: runInline),
        ),
        biometricVaultProvider.overrideWithValue(FakeBiometricVault()),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: ZuniaTheme.dark(), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> choosePassword(WidgetTester tester) async {
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Main');
    await tester.enterText(fields.at(1), 'Str0ng password!');
    await tester.enterText(fields.at(2), 'Str0ng password!');
    await tester.pumpAndSettle();
    expect(find.text('STRONG'), findsOneWidget);
    await tapText(tester, 'Continue');
  }

  /// The busy button spins while the vault is sealed and the biometric
  /// offer is up, so pumpAndSettle would never settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  testWidgets('create: acknowledge, reveal, verify, password, networks',
      (tester) async {
    await pump(tester, const OnboardingScreen(initialMode: OnboardingMode.create));

    // Nothing to reveal before the two statements are ticked.
    final reveal = find.widgetWithText(ZuniaButton, 'Reveal');
    expect(tester.widget<ZuniaButton>(reveal).onPressed, isNull);
    await tester.tap(find.textContaining('I will never share'));
    await tester.tap(find.textContaining('I accept that Zunia'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(reveal);
    await tester.tap(reveal);
    await tester.pumpAndSettle();

    final grid = tester.widget<ZuniaMnemonicGrid>(find.byType(ZuniaMnemonicGrid));
    final words = grid.words;
    expect(words, hasLength(12));
    await tapText(tester, 'I have written it down');

    // Four checks for twelve words: pick what the grid showed.
    for (var i = 0; i < 4; i++) {
      final prompt = tester
          .widget<Text>(find.textContaining('Tap word'))
          .textSpan!
          .toPlainText();
      final position = int.parse(prompt.replaceAll(RegExp(r'\D'), ''));
      await tester.tap(find.text(words[position - 1]).last);
      await tester.pumpAndSettle();
    }

    await choosePassword(tester);
    await tapAndSettle(tester, find.textContaining('Create wallet'));
    // Offered biometric unlock: not now.
    expect(find.textContaining('Unlock with'), findsOneWidget);
    await tapAndSettle(tester, find.text('Not now'));

    final session = container.read(sessionProvider);
    expect(session, isNotNull);
    expect(session!.phrases.values.single, words.join(' '));
    final wallet = container.read(walletProvider);
    expect(wallet.active!.name, 'Main');
    expect(wallet.phraseOf(wallet.active!)!.backupVerified, isTrue);
    expect(wallet.enabledChainIds, contains('safrochain-1'));
    expect(container.read(phraseProvider), words.join(' '));
    await tester.pumpWidget(const SizedBox());
  }, skip: kernelSkip != false);

  testWidgets('restore: checked as typed, and not marked verified',
      (tester) async {
    await pump(tester, const OnboardingScreen(initialMode: OnboardingMode.import));
    await tester.tap(find.textContaining('I will never share'));
    await tester.tap(find.textContaining('I accept that Zunia'));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    await tester.enterText(field, _restore.replaceFirst('about', 'abuot'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"abuot") is not a recovery-phrase word'), findsWidgets);

    await tester.enterText(field, '1. ${_restore.replaceAll(' ', '\n')}');
    await tester.pumpAndSettle();
    expect(find.text('12 words · checksum OK'), findsOneWidget);
    await tapText(tester, 'Continue');

    await choosePassword(tester);
    await tapText(tester, 'Continue · 3');
    expect(find.text('Check your written copy?'), findsOneWidget);
    await tapAndSettle(tester, find.text('Skip for now'));
    await tapAndSettle(tester, find.text('Not now'));

    expect(container.read(sessionProvider)!.phrases.values.single, _restore);
    final wallet = container.read(walletProvider);
    expect(wallet.phraseOf(wallet.active!)!.backupVerified, isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: kernelSkip != false);
}
