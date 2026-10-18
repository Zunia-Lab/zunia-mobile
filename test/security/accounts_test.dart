import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

import '../support/kernel.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';
const _password = 'wallet password 1';
const _prompt = BiometricPromptText(title: 'Test');

/// Accounts as in extension 0.1.5: each added account has its own phrase,
/// one password unlocks them all, and the active account's phrase and
/// derivation index are what signing reads.
void main() {
  late MemorySecretStore secrets;
  late FakeBiometricVault bio;
  late ProviderContainer container;

  VaultSession session() => container.read(vaultSessionProvider);
  WalletData wallet() => container.read(walletProvider);

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(
          Keystore(secrets: secrets, runner: runInline),
        ),
        biometricVaultProvider.overrideWithValue(bio),
        // No relay or WalletConnect in a unit test; removal tolerates both
        // being unavailable.
        nativeConnectProvider.overrideWith((ref) => throw UnsupportedError('test')),
        walletConnectProvider.overrideWith((ref) => throw UnsupportedError('test')),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
    bio = FakeBiometricVault();
    container = makeContainer();
    await container.read(walletProvider.notifier).ready;
    await container.read(securitySettingsProvider.notifier).ready;
  });

  /// Onboarding, as WalletSetupFlow does it.
  Future<String> onboard() async {
    final id = await container
        .read(keystoreProvider)
        .createVault(phrase: _phrase, password: _password);
    await container.read(walletProvider.notifier).initialise(
          walletName: 'Main',
          enabledChainIds: const ['safrochain-1'],
          phraseId: id,
          wordCount: 12,
          backupVerified: true,
        );
    await session().begin(VaultUnlock(phrases: {id: _phrase}));
    return id;
  }

  test('a new account has its own phrase and becomes active', () async {
    final firstPhrase = await onboard();
    expect(container.read(phraseProvider), _phrase);
    final first = wallet().active!;

    final other = WalletKernel.instance.generateMnemonic(words: 24);
    final added = await session().addAccount(
      phrase: other,
      password: _password,
      name: '  Savings   account ',
    );
    expect(added.name, 'Savings account');
    expect(added.index, 0, reason: 'own phrase derives at index 0');
    expect(added.phraseId, isNot(firstPhrase));
    expect(added.avatarSeed, isNot(first.avatarSeed));
    expect(wallet().active!.id, added.id);
    expect(container.read(phraseProvider), other);
    expect(wallet().phraseOf(added)!.backupVerified, isFalse);
    expect(wallet().phraseOf(added)!.wordCount, 24);

    // The same password opens both after a restart.
    session().lock();
    expect(container.read(phraseProvider), isNull);
    expect(container.read(sessionProvider), isNull);
    await session().unlockWithPassword(_password);
    expect(container.read(sessionProvider)!.phrases.values, containsAll([_phrase, other]));
    expect(container.read(phraseProvider), other, reason: 'active survives the lock');
  }, skip: kernelSkip);

  test('switching swaps the phrase in the same step as the account', () async {
    await onboard();
    final main = wallet().active!;
    final other = WalletKernel.instance.generateMnemonic();
    final added = await session().addAccount(
      phrase: other,
      password: _password,
      name: 'Two',
    );

    final seen = <(String?, String?)>[];
    container.listen<String?>(
      walletProvider.select((w) => w.active?.id),
      (_, id) => seen.add((id, container.read(phraseProvider))),
    );
    await session().switchAccount(main.id);
    expect(container.read(phraseProvider), _phrase);
    expect(wallet().active!.index, 0);
    await session().switchAccount(added.id);
    // A listener on the account already reads the matching phrase.
    expect(seen, [(main.id, _phrase), (added.id, other)]);
  }, skip: kernelSkip);

  test('refuses a phrase that is already in the wallet', () async {
    await onboard();
    await expectLater(
      session().addAccount(
        phrase: 'ABANDON abandon  abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon about',
        password: _password,
        name: 'Dup',
      ),
      throwsA(isA<KeystoreException>()),
    );
    expect(wallet().accounts, hasLength(1));
  }, skip: kernelSkip);

  test('remove takes the password, erases the phrase, keeps the last', () async {
    await onboard();
    final added = await session().addAccount(
      phrase: WalletKernel.instance.generateMnemonic(),
      password: _password,
      name: 'Gone soon',
    );
    await expectLater(
      session().removeAccount(added.id, 'wrong password'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(wallet().accounts, hasLength(2));

    await session().removeAccount(added.id, _password);
    expect(wallet().accounts, hasLength(1));
    expect(await container.read(keystoreProvider).phraseIds(), hasLength(1));
    expect(container.read(sessionProvider)!.phrases, hasLength(1));
    expect(container.read(phraseProvider), _phrase, reason: 'back on the first');

    await expectLater(
      session().removeAccount(wallet().active!.id, _password),
      throwsA(isA<KeystoreException>()),
    );
  }, skip: kernelSkip);

  test('an older HD child of the first phrase keeps index 1 and derives there',
      () async {
    // The index as an older build wrote it: no phrase ids, a second account
    // at derivation index 1 of the same phrase.
    SharedPreferences.setMockInitialValues({
      'zunia.wallet.accounts': jsonEncode([
        {'id': 'acct-0', 'name': 'Main', 'index': 0},
        {'id': 'acct-1', 'name': 'Two', 'index': 1},
      ]),
      'zunia.wallet.activeAccount': 'acct-1',
    });
    final older = makeContainer();
    final id = await older
        .read(keystoreProvider)
        .createVault(phrase: _phrase, password: _password);
    await older.read(walletProvider.notifier).ready;
    await older.read(vaultSessionProvider).begin(VaultUnlock(phrases: {id: _phrase}));

    final active = older.read(walletProvider).active!;
    expect(active.id, 'acct-1');
    expect(active.phraseId, id);
    expect(active.index, 1);
    expect(active.isHdChild, isTrue);
    expect(older.read(phraseProvider), _phrase);
    // Signing reads phrase + index: the kernel path for it.
    final chain = ChainEntry.fromJson(
      (jsonDecode(File('assets/chains/catalog.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((c) => c['chainId'] == 'cosmoshub-4'),
    );
    final derived = WalletKernel.instance.deriveAddress(
      phrase: _phrase,
      chain: chain,
      accountIndex: active.index,
    );
    expect(derived.path, "m/44'/118'/0'/0/1");
  }, skip: kernelSkip);

  test('rename is cleaned like the extension', () async {
    await onboard();
    final id = wallet().active!.id;
    await session().renameAccount(id, '   ');
    expect(wallet().active!.name, 'Main');
    await session().renameAccount(id, 'x' * 40);
    expect(wallet().active!.name, 'x' * 32);
  }, skip: kernelSkip);

  test('networks are per account', () async {
    await onboard();
    await session().addAccount(
      phrase: WalletKernel.instance.generateMnemonic(),
      password: _password,
      name: 'Two',
      enabledChainIds: const ['osmosis-1'],
    );
    expect(wallet().enabledChainIds, ['osmosis-1']);
    await container.read(walletProvider.notifier).toggleChain('cosmoshub-4');
    expect(wallet().enabledChainIds, ['osmosis-1', 'cosmoshub-4']);
    await session().switchAccount(wallet().accounts.first.id);
    expect(wallet().enabledChainIds, ['safrochain-1']);
  }, skip: kernelSkip);

  group('biometrics and password', () {
    test('biometric unlock reads the password from the bound store', () async {
      await onboard();
      await session().enableBiometrics(_password, _prompt);
      expect(container.read(securitySettingsProvider).biometricUnlock, isTrue);
      expect(bio.secret, _password);
      session().lock();
      await session().unlockWithBiometrics(_prompt);
      expect(container.read(phraseProvider), _phrase);
    }, skip: kernelSkip);

    test('a changed enrolment turns biometric unlock off', () async {
      await onboard();
      await session().enableBiometrics(_password, _prompt);
      session().lock();
      bio.nextFailure = BiometricFailure.invalidated;
      await expectLater(
        session().unlockWithBiometrics(_prompt),
        throwsA(isA<BiometricException>().having(
          (e) => e.failure,
          'failure',
          BiometricFailure.invalidated,
        )),
      );
      expect(container.read(securitySettingsProvider).biometricUnlock, isFalse);
      expect(await session().biometricsReady(), isFalse);
    }, skip: kernelSkip);

    test('change password re-seals all and moves the biometric secret', () async {
      await onboard();
      final other = WalletKernel.instance.generateMnemonic();
      await session().addAccount(phrase: other, password: _password, name: 'Two');
      await session().enableBiometrics(_password, _prompt);

      final outcome = await session().changePassword(
        current: _password,
        next: 'brand new password',
        prompt: _prompt,
      );
      expect(outcome, BiometricOutcome.kept);
      expect(bio.secret, 'brand new password');
      session().lock();
      await expectLater(
        session().unlockWithPassword(_password),
        throwsA(isA<WrongPasswordException>()),
      );
      await session().unlockWithPassword('brand new password');
      expect(container.read(sessionProvider)!.phrases.values, containsAll([_phrase, other]));
    }, skip: kernelSkip);

    test('if the new password cannot go behind biometrics, they turn off', () async {
      await onboard();
      await session().enableBiometrics(_password, _prompt);
      bio.nextFailure = BiometricFailure.cancelled;
      final outcome = await session().changePassword(
        current: _password,
        next: 'another password',
        prompt: _prompt,
      );
      expect(outcome, BiometricOutcome.turnedOff);
      expect(bio.secret, isNull, reason: 'the old password must not linger');
      expect(container.read(securitySettingsProvider).biometricUnlock, isFalse);
    }, skip: kernelSkip);

    test('removing the wallet erases vault, index and biometric secret', () async {
      await onboard();
      await session().enableBiometrics(_password, _prompt);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('zunia.addressBook', '[]');
      await prefs.setString('zunia.prefs.theme', 'dark');

      final wipe = VaultSession(
        _RefProbe.of(container),
        wipeOtherSecrets: () async {},
      );
      await expectLater(
        wipe.removeWallet(password: 'wrong one'),
        throwsA(isA<WrongPasswordException>()),
      );
      await wipe.removeWallet(password: _password);
      expect(secrets.values, isEmpty);
      expect(bio.secret, isNull);
      expect(wallet().accounts, isEmpty);
      expect(container.read(sessionProvider), isNull);
      expect(prefs.getString('zunia.addressBook'), isNull);
      expect(prefs.getString('zunia.prefs.theme'), 'dark');
    }, skip: kernelSkip);
  });
}

/// A [Ref] for building a [VaultSession] by hand in a test.
final _refProvider = Provider<Ref>((ref) => ref);

abstract final class _RefProbe {
  static Ref of(ProviderContainer container) => container.read(_refProvider);
}
