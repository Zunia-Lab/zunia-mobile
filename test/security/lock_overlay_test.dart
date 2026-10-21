import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/security_shell.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

import '../support/kernel.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';
const _password = 'right password';

/// The lock covers the app instead of replacing it: what was open is still
/// open after unlocking, and nothing underneath can be used meanwhile.
void main() {
  late ProviderContainer container;

  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final keystore = Keystore(secrets: MemorySecretStore(), runner: runInline);
    container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(keystore),
        biometricVaultProvider.overrideWithValue(
          FakeBiometricVault(available: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final id = await keystore.createVault(phrase: _phrase, password: _password);
    await container.read(walletProvider.notifier).initialise(
          walletName: 'Main',
          enabledChainIds: const ['safrochain-1'],
          phraseId: id,
          wordCount: 12,
        );
    await container.read(securitySettingsProvider.notifier).ready;
    await container.read(vaultSessionProvider).begin(
          VaultUnlock(phrases: {id: _phrase}),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: container.read(appNavigatorKeyProvider),
          theme: ZuniaTheme.dark(),
          builder: (context, child) => SecurityShell(child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('Half-typed send')),
                    ),
                  ),
                  child: const Text('Open send'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open send'));
    await tester.pumpAndSettle();
    expect(find.text('Half-typed send'), findsOneWidget);
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), _password);
    await tester.pump();
    await tester.tap(find.text('Unlock'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('lock covers the open screen, unlock returns to it', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);

    container.read(vaultSessionProvider).lock();
    await tester.pumpAndSettle();
    expect(container.read(phraseProvider), isNull);
    expect(find.text('Welcome back'), findsOneWidget);
    // Still there underneath, but not reachable.
    final underneath = find.text('Half-typed send');
    expect(underneath, findsOneWidget);
    bool covered<T extends Widget>(bool Function(T) test) => tester
        .widgetList<T>(find.ancestor(of: underneath, matching: find.byType(T)))
        .any(test);
    expect(covered<ExcludeSemantics>((w) => w.excluding), isTrue);
    expect(covered<AbsorbPointer>((w) => w.absorbing), isTrue);
    expect(find.bySemanticsLabel('Welcome back'), findsOneWidget);

    // Back does not navigate underneath the lock.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Half-typed send', skipOffstage: false), findsOneWidget);

    await unlock(tester);
    expect(container.read(phraseProvider), _phrase);
    expect(find.text('Welcome back'), findsNothing);
    expect(find.text('Half-typed send'), findsOneWidget);

    // And back works again once unlocked.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open send'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  }, skip: kernelSkip != false);

  testWidgets('"immediately" locks when the app leaves the screen', (tester) async {
    await pumpApp(tester);
    await container
        .read(securitySettingsProvider.notifier)
        .setAutoLock(AutoLockDelay.immediately);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(container.read(sessionProvider), isNotNull, reason: 'inactive is not leaving');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(sessionProvider), isNull);
    expect(container.read(phraseProvider), isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: kernelSkip != false);
}
