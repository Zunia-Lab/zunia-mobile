import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tx/tx_memo.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import '../support/catalog.dart';

/// The memo Zunia writes on a transaction the user left blank (extension
/// lib/__tests__/tx-memo.test.ts, 0.1.5). It is on chain for good, so a
/// token is named only when its identity is proven on the signing chain.
const me = 'cosmos1qyqszqgpqyqszqgpqyqszqgpqyqszqgpgq2rsw';
const tag = zuniaWalletTag;
const usdcNOnOsmosis = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const atomOnOsmosis = 'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2';
const unlisted = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
const xcs = 'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs';

TxMsg send(String denom) => TxMsg(TxMsg.sendType, {
      'from_address': me,
      'to_address': me,
      'amount': [
        {'denom': denom, 'amount': '1'},
      ],
    });

TxMsg transfer(String denom, [String memo = '']) => TxMsg(TxMsg.transferType, {
      'token': {'denom': denom, 'amount': '1'},
      'memo': memo,
    });

TxMsg swapCall(String sold, String bought, {List<Object?>? funds}) => TxMsg(TxMsg.executeContractType, {
      'contract': xcs,
      'msg': base64.encode(utf8.encode(jsonEncode({
        'osmosis_swap': {
          'output_denom': bought,
          'slippage': {
            'twap': {'slippage_percentage': '1', 'window_seconds': 10},
          },
          'receiver': 'cosmos1sender',
          'on_failed_delivery': {'local_recovery_addr': 'osmo1recovery'},
          'next_memo': null,
        },
      }))),
      'funds': funds ??
          [
            {'denom': sold, 'amount': '63000000'},
          ],
    });

TxMsg call(Object msg) => TxMsg(TxMsg.executeContractType, {
      'contract': xcs,
      'msg': base64.encode(utf8.encode(jsonEncode(msg))),
      'funds': const <Object?>[],
    });

