/// The whole swap pipeline, offline: the lists, the path each pair takes, the
/// fee, the plan and price, and the exact messages each path signs.
///
/// Real bundled data (catalog, token table, swap-fee.json, interchain.json)
/// and the contract's real route table; every chain endpoint and the SQS
/// router are scripted, so nothing here touches the network.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_data.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_review.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

import 'support/swap_fixtures.dart';
import 'support/swap_world.dart';

void main() {
  setUpAll(loadSwapWorld);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the lists', () {
    test(
      'sell what is held, one row per chain and exact denom, named by identity',
      () async {
        final view = await settle(world());
        expect(view.sources.map((a) => a.key), [
          'cosmoshub-4:uatom',
          'osmosis-1:uosmo',
        ]);
        expect(view.sources.first.ticker, 'ATOM');
        expect(view.sources.first.held, isTrue);
      },
    );

    test(
      'buy held tokens, chain coins, Osmosis tokens and their homes, the From itself refused',
      () async {
        final view = await settle(world());
        final keys = view.destinations.map((a) => a.key).toSet();
        expect(keys, contains('osmosis-1:uosmo'));
        expect(keys, contains('osmosis-1:$usdcInj'));
        // USDC.inj delivered home to Injective, as its exact erc20 denom.
        expect(keys, contains('injective-1:$usdcInjOrigin'));
        final self = view.destinations.firstWhere(
          (a) => a.key == 'cosmoshub-4:uatom',
        );
        expect(self.disabledReason, selfReason);
        expect(self.searchOnly, isTrue);
        // ATOM on Osmosis is the same asset: Send moves it.
        final voucher = view.destinations.firstWhere(
          (a) => a.key == 'osmosis-1:$atomOnOsmosis',
        );
        expect(voucher.disabledReason, sameTokenReason);
      },
    );
  });

  group('which way each pair goes', () {
    Future<SwapView> pick(ProviderContainer c, String from, String to) async {
      await settle(c);
      c.read(swapControllerProvider.notifier)
        ..pickFrom(from)
        ..pickTo(to);
      return c.read(swapViewProvider);
    }

    test(
      'funds elsewhere go through the contract when its table has the pair',
      () async {
        final view = await pick(
          world(),
          'cosmoshub-4:uatom',
          'osmosis-1:uosmo',
        );
        expect(view.to!.executable, Executable.yes);
        expect(view.path, SwapPath.contract);
      },
    );

    test(
      'funds elsewhere move to Osmosis first when the contract cannot swap the pair',
      () async {
        final view = await pick(
          world(),
          'cosmoshub-4:uatom',
          'osmosis-1:$usdcInj',
        );
        expect(view.to!.executable, Executable.no);
        expect(view.path, SwapPath.moveFirst);
      },
    );

    test(
      'funds on Osmosis swap in the pools, or through the contract when it delivers elsewhere',
      () async {
        expect(
          (await pick(world(), 'osmosis-1:uosmo', 'osmosis-1:$usdcInj')).path,
          SwapPath.pool,
        );
        expect(
          (await pick(world(), 'osmosis-1:uosmo', 'cosmoshub-4:uatom')).path,
          SwapPath.contract,
        );
        expect(
          (await pick(
            world(),
            'osmosis-1:uosmo',
            'injective-1:$usdcInjOrigin',
          )).path,
          SwapPath.poolDeliver,
        );
        // Without a table nothing is known: funds on Osmosis use the pools.
        expect(
          (await pick(
            world(tableGiven: false),
            'osmosis-1:uosmo',
            'cosmoshub-4:uatom',
          )).path,
          SwapPath.poolDeliver,
        );
      },
    );
  });

  group('the form', () {
    test('says what to do next, one thing at a time', () async {
      final c = world();
      await settle(c);
      final controller = c.read(swapControllerProvider.notifier)
        ..pickFrom('osmosis-1:uosmo')
        ..pickTo('osmosis-1:$usdcInj');
      var view = c.read(swapViewProvider);
      expect(view.blockedReason, 'Enter an amount to swap.');
      controller.setAmount('0', view.from!);
      expect(
        c.read(swapViewProvider).blockedReason,
        'Enter an amount above zero.',
      );
      controller.setAmount('1.0000001', view.from!);
      expect(
        c.read(swapViewProvider).blockedReason,
        'That amount is not a number this chain can hold.',
      );
      controller.setAmount('50', view.from!);
      expect(
        c.read(swapViewProvider).blockedReason,
        'More than the OSMO left after the network fee.',
      );
      controller.setAmount('10', view.from!);
      view = c.read(swapViewProvider);
      expect(view.blockedReason, isNull);
      expect(view.planning, isTrue);
      expect(view.planKey, isNotEmpty);
    });

    test(
      'charges 0.5% of the amount typed, in the token sold, to the signing chain\'s treasury',
      () async {
        final c = world();
        await settle(c);
        c.read(swapControllerProvider.notifier)
          ..pickFrom('cosmoshub-4:uatom')
          ..pickTo('osmosis-1:uosmo');
        c
            .read(swapControllerProvider.notifier)
            .setAmount('1', c.read(swapViewProvider).from!);
        final view = c.read(swapViewProvider);
        expect(view.amountUnits, BigInt.from(1000000));
        expect(
          view.fee,
          SwapFee(
            bps: 50,
            fee: BigInt.from(5000),
            net: BigInt.from(995000),
            recipient: data.fees.recipients['cosmoshub-4'],
          ),
        );
        expect(swapFeeLine(view.fee, view.from!.identity), (
          label: 'Zunia fee',
          value: '0.5% · 0.005 ATOM',
        ));
      },
    );

    test(
      'reads a typed amount only with the exponent it was typed for',
      () async {
        final c = world();
        await settle(c);
        final controller = c.read(swapControllerProvider.notifier)
          ..pickFrom('cosmoshub-4:uatom');
        controller.setAmount('2', c.read(swapViewProvider).from!);
        expect(c.read(swapViewProvider).amountUnits, BigInt.from(2000000));
        controller.pickFrom('osmosis-1:uosmo');
        expect(c.read(swapViewProvider).amountText, '');
        expect(c.read(swapViewProvider).amountUnits, isNull);
      },
    );

    test(
      'Max leaves room for the network fee when it is paid in the token sold',
      () async {
        final c = world();
        final view = await settle(c);
        c.read(swapControllerProvider.notifier).applyMax(view);
        final after = c.read(swapViewProvider);
        expect(after.amountUnits, after.spendable);
        expect(after.spendable! < BigInt.from(10000000), isTrue);
        expect(after.overBalance, isFalse);
      },
    );

    test('only a held To can become the From', () async {
      final c = world();
      await settle(c);
      final controller = c.read(swapControllerProvider.notifier)
        ..pickFrom('cosmoshub-4:uatom')
        ..pickTo('osmosis-1:$usdcInj');
      expect(controller.flip(c.read(swapViewProvider)), isFalse);
      controller.pickTo('osmosis-1:uosmo');
      expect(controller.flip(c.read(swapViewProvider)), isTrue);
      expect(c.read(swapViewProvider).from!.key, 'osmosis-1:uosmo');
      expect(c.read(swapViewProvider).to!.key, 'cosmoshub-4:uatom');
    });

    test(
      'a contract that cannot be confirmed blocks the contract path, never the pools',
      () async {
        final off = const SwapVenueStatus.unavailable(
          'No crosschain-swaps contract this release names exists on Osmosis.',
        );
        final c = world(venue: off, tableGiven: false);
        await settle(c);
        final controller = c.read(swapControllerProvider.notifier)
          ..pickFrom('cosmoshub-4:uatom')
          ..pickTo('osmosis-1:uosmo');
        controller.setAmount('1', c.read(swapViewProvider).from!);
        expect(c.read(swapViewProvider).blockedReason, off.reason);
        expect(c.read(swapViewProvider).planKey, isEmpty);
        controller
          ..pickFrom('osmosis-1:uosmo')
          ..pickTo('osmosis-1:$usdcInj');
        controller.setAmount('1', c.read(swapViewProvider).from!);
        expect(c.read(swapViewProvider).blockedReason, isNull);
        expect(c.read(swapViewProvider).planKey, isNotEmpty);
      },
    );

    test(
      'slippage outside 0 to 50% is refused before anything is planned',
      () async {
        final c = world();
        await settle(c);
        await c
            .read(swapSettingsProvider.notifier)
            .update(const SwapSettings(slippagePercent: 60));
        final controller = c.read(swapControllerProvider.notifier)
          ..pickFrom('osmosis-1:uosmo')
          ..pickTo('osmosis-1:$usdcInj');
        controller.setAmount('1', c.read(swapViewProvider).from!);
        expect(
          c.read(swapViewProvider).blockedReason,
          contains('Slippage must be between 0 and 50%'),
        );
      },
    );
  });

  group('what each path signs', () {
    test(
      'pool: [poolmanager swap of what is left after the fee, fee]',
      () async {
        final c = world();
        final view = await plan(
          c,
          from: 'osmosis-1:uosmo',
          to: 'osmosis-1:$usdcInj',
          amount: '10',
        );
        expect(view.ready, isTrue, reason: view.blockedReason ?? '');
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        final msgs = prepared.msgs;
        expect(msgs.map((m) => m.typeUrl), [
          poolSplitSwapTypeUrl,
          bankSendTypeUrl,
        ]);
        expect(msgs[0].value['token_in_denom'], 'uosmo');
        expect(msgs[0].value['sender'], osmoMe);
        // 10 OSMO typed: 0.05 OSMO fee, 9.95 OSMO swapped; floor 1% under 4.975.
        final sold = (msgs[0].value['routes'] as List).fold<BigInt>(
          BigInt.zero,
          (sum, r) =>
              sum + BigInt.parse((r as Map)['token_in_amount'] as String),
        );
        expect(sold, BigInt.from(9950000));
        expect(msgs[0].value['token_out_min_amount'], '4925250');
        expect(msgs[1].value, {
          'from_address': osmoMe,
          'to_address': data.fees.recipients['osmosis-1'],
          'amount': [
            {'denom': 'uosmo', 'amount': '50000'},
          ],
        });
        expect(prepared.memo, 'Swap OSMO to USDC.inj · by Zunia-wallet');
        expect(
          reviewProblems(
            prepared.review,
            msgs: msgs,
            chainId: 'osmosis-1',
            policy: data.fees,
            book: data.book,
            now: DateTime.now(),
            venueChainId: 'osmosis-1',
          ),
          isEmpty,
        );
      },
    );

    test(
      'pool-deliver: [swap, fee, transfer of exactly the floor home to Injective]',
      () async {
        final c = world(
          enabled: const ['cosmoshub-4', 'osmosis-1', 'injective-1'],
        );
        final view = await plan(
          c,
          from: 'osmosis-1:uosmo',
          to: 'injective-1:$usdcInjOrigin',
          amount: '10',
        );
        expect(view.path, SwapPath.poolDeliver);
        expect(view.ready, isTrue, reason: view.blockedReason ?? '');
        expect(view.delivery?.sourceChannel, 'channel-122');
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        final msgs = prepared.msgs;
        expect(msgs.map((m) => m.typeUrl), [
          poolSplitSwapTypeUrl,
          bankSendTypeUrl,
          transferTypeUrl,
        ]);
        final floor = msgs[0].value['token_out_min_amount'];
        expect(msgs[2].value['token'], {'denom': usdcInj, 'amount': floor});
        expect(msgs[2].value['source_channel'], 'channel-122');
        expect(msgs[2].value['receiver'], injMe);
        expect(msgs[2].value['sender'], osmoMe);
        expect(msgs[2].value.containsKey('memo'), isFalse);
        expect(
          reviewProblems(
            prepared.review,
            msgs: msgs,
            chainId: 'osmosis-1',
            policy: data.fees,
            book: data.book,
            now: DateTime.now(),
            venueChainId: 'osmosis-1',
          ),
          isEmpty,
        );
      },
    );

    test(
      'contract from another chain: [MsgTransfer to the contract with the swap memo, fee on that chain]',
      () async {
        final c = world();
        final view = await plan(
          c,
          from: 'cosmoshub-4:uatom',
          to: 'osmosis-1:uosmo',
          amount: '1',
        );
        expect(
          view.ready,
          isTrue,
          reason: view.blockedReason ?? view.contract?.error ?? '',
        );
        expect(view.contract!.venueInputDenom, atomOnOsmosis);
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        final msgs = prepared.msgs;
        expect(msgs.map((m) => m.typeUrl), [transferTypeUrl, bankSendTypeUrl]);
        final transfer = msgs[0].value;
        expect(transfer['source_channel'], 'channel-141');
        expect(transfer['token'], {'denom': 'uatom', 'amount': '995000'});
        // ibc-hooks runs only when the ICS20 receiver is the contract.
        expect(transfer['receiver'], xcs);
        final memo =
            jsonDecode(transfer['memo'] as String) as Map<String, Object?>;
        final swap =
            ((memo['wasm']! as Map)['msg']! as Map)['osmosis_swap']! as Map;
        expect(swap['output_denom'], 'uosmo');
        expect(swap['receiver'], osmoMe);
        expect(swap['on_failed_delivery'], {'local_recovery_addr': osmoMe});
        expect(swap['slippage'], {
          'twap': {'slippage_percentage': '1'},
        });
        expect(
          msgs[1].value['to_address'],
          data.fees.recipients['cosmoshub-4'],
        );
        expect(msgs[1].value['amount'], [
          {'denom': 'uatom', 'amount': '5000'},
        ]);
        expect(prepared.memo, 'Swap ATOM · by Zunia-wallet');
        // The quote was asked along the contract's own route (pool 1).
        expect(view.quote!.route.single.poolId, '1');
        expect(
          reviewProblems(
            prepared.review,
            msgs: msgs,
            chainId: 'cosmoshub-4',
            policy: data.fees,
            book: data.book,
            now: DateTime.now(),
            venueChainId: 'osmosis-1',
          ),
          isEmpty,
        );
      },
    );

    test(
      'contract from Osmosis: [MsgExecuteContract osmosis_swap with the coin attached, fee]',
      () async {
        final c = world();
        final view = await plan(
          c,
          from: 'osmosis-1:uosmo',
          to: 'cosmoshub-4:uatom',
          amount: '10',
        );
        expect(view.path, SwapPath.contract);
        expect(
          view.ready,
          isTrue,
          reason: view.blockedReason ?? view.contract?.error ?? '',
        );
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        final msgs = prepared.msgs;
        expect(msgs.map((m) => m.typeUrl), [
          executeContractTypeUrl,
          bankSendTypeUrl,
        ]);
        expect(msgs[0].value['contract'], xcs);
        expect(msgs[0].value['funds'], [
          {'denom': 'uosmo', 'amount': '9950000'},
        ]);
        final body =
            jsonDecode(
                  utf8.decode(base64.decode(msgs[0].value['msg'] as String)),
                )
                as Map;
        final swap = body['osmosis_swap'] as Map;
        expect(swap['output_denom'], atomOnOsmosis);
        expect(swap['receiver'], hubMe);
        expect(prepared.memo, 'Swap OSMO to ATOM · by Zunia-wallet');
        final facts = readSwapMessage(msgs[0])!;
        expect(facts.contractCall, isTrue);
        expect(facts.sold.amount, '9950000');
      },
    );

    test(
      'no treasury on the signing chain: the swap alone, byte for byte what it was before the fee',
      () async {
        final noFee = SwapData(
          config: data.config,
          fees: SwapFeePolicy(bps: 50, recipients: const {}),
          book: data.book,
          catalog: data.catalog,
        );
        final c = world(swapData: noFee);
        final view = await plan(
          c,
          from: 'cosmoshub-4:uatom',
          to: 'osmosis-1:uosmo',
          amount: '1',
        );
        expect(view.fee!.charged, isFalse);
        final at = DateTime(2026, 10, 18, 12);
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view, now: at);
        expect(prepared.msgs, hasLength(1));
        final bare = buildContractSwapMsg(
          plan: view.contract!.plan!,
          receiver: view.contract!.receiver!,
          sender: hubMe,
          amount: '1000000',
          timeoutMinutes: data.config.packetTimeoutMinutes,
          now: at,
        );
        expect(
          jsonEncode(prepared.msgs.single.toJson()),
          jsonEncode(bare.toJson()),
        );
      },
    );
  });

  group('the review stands only while nothing moves', () {
    test(
      'the Sign button reads Out of date once the form changes, and Price expired after the TTL',
      () async {
        final c = world();
        final view = await plan(
          c,
          from: 'osmosis-1:uosmo',
          to: 'osmosis-1:$usdcInj',
          amount: '10',
        );
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        final review = prepared.review;
        final ttl = data.config.quoteTtl;
        ({String label, String reason})? block(DateTime now) => swapSignBlock(
          problem: null,
          drift: reviewDrift(review, c.read(swapViewProvider).live),
          price: review.price,
          refreshing: false,
          now: now,
          ttl: ttl,
          feeShort: false,
        );
        expect(block(DateTime.now()), isNull);
        expect(block(review.price.at.add(ttl))?.label, 'Price expired');
        // The user edits the amount under the review.
        c.read(swapControllerProvider.notifier).setAmount('11', view.from!);
        final moved = block(DateTime.now());
        expect(moved?.label, 'Out of date');
        expect(moved?.reason, contains('no longer 10 OSMO'));
      },
    );

    test(
      'a fee the review did not show, a changed amount or an extra message is refused',
      () async {
        final c = world();
        final view = await plan(
          c,
          from: 'osmosis-1:uosmo',
          to: 'osmosis-1:$usdcInj',
          amount: '10',
        );
        final prepared = await c
            .read(swapControllerProvider.notifier)
            .prepareReview(view);
        List<String> problems(List<TxMsg> msgs) => reviewProblems(
          prepared.review,
          msgs: msgs,
          chainId: 'osmosis-1',
          policy: data.fees,
          book: data.book,
          now: DateTime.now(),
          venueChainId: 'osmosis-1',
        );
        final swap = prepared.msgs[0];
        final elsewhere = buildSwapFeeMsg(
          sender: osmoMe,
          recipient: bech('osmo', 9),
          denom: 'uosmo',
          amount: BigInt.from(50000),
        );
        expect(
          problems([swap, elsewhere]).single,
          contains("not Zunia's fee address"),
        );
        final more = buildSwapFeeMsg(
          sender: osmoMe,
          recipient: data.fees.recipients['osmosis-1']!,
          denom: 'uosmo',
          amount: BigInt.from(50001),
        );
        expect(problems([swap, more]).single, contains('The Zunia fee is'));
        expect(problems([swap]).single, contains('leaves out'));
        expect(problems([...prepared.msgs, prepared.msgs[1]]), [extraMessages]);
        final floorless = TxMsg(swap.typeUrl, {
          ...swap.value,
          'token_out_min_amount': '1',
        });
        expect(
          problems([floorless, prepared.msgs[1]]).single,
          contains("swap's minimum"),
        );
      },
    );
  });

  test('the default memo names the swap, never the fee beside it', () {
    final pool = buildPoolSwapMsg(
      sender: osmoMe,
      denom: 'uosmo',
      routes: const [
        PoolRoute([PoolHop('1', atomOnOsmosis)], '1000'),
      ],
      minOut: '400',
    );
    final fee = buildSwapFeeMsg(
      sender: osmoMe,
      recipient: bech('osmo', 5),
      denom: 'uosmo',
      amount: BigInt.from(5),
    );
    expect(
      swapTxMemo([pool, fee], 'osmosis-1', data.book),
      'Swap OSMO to ATOM · by Zunia-wallet',
    );
    // A token nothing proves is left out rather than named.
    final unknown = buildPoolSwapMsg(
      sender: osmoMe,
      denom: 'uosmo',
      routes: const [
        PoolRoute([
          PoolHop(
            '1',
            'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
          ),
        ], '1000'),
      ],
      minOut: '400',
    );
    expect(
      swapTxMemo([unknown], 'osmosis-1', data.book),
      'Swap · by Zunia-wallet',
    );
    expect(ibcDenomHash('transfer/channel-0', 'uatom'), atomOnOsmosis);
  });
}
