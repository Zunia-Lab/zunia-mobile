/// The messages each swap path builds are messages the kernel signs: it reads
/// the snake_case JSON (zunia-core `crates/cosmos/src/json.rs`), describes
/// each one in the preview the confirm card shows, and its sign bytes are the
/// ones that preview hashes. Needs the host kernel; skipped without it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_core/zunia_core.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_review.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import 'support/kernel.dart';
import 'support/swap_fixtures.dart';

const usdcInj =
    'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const xcs = 'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs';

void main() {
  final phrase =
      (jsonDecode(
                File(
                  'test/fixtures/registry-addresses.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>)['mnemonic']
          as String;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ChainCatalog.load();
  });

  ZuniaSigningPreview preview(
    String chainId,
    List<TxMsg> msgs, {
    String memo = '',
  }) {
    final chain = ChainCatalog.instance.find(chainId)!;
    final account = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: chain,
    );
    return WalletKernel.instance.core.previewTx(
      chainId: chainId,
      msgs: [for (final m in msgs) m.toJson()],
      fee: const ZuniaFee(
        amount: [ZuniaCoin(denom: 'uosmo', amount: '5000')],
        gasLimit: 400000,
      ),
      memo: memo,
      accountNumber: 1,
      sequence: 0,
      publicKeyHex: account.publicKeyHex,
      ethKeyType: chain.usesEthKeySign,
      mode: ZuniaSignMode.direct,
    );
  }

  String me(String chainId) => WalletKernel.instance
      .deriveAddress(
        phrase: phrase,
        chain: ChainCatalog.instance.find(chainId)!,
      )
      .address;

  test(
    'a split pool swap, its fee and the transfer that delivers it are three messages the kernel describes',
    () {
      final sender = me('osmosis-1');
      final msgs = poolSwapTxMsgs(
        sender: sender,
        denom: 'uosmo',
        routes: const [
          PoolRoute([PoolHop('3498', usdcInj)], '5970000'),
          PoolRoute([PoolHop('3586', usdcInj)], '3980000'),
        ],
        minOut: '351087',
        fee: SwapFee(
          bps: 50,
          fee: BigInt.from(50000),
          net: BigInt.from(9950000),
          recipient: bech('osmo', 0x5a),
        ),
        delivery: const PoolDelivery(
          sourceChannel: 'channel-122',
          destChainId: 'injective-1',
          arrivalDenom: 'x',
        ),
        recipient: bech('inj', 7),
        timeoutMinutes: 10,
        now: DateTime(2026, 10, 18, 12),
      );
      final read = preview(
        'osmosis-1',
        msgs,
        memo: 'Swap OSMO to USDC.inj · by Zunia-wallet',
      );
      expect(read.summaries, hasLength(3));
      expect(
        read.summaries[0],
        startsWith('Swap 9950000 uosmo for at least 351087'),
      );
      expect(read.summaries[0], contains('2 routes'));
      expect(read.summaries[1].toLowerCase(), contains('50000'));
      expect(read.summaries[2].toLowerCase(), contains('channel-122'));
      expect(read.memo, 'Swap OSMO to USDC.inj · by Zunia-wallet');
    },
    skip: kernelSkip,
  );

  test('a single-route pool swap reads as one route', () {
    final msg = buildPoolSwapMsg(
      sender: me('osmosis-1'),
      denom: 'uosmo',
      routes: const [
        PoolRoute([
          PoolHop(
            '1',
            'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2',
          ),
        ], '1000000'),
      ],
      minOut: '400000',
    );
    final read = preview('osmosis-1', [msg]);
    expect(
      read.summaries.single,
      startsWith('Swap 1000000 uosmo for at least 400000'),
    );
    expect(read.summaries.single, contains('pool 1'));
  }, skip: kernelSkip);

  test(
    'the crosschain-swaps transfer and its fee sign on the source chain',
    () {
      final sender = me('cosmoshub-4');
      final memo = jsonEncode(
        buildXcsSwapMemoJson(
          contract: xcs,
          outputDenom: 'uosmo',
          receiver: me('osmosis-1'),
          slippage: const XcsTwapSlippage(slippagePercentage: '1'),
          onFailedDelivery: XcsLocalRecovery(me('osmosis-1')),
        ),
      );
      final plan = RoutePlan(
        sourceChainId: 'cosmoshub-4',
        destChainId: 'osmosis-1',
        inputDenom: 'uatom',
        outputDenom: 'uosmo',
        hops: const [
          RouteHop(
            chainId: 'cosmoshub-4',
            channelId: 'channel-141',
            port: 'transfer',
            counterpartyChainId: 'osmosis-1',
            kind: RouteHopKind.transfer,
          ),
          RouteHop(
            chainId: 'osmosis-1',
            channelId: '',
            port: '',
            counterpartyChainId: 'osmosis-1',
            kind: RouteHopKind.swap,
          ),
        ],
        memo: memo,
        warnings: const [],
        estimatedDurationSeconds: 75,
        requiresPfm: false,
        requiresIbcHooks: true,
      );
      final msgs = swapTxMsgs(
        plan: plan,
        receiver: xcs,
        sender: sender,
        denom: 'uatom',
        fee: SwapFee(
          bps: 50,
          fee: BigInt.from(5000),
          net: BigInt.from(995000),
          recipient: bech('cosmos', 0x5a),
        ),
        timeoutMinutes: 10,
        now: DateTime.now(),
      );
      final read = WalletKernel.instance.core.previewTx(
        chainId: 'cosmoshub-4',
        msgs: [for (final m in msgs) m.toJson()],
        fee: const ZuniaFee(
          amount: [ZuniaCoin(denom: 'uatom', amount: '5000')],
          gasLimit: 200000,
        ),
        memo: 'Swap ATOM · by Zunia-wallet',
        accountNumber: 1,
        sequence: 0,
        publicKeyHex: WalletKernel.instance
            .deriveAddress(
              phrase: phrase,
              chain: ChainCatalog.instance.find('cosmoshub-4')!,
            )
            .publicKeyHex,
        ethKeyType: false,
        mode: ZuniaSignMode.direct,
      );
      expect(read.summaries, hasLength(2));
      expect(read.summaries[0].toLowerCase(), contains('995000'));
      expect(read.summaries[1].toLowerCase(), contains('5000'));
    },
    skip: kernelSkip,
  );
}
