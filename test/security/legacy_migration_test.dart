import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/legacy_vault.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

import '../support/kernel.dart';

/// test/fixtures/legacy_vault_v1.json was written by the keystore and
/// wallet state this branch replaced (the XOR-wrapped envelope in
/// SharedPreferences, the wrapping key and the plaintext biometric password
/// in secure storage, accounts without phrase ids, one HD child at index 1).
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/legacy_vault_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final phrase = fixture['phrase'] as String;
  final password = fixture['password'] as String;

  Map<String, Object> prefsOf(String which) => {
        for (final e in ((fixture[which] as Map)['prefs'] as Map).entries)
          e.key as String: e.value is List
              ? (e.value as List).cast<String>()
              : e.value as Object,
      };

  MemorySecretStore secretsOf(String which) => MemorySecretStore({
        for (final e in ((fixture[which] as Map)['secure'] as Map).entries)
          e.key as String: e.value as String,
      });

  test('the old biometric password is purged before any unlock', () async {
    SharedPreferences.setMockInitialValues(prefsOf('kernelInner'));
    final secrets = secretsOf('kernelInner');
    expect(secrets.values.containsKey(kLegacyBioPasswordKey), isTrue);
    await Keystore(secrets: secrets, runner: runInline)
        .purgeLegacyBiometricSecrets();
    expect(secrets.values.containsKey(kLegacyBioPasswordKey), isFalse);
    expect(secrets.values.containsKey(kLegacyBioUnlockSecretKey), isFalse);
  });

  test('first unlock moves the kernel envelope to v2 and deletes the old data',
      () async {
    SharedPreferences.setMockInitialValues(prefsOf('kernelInner'));
    final secrets = secretsOf('kernelInner');
    final keystore = Keystore(secrets: secrets, runner: runInline);
    expect(await keystore.format(), VaultFormat.legacy);

    await expectLater(
      keystore.unlock('not it at all'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(await keystore.format(), VaultFormat.legacy, reason: 'nothing moved');

    final unlock = await keystore.unlock(password);
    final migration = unlock.migration!;
    expect(unlock.phrases, {migration.phraseId: phrase});
    expect(migration.backupVerified, isTrue);

    expect(await keystore.format(), VaultFormat.v2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(kLegacyEnvelopePrefsKey), isFalse);
    expect(prefs.containsKey(kLegacyVerifiedPrefsKey), isFalse);
    expect(secrets.values.keys.where((k) => k.startsWith('zunia.keystore.')), isEmpty);

    // From now on it is an ordinary v2 vault.
    final again = await Keystore(secrets: secrets, runner: runInline).unlock(password);
    expect(again.phrases, {migration.phraseId: phrase});
    expect(again.migration, isNull);
  }, skip: kernelSkip);

  test('the old development fallback (XOR-sealed phrase) migrates too', () async {
    SharedPreferences.setMockInitialValues(prefsOf('fallbackInner'));
    final secrets = secretsOf('fallbackInner');
    final keystore = Keystore(secrets: secrets, runner: runInline);
    final unlock = await keystore.unlock(password);
    expect(unlock.phrases.values.single, phrase);
    expect(unlock.migration!.backupVerified, isFalse);
    expect(await keystore.format(), VaultFormat.v2);
  }, skip: kernelSkip);

  test('the account index follows: phrase ids, the HD child keeps index 1',
      () async {
    SharedPreferences.setMockInitialValues(prefsOf('kernelInner'));
    final secrets = secretsOf('kernelInner');
    final container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(
          Keystore(secrets: secrets, runner: runInline),
        ),
        biometricVaultProvider.overrideWithValue(FakeBiometricVault()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(walletProvider.notifier).ready;
    final before = container.read(walletProvider);
    expect(before.accounts.map((a) => a.phraseId), everyElement(isEmpty));

    await container.read(vaultSessionProvider).unlockWithPassword(password);

    final wallet = container.read(walletProvider);
    final phraseId = container.read(sessionProvider)!.phrases.keys.single;
    expect(wallet.accounts.map((a) => a.id), ['acct-0', 'acct-1']);
    expect(wallet.accounts.map((a) => a.phraseId), everyElement(phraseId));
    expect(wallet.accounts.map((a) => a.index), [0, 1]);
    expect(wallet.accounts[1].isHdChild, isTrue);
    expect(wallet.accounts.map((a) => a.avatarSeed), everyElement(isNotNull));
    expect(wallet.phrases[phraseId]!.backupVerified, isTrue);
    // The fixture left account 2 active: it stays active, on its phrase.
    expect(wallet.active!.id, 'acct-1');
    expect(container.read(phraseProvider), phrase);
    expect(wallet.enabledChainIds, ['safrochain-1', 'osmosis-1']);
  }, skip: kernelSkip);
}
