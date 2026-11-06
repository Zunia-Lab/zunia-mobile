/// An Injective send was quoted 3689348814742 inj when the chain wanted at
/// least 6.4e13: the fee scaled a 1.5e9 gas price into a 64-bit `int`, which
/// clamps. Its simulation was refused too, because it carried Ethermint's key
/// type, which Injective does not decode. These pin both, and the same key
/// rule for the cosmos/evm and Initia chains.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/tx/gas_fee.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';

import '../support/kernel.dart';

const ethermint = '/ethermint.crypto.v1.ethsecp256k1.PubKey';

BigInt n(Object value) => BigInt.parse('$value');

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ChainCatalog.load();
  });

  ChainEntry chain(String id) => ChainCatalog.instance.find(id)!;

  group('gasFee', () {
    test('an 18-decimal gas price does not overflow', () {
      // Injective "high", 400000 gas: the fee the screenshot should have shown.
      expect(gasFee(n(400000), 1.5e9), n('600000000000000'));
      expect(gasFee(n(400000), 1.6e8), n('64000000000000'));
      // Evmos, 80 gwei per gas.
      expect(gasFee(n(400000), 8e10), n('32000000000000000'));
      // Far beyond 2^63 once scaled, still exact.
      expect(gasFee(n('1000000000'), 1e21), n('1000000000000000000000000000000'));
    });

    test('rounds up, reading the price as the decimal it prints as', () {
      expect(gasFee(n(200000), 0.0025), n(500));
      expect(gasFee(n(123457), 0.025), n(3087)); // 3086.425
      expect(gasFee(n(3), 0.1), n(1)); // 0.3, not 0.30000000000000004
      expect(gasFee(n(10), 0.1), n(1));
      expect(gasFee(n(7), 8e-7), n(1));
    });

    test('nothing to pay for a free, broken or empty price', () {
      expect(gasFee(n(400000), 0), BigInt.zero);
      expect(gasFee(n(400000), -1), BigInt.zero);
      expect(gasFee(n(400000), double.nan), BigInt.zero);
      expect(gasFee(n(400000), double.infinity), BigInt.zero);
      expect(gasFee(BigInt.zero, 0.025), BigInt.zero);
    });

    test('decimalFraction spells exponents out', () {
      expect(decimalFraction(1500000000.0), (n('1500000000'), BigInt.one));
      expect(decimalFraction(0.025), (n(25), n(1000)));
      expect(decimalFraction(8e-7), (n(8), n(10000000)));
      expect(decimalFraction(1e21), (n('1000000000000000000000'), BigInt.one));
    });
  });

  group('fees on Injective', () {
    test('every speed is at or above the chain minimum', () {
      final injective = chain('injective-1');
      const minimum = 160000000; // inj per gas, Injective's floor
      for (final speed in FeeSpeed.values) {
        final fee = TxEngine.feeFor(injective, fallbackGasLimit, speed);
        expect(fee.amount.single.denom, 'inj');
        expect(
          BigInt.parse(fee.amount.single.amount),
          greaterThanOrEqualTo(BigInt.from(fallbackGasLimit) * BigInt.from(minimum)),
          reason: speed.name,
        );
      }
      expect(
        TxEngine.feeFor(injective, fallbackGasLimit, FeeSpeed.high).amount.single.amount,
        '600000000000000',
      );
    });

    test('the Amino estimate is exact too', () {
      final fee = estimateFee(gasLimit: 400000, gasPrice: 1.5e9, denom: 'inj');
      expect(fee.amount.single.amount, '600000000000000');
      expect(estimateFee(gasLimit: 1, gasPrice: 0.000001, denom: 'uatom').amount.single.amount, '1');
    });
  });

  group('ethKeyTypeUrl', () {
    test('follows the catalog, then Injective, then the Keplr flags', () {
      expect(chain('injective-1').ethKeyTypeUrl, injectivePubKeyTypeUrl);
      expect(chain('kiichain_1783-1').ethKeyTypeUrl, cosmosEvmPubKeyTypeUrl);
      expect(chain('nvnm-1').ethKeyTypeUrl, cosmosEvmPubKeyTypeUrl);
      expect(chain('1919').ethKeyTypeUrl, cosmosEvmPubKeyTypeUrl);
      expect(chain('interwoven-1').ethKeyTypeUrl, initiaPubKeyTypeUrl);
      // Ethermint chains and plain Cosmos chains keep the kernel's default.
      expect(chain('evmos_9001-2').ethKeyTypeUrl, isNull);
      expect(chain('dymension_1100-1').ethKeyTypeUrl, isNull);
      expect(chain('cosmoshub-4').ethKeyTypeUrl, isNull);
    });

    test('reaches the chain document the kernel signs with', () {
      String? sent(String id) =>
          (jsonDecode(chain(id).toChainJson()) as Map<String, dynamic>)['ethPubKeyTypeUrl'] as String?;
      expect(sent('injective-1'), injectivePubKeyTypeUrl);
      expect(sent('kiichain_1783-1'), cosmosEvmPubKeyTypeUrl);
      expect(sent('interwoven-1'), initiaPubKeyTypeUrl);
      expect(sent('evmos_9001-2'), isNull);
    });
  });

  group('kernel', () {
    String hexOf(String text) =>
        utf8.encode(text).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test(
      'the simulation, the preview and the sign bytes carry the chain key type',
      () {
        final injective = chain('injective-1');
        final core = WalletKernel.instance.core;
        final msgs = [
          {
            'typeUrl': '/cosmos.bank.v1beta1.MsgSend',
            'value': {
              'from_address': 'inj1c5zpdj9eq35xuv0rkyt6tulzphpsvpc7um2pk7',
              'to_address': 'inj1c5zpdj9eq35xuv0rkyt6tulzphpsvpc7um2pk7',
              'amount': [
                {'denom': 'inj', 'amount': '160000000000000000'},
              ],
            },
          },
        ];
        const pubkey = '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
        final fee = TxEngine.feeFor(injective, fallbackGasLimit, FeeSpeed.high);

        final simulate = core.buildSimulateTx(
          chainId: injective.chainId,
          msgs: msgs,
          fee: ZuniaFee(amount: const [], gasLimit: fallbackGasLimit),
          accountNumber: 1,
          sequence: 0,
          publicKeyHex: pubkey,
          ethKeyType: injective.usesEthKeySign,
          ethPubKeyTypeUrl: injective.ethKeyTypeUrl,
        );
        expect(simulate, contains(hexOf(injectivePubKeyTypeUrl)));
        expect(simulate, isNot(contains(hexOf(ethermint))));

        final signBytes = core.buildSignBytes(
          chainId: injective.chainId,
          msgs: msgs,
          fee: fee,
          accountNumber: 1,
          sequence: 0,
          publicKeyHex: pubkey,
          ethKeyType: injective.usesEthKeySign,
          ethPubKeyTypeUrl: injective.ethKeyTypeUrl,
          mode: ZuniaSignMode.direct,
        );
        expect(signBytes, contains(hexOf(injectivePubKeyTypeUrl)));

        final preview = core.previewTx(
          chainId: injective.chainId,
          msgs: msgs,
          fee: fee,
          accountNumber: 1,
          sequence: 0,
          publicKeyHex: pubkey,
          ethKeyType: injective.usesEthKeySign,
          ethPubKeyTypeUrl: injective.ethKeyTypeUrl,
          mode: ZuniaSignMode.direct,
        );
        // The review screen hashes the very bytes about to be signed.
        expect(
          preview.signBytesHash.toLowerCase().replaceFirst('0x', ''),
          sha256.convert(_bytes(signBytes)).toString(),
        );
      },
      skip: kernelSkip,
    );
  });
}
