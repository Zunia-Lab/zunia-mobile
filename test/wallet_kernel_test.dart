import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

/// The Dart fallback must agree with the Rust kernel's golden vectors in
/// `zunia-core/tests/vectors/registry-addresses.json`, otherwise a build
/// without the native library would show different addresses.
void main() {
  const phrase =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  const cosmoshub = ChainEntry(
    chainId: 'cosmoshub-4',
    chainName: 'Cosmos Hub',
    bech32Prefix: 'cosmos',
    coinType: 118,
    network: 'mainnet',
    coinDenom: 'ATOM',
    coinMinimalDenom: 'uatom',
    coinDecimals: 6,
    feeDenom: 'ATOM',
    feeMinimalDenom: 'uatom',
    feeDecimals: 6,
  );

  const osmosis = ChainEntry(
    chainId: 'osmosis-1',
    chainName: 'Osmosis',
    bech32Prefix: 'osmo',
    coinType: 118,
    network: 'mainnet',
    coinDenom: 'OSMO',
    coinMinimalDenom: 'uosmo',
    coinDecimals: 6,
    feeDenom: 'OSMO',
    feeMinimalDenom: 'uosmo',
    feeDecimals: 6,
  );

  test('derives the canonical cosmos hub vector', () {
    final account = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: cosmoshub,
    );
    expect(account.address, 'cosmos19rl4cm2hmr8afy4kldpxz3fka4jguq0auqdal4');
    expect(account.path, "m/44'/118'/0'/0/0");
    expect(account.publicKey, hasLength(33));
  });

  test('re-prefixes the same key per chain', () {
    final account = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: osmosis,
    );
    expect(account.address.startsWith('osmo1'), isTrue);
    expect(account.address.contains('qqqqqq'), isFalse);
  });

  test('derives a distinct address per account index', () {
    final first = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: cosmoshub,
    );
    final second = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: cosmoshub,
      accountIndex: 1,
    );
    expect(second.path, "m/44'/118'/1'/0/0");
    expect(second.address, isNot(first.address));
  });

  test('rejects a mnemonic with a bad checksum', () {
    expect(
      WalletKernel.instance.validateMnemonic('abandon ' * 11 + 'abandon'),
      isFalse,
    );
    expect(WalletKernel.instance.validateMnemonic(phrase), isTrue);
  });
}
