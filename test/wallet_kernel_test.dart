import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

import 'support/kernel.dart';

/// The app derives through the same kernel as the extension, from the same
/// chain document, so one phrase gives one set of addresses everywhere. The
/// expected values are zunia-core's CosmJS-generated golden vectors.
void main() {
  final vectors = jsonDecode(
    File('test/fixtures/registry-addresses.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final phrase = vectors['mnemonic'] as String;
  final catalog = [
    for (final row in jsonDecode(
      File('assets/chains/catalog.json').readAsStringSync(),
    ) as List<dynamic>)
      ChainEntry.fromJson(row as Map<String, dynamic>),
  ];

  test('every catalog chain derives the golden address', () {
    final cases = {
      for (final c in vectors['cases'] as List<dynamic>)
        (c as Map<String, dynamic>)['chain_id'] as String: c,
    };
    var checked = 0;
    for (final chain in catalog) {
      final expected = cases[chain.chainId];
      if (expected == null) continue;
      final account = WalletKernel.instance.deriveAddress(phrase: phrase, chain: chain);
      expect(account.address, expected['address'], reason: chain.chainId);
      expect(account.publicKeyHex, expected['pubkey_compressed_hex'], reason: chain.chainId);
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(240));
  }, skip: kernelSkip);

  test('extra accounts follow the extension: m/44\'/coin\'/0\'/0/index', () {
    final hub = catalog.firstWhere((c) => c.chainId == 'cosmoshub-4');
    final first = WalletKernel.instance.deriveAddress(phrase: phrase, chain: hub);
    final second = WalletKernel.instance.deriveAddress(phrase: phrase, chain: hub, accountIndex: 1);
    expect(first.path, "m/44'/118'/0'/0/0");
    expect(second.path, "m/44'/118'/0'/0/1");
    expect(second.address, isNot(first.address));
  }, skip: kernelSkip);

  test('Injective derives an Ethereum-style address', () {
    final inj = catalog.firstWhere((c) => c.chainId == 'injective-1');
    final account = WalletKernel.instance.deriveAddress(phrase: phrase, chain: inj);
    expect(account.address, startsWith('inj1'));
    expect(account.ethAddress, startsWith('0x'));
  }, skip: kernelSkip);

  test('the keyring envelope round-trips and refuses a wrong password', () {
    final sealed = WalletKernel.instance.sealKeyring(phrase: phrase, password: 'correct horse');
    expect(sealed, isNot(contains('abandon')));
    expect(
      WalletKernel.instance.openKeyring(envelopeJson: sealed, password: 'correct horse'),
      phrase,
    );
    expect(
      () => WalletKernel.instance.openKeyring(envelopeJson: sealed, password: 'wrong'),
      throwsA(anything),
    );
  }, skip: kernelSkip);

  test('validates the checksum', () {
    expect(WalletKernel.instance.validateMnemonic('abandon ' * 11 + 'abandon'), isFalse);
    expect(WalletKernel.instance.validateMnemonic(phrase), isTrue);
  });
}