void main() {
  setUpAll(loadBundledData);
  tearDown(() {
    ChainCatalog.instance.setCustom(const []);
    resetTokenIdentityState();
  });

  group('resolveTxMemo', () {
    test('keeps a user-written memo, trimmed', () {
      expect(resolveTxMemo(' rent ', [send('uatom')]), 'rent');
      expect(resolveTxMemo('  rent  ', [send('uusdc')], 'noble-1'), 'rent');
    });

    test('fills an empty memo with a Zunia default', () {
      final memo = resolveTxMemo('   ', [send('uatom')]);
      expect(memo, startsWith('Send'));
      expect(memo, endsWith(tag));
    });
  });

  group('defaultTxMemo', () {
    test('names a send, a stake and an IBC transfer', () {
      expect(defaultTxMemo([send('uatom')]), matches(RegExp(r'^Send .+ · by Zunia-wallet$')));
      expect(
        defaultTxMemo([
          TxMsg.delegate(
            delegator: me,
            validator: 'cosmosvaloper1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqnrql8a',
            amount: const TxCoin('uatom', '1'),
          ),
        ]),
        matches(RegExp(r'^Stake .+ · by Zunia-wallet$')),
      );
      expect(defaultTxMemo([transfer('uosmo')]), matches(RegExp(r'^IBC transfer .+ · by Zunia-wallet$')));
    });

    test('names a claim across several withdraw messages, and a vote', () {
      final claim = TxMsg.withdrawReward(
        delegator: me,
        validator: 'cosmosvaloper1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqnrql8a',
      );
      expect(defaultTxMemo([claim, claim]), 'Claim rewards · $tag');
      expect(defaultTxMemo([TxMsg.vote(voter: me, proposalId: '42', option: 1)]), 'Vote Yes on #42 · $tag');
      expect(
        defaultTxMemo([
          const TxMsg(TxMsg.voteType, {'proposal_id': '981', 'option': 'VOTE_OPTION_NO'}),
        ]),
        'Vote No on #981 · $tag',
      );
    });

    test('names a swap or a forward hop from the packet memo it reads', () {
      expect(
        defaultTxMemo([
          transfer(
            'uosmo',
            jsonEncode({
              'wasm': {
                'contract': 'osmo1x',
                'msg': {'osmosis_swap': <String, Object?>{}},
              },
            }),
          ),
        ]),
        matches(RegExp(r'^Swap .+ · by Zunia-wallet$')),
      );
      expect(
        defaultTxMemo([
          transfer(
            'uatom',
            jsonEncode({
              'forward': {'receiver': me, 'port': 'transfer', 'channel': 'channel-0'},
            }),
          ),
        ]),
        matches(RegExp(r'^IBC forward .+ · by Zunia-wallet$')),
      );
    });

    test('names an NFT transfer from the wasm action, and falls back for the rest', () {
      expect(
        defaultTxMemo([
          const TxMsg(TxMsg.executeContractType, {
            'msg': {
              'transfer_nft': {'recipient': me, 'token_id': '1'},
            },
          }),
        ]),
        'NFT transfer · $tag',
      );
      expect(defaultTxMemo([const TxMsg('/cosmos.unknown.v1.MsgNope', {})]), 'Signed · $tag');
      expect(defaultTxMemo(const []), 'Signed · $tag');
    });
  });

  group('chain-aware naming', () {
    test("names Noble's own USDC by the chain that signs: 'Send USDC.n'", () {
      expect(resolveTxMemo('', [send('uusdc')], 'noble-1'), 'Send USDC.n · $tag');
      expect(defaultTxMemo([transfer('uusdc')], 'noble-1'), 'IBC transfer USDC.n · $tag');
    });

    test('names a voucher on the chain that holds it, never by its base denom', () {
      expect(resolveTxMemo('', [transfer(usdcNOnOsmosis)], 'osmosis-1'), 'IBC transfer USDC.n · $tag');
      expect(
        resolveTxMemo('', [send('erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a')], 'injective-1'),
        'Send USDC.inj · $tag',
      );
    });

    test('writes the generic phrase for anything it cannot prove', () {
      expect(resolveTxMemo('', [transfer(unlisted)], 'osmosis-1'), 'IBC transfer · $tag');
      expect(
        resolveTxMemo('', [send('factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/USDC.n')], 'osmosis-1'),
        'Send · $tag',
      );
      expect(
        resolveTxMemo('', [send('erc20:0xa00c59ff5a080d2b954d0c75e46e22a0c371235a')], 'injective-1'),
        'Send · $tag',
      );
      expect(resolveTxMemo('', [send('transfer/channel-0/uatom')], 'osmosis-1'), 'Send · $tag');
      // A chain the user added is not evidence of what its coins are.
      ChainCatalog.instance.setCustom([
        customChain(chainId: 'mine-1', chainName: 'Mine', bech32Prefix: 'mine', coinDenom: 'USDC', coinMinimalDenom: 'umine'),
      ]);
      resetTokenIdentityState();
      expect(resolveTxMemo('', [send('umine')], 'mine-1'), 'Send · $tag');
    });

    test('names nothing a base denom cannot pin to one issuer when no chain is given', () {
      expect(resolveTxMemo('', [send('uusdc')]), 'Send · $tag');
      expect(resolveTxMemo('', [send('uluna')]), 'Send · $tag');
      expect(resolveTxMemo('', [transfer(usdcNOnOsmosis)]), 'IBC transfer · $tag');
    });
  });

  group('Earn and Governance memos', () {
    TxMsg stake(String type, String denom) => TxMsg(type, {
          'amount': {'denom': denom},
        });

    test('name the staking coin, with or without the chain', () {
      const cases = {
        'uatom': 'ATOM',
        'uosmo': 'OSMO',
        'inj': 'INJ',
        'uaxl': 'AXL',
        'utia': 'TIA',
        'untrn': 'NTRN',
        'ustrd': 'STRD',
        'ujuno': 'JUNO',
        'uakt': 'AKT',
        'adydx': 'DYDX',
        'ukuji': 'KUJI',
      };
      for (final MapEntry(key: denom, value: ticker) in cases.entries) {
        expect(resolveTxMemo('', [stake('cosmos-sdk/MsgDelegate', denom)]), 'Stake $ticker · $tag');
        expect(resolveTxMemo('', [stake('cosmos-sdk/MsgUndelegate', denom)]), 'Unstake $ticker · $tag');
        expect(resolveTxMemo('', [stake('cosmos-sdk/MsgBeginRedelegate', denom)]), 'Redelegate $ticker · $tag');
        final chainId = ChainCatalog.instance.registryOnly
            .firstWhere((entry) => entry.coinMinimalDenom == denom && entry.network == 'mainnet')
            .chainId;
        expect(resolveTxMemo('', [stake('cosmos-sdk/MsgDelegate', denom)], chainId), 'Stake $ticker · $tag');
      }
    });
  });

  group('the packet memo inside MsgTransfer', () {
    test('is read to choose the phrase and never written', () {
      const forward = '{"forward":{"receiver":"pfm","port":"transfer","channel":"channel-1"}}';
      final msg = transfer(usdcNOnOsmosis, forward);
      final before = jsonEncode(msg.toJson());
      expect(resolveTxMemo('', [msg], 'osmosis-1'), 'IBC forward USDC.n · $tag');
      expect(jsonEncode(msg.toJson()), before);
    });
  });

  group('a swap signed as one contract call on Osmosis', () {
    test("names both tokens as Osmosis holds them: 'Swap OSMO to ATOM'", () {
      expect(resolveTxMemo('', [swapCall('uosmo', atomOnOsmosis)], 'osmosis-1'), 'Swap OSMO to ATOM · $tag');
      expect(resolveTxMemo('', [swapCall(usdcNOnOsmosis, 'uosmo')], 'osmosis-1'), 'Swap USDC.n to OSMO · $tag');
      expect(resolveTxMemo(' mine ', [swapCall('uosmo', atomOnOsmosis)], 'osmosis-1'), 'mine');
    });

    test('keeps the generic text unless both tokens are proven', () {
      const generic = 'Contract call · $tag';
      expect(resolveTxMemo('', [swapCall('uosmo', unlisted)], 'osmosis-1'), generic);
      expect(resolveTxMemo('', [swapCall(unlisted, atomOnOsmosis)], 'osmosis-1'), generic);
      expect(
        resolveTxMemo('', [swapCall('factory/osmo1qyqszqgpqyqszqgpqyqszqgpqyqszqgpjnp7du/USDC.n', 'uosmo')],
            'osmosis-1'),
        generic,
      );
      expect(resolveTxMemo('', [swapCall('uosmo', atomOnOsmosis)]), generic);
      expect(resolveTxMemo('', [swapCall('uosmo', atomOnOsmosis, funds: const [])], 'osmosis-1'), generic);
      expect(
        resolveTxMemo(
          '',
          [
            swapCall('uosmo', atomOnOsmosis, funds: const [
              {'denom': 'uosmo', 'amount': '1'},
              {'denom': usdcNOnOsmosis, 'amount': '1'},
            ]),
          ],
          'osmosis-1',
        ),
        generic,
      );
      expect(resolveTxMemo('', [call({'recover': <String, Object?>{}})], 'osmosis-1'), 'Recover funds · $tag');
      expect(
        resolveTxMemo('', [call({'osmosis_swap': <String, Object?>{}, 'recover': <String, Object?>{}})], 'osmosis-1'),
        generic,
      );
      expect(resolveTxMemo('', [call({'set_route': <String, Object?>{}})], 'osmosis-1'), generic);
    });

    test('caps a long phrase at 256 characters and keeps the tag', () {
      final memo = defaultTxMemo([TxMsg(TxMsg.voteType, {'proposal_id': '9' * 300, 'option': 1})]);
      expect(memo.length, 256);
      expect(memo, endsWith('… · $tag'));
    });
  });
}
