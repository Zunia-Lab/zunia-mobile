import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

import '../support/kernel.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';
const _password = 'correct horse 1';

/// Vault v2: one kernel envelope per phrase in the secret store, the
/// password the only key, nothing XOR-wrapped, one write per change.
void main() {
  late MemorySecretStore store;
  late Keystore keystore;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemorySecretStore();
    keystore = Keystore(secrets: store, runner: runInline);
  });

  test('create, then unlock with the password', () async {
    expect(await keystore.format(), VaultFormat.none);
    final id = await keystore.createVault(phrase: _phrase, password: _password);
    expect(await keystore.format(), VaultFormat.v2);
    final unlock = await keystore.unlock(_password);
    expect(unlock.phrases, {id: _phrase});
    expect(unlock.migration, isNull);
  }, skip: kernelSkip);

  test('what is stored is kernel envelopes, and not the phrase', () async {
    await keystore.createVault(phrase: _phrase, password: _password);
    final raw = store.values[kVaultKey]!;
    expect(raw, isNot(contains('abandon')));
    final record = jsonDecode(raw) as Map<String, dynamic>;
    expect(record['v'], 2);
    final envelope = jsonDecode(
      (record['phrases'] as List).single['envelope'] as String,
    ) as Map<String, dynamic>;
    expect(envelope['kdf'], 'argon2id');
    expect(envelope['aead'], 'xchacha20poly1305');
    // Nothing of the old wrap anywhere.
    expect(store.values.keys.where((k) => k.startsWith('zunia.keystore.')), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {kInstallMarkerKey});
  }, skip: kernelSkip);

  test('a wrong password is refused and counted', () async {
    await keystore.createVault(phrase: _phrase, password: _password);
    await expectLater(
      keystore.unlock('wrong password'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect((await keystore.throttle()).failures, 1);
    await keystore.unlock(_password);
    expect((await keystore.throttle()).failures, 0);
  }, skip: kernelSkip);

  test('refuses a second wallet and a short password', () async {
    await expectLater(
      keystore.createVault(phrase: _phrase, password: 'short'),
      throwsA(isA<KeystoreException>()),
    );
    await keystore.createVault(phrase: _phrase, password: _password);
    await expectLater(
      keystore.createVault(phrase: _phrase, password: _password),
      throwsA(isA<KeystoreException>()),
    );
  }, skip: kernelSkip);

  test('another phrase is sealed only with the wallet password', () async {
    final first = await keystore.createVault(phrase: _phrase, password: _password);
    final second = WalletKernel.instance.generateMnemonic(words: 24);
    await expectLater(
      keystore.addPhrase(phrase: second, password: 'not the password'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(await keystore.phraseIds(), [first]);
    final id = await keystore.addPhrase(phrase: second, password: _password);
    final unlock = await keystore.unlock(_password);
    expect(unlock.phrases, {first: _phrase, id: second});
    expect(await keystore.revealPhrase(phraseId: id, password: _password), second);
  }, skip: kernelSkip);

  test('removes a phrase, never the last', () async {
    final first = await keystore.createVault(phrase: _phrase, password: _password);
    final id = await keystore.addPhrase(
      phrase: WalletKernel.instance.generateMnemonic(),
      password: _password,
    );
    await keystore.removePhrase(id);
    expect(await keystore.phraseIds(), [first]);
    await expectLater(
      keystore.removePhrase(first),
      throwsA(isA<KeystoreException>()),
    );
  }, skip: kernelSkip);

  test('change password re-seals every phrase', () async {
    final first = await keystore.createVault(phrase: _phrase, password: _password);
    final other = WalletKernel.instance.generateMnemonic();
    final id = await keystore.addPhrase(phrase: other, password: _password);
    final before = store.values[kVaultKey];

    await expectLater(
      keystore.changePassword(current: 'nope nope', next: 'new password 2'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(store.values[kVaultKey], before, reason: 'untouched on failure');

    await keystore.changePassword(current: _password, next: 'new password 2');
    await expectLater(
      keystore.unlock(_password),
      throwsA(isA<WrongPasswordException>()),
    );
    final unlock = await keystore.unlock('new password 2');
    expect(unlock.phrases, {first: _phrase, id: other});
    expect(unlock.unreadable, isEmpty);
  }, skip: kernelSkip);

  test('wipe erases the vault and the throttle', () async {
    await keystore.createVault(phrase: _phrase, password: _password);
    await expectLater(keystore.unlock('bad bad bad'), throwsA(anything));
    await keystore.wipe();
    expect(await keystore.format(), VaultFormat.none);
    expect(store.values, isEmpty);
  }, skip: kernelSkip);

  test('a vault left by a deleted install is forgotten', () async {
    await keystore.createVault(phrase: _phrase, password: _password);
    expect(await keystore.forgetIfReinstalled(), isFalse);
    // iOS: SharedPreferences went with the app, the Keychain did not.
    SharedPreferences.setMockInitialValues({});
    final fresh = Keystore(secrets: store, runner: runInline);
    expect(await fresh.forgetIfReinstalled(), isTrue);
    expect(await fresh.format(), VaultFormat.none);
  }, skip: kernelSkip);

  test('the isolate runner opens what the inline one sealed', () async {
    final isolated = Keystore(secrets: store);
    final id = await isolated.createVault(phrase: _phrase, password: _password);
    expect((await isolated.unlock(_password)).phrases[id], _phrase);
  }, skip: kernelSkip);
}
