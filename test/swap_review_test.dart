/// The signing screen's security control: a memo the wallet cannot account for
/// is never signed.
///
/// The user signs one MsgTransfer whose memo tells Osmosis to swap and forward
/// the proceeds — so the memo *is* the transaction. These tests drive the real
/// review screen with a real plan and pin what it says and what it refuses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/swap_review_screen.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _xcs = 'osmo1xcscontract';

ChainEntry _chain(String id, String denom, String prefix) => ChainEntry(
      chainId: id,
      chainName: id,
      bech32Prefix: prefix,
      coinType: 118,
      network: 'testnet',
      coinDenom: denom,
      coinMinimalDenom: 'u${denom.toLowerCase()}',
      coinDecimals: 6,
      feeDenom: denom,
      feeMinimalDenom: 'u${denom.toLowerCase()}',
      feeDecimals: 6,
      rest: 'http://127.0.0.1:1',
    );

/// A controller frozen at one state, so the screen can be driven directly.
class _FrozenController extends SwapController {
  _FrozenController(super.ref, SwapPlanState value) {
    state = value;
  }
}

void main() {
  final source = _chain('source-1', 'SRC', 'src');
  final dest = _chain('dest-1', 'DST', 'dst');
  final from = ChainAccount(chain: source, address: 'src1sender');
  final to = ChainAccount(chain: dest, address: 'dst1recipient');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  RoutePlanCandidate candidateWith(String memo) => RoutePlanCandidate(
        plan: RoutePlan(
          sourceChainId: source.chainId,
          destChainId: dest.chainId,
          inputDenom: 'usrc',
          outputDenom: 'udst',
          hops: const [
            RouteHop(
              chainId: 'source-1',
              channelId: 'channel-3',
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
        ),
        strategy: RouteStrategy.ibcSwap,
        links: const [],
        receiver: _xcs,
        quote: null,
        requiresQuote: true,
        venue: const SwapVenue(chainId: 'osmosis-1', contractAddress: _xcs),
        unwindsDenom: false,
        unverifiedChannelCount: 0,
        packetHopCount: 1,
        score: 105,
      );

  final quote = OsmosisSwapQuote(
    inputDenom: 'usrc',
    inputAmount: '1000000',
    outputDenom: 'udst',
    outputAmount: '2200000',
    priceImpact: 0.42,
    poolFee: 0.2,
    minReceived: '2178000',
    slippagePercent: 1,
    route: const [],
    source: OsmosisQuoteSource.router,
    splits: const [],
    spotPrice: null,
    effectiveFeeFraction: null,
    warnings: const [],
    fetchedAt: DateTime(2026, 9, 6),
  );

  Future<void> pumpReview(WidgetTester tester, SwapPlanState state) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          swapControllerProvider.overrideWith(
            (ref) => _FrozenController(ref, state),
          ),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: SwapReviewScreen(from: from, to: to),
        ),
      ),
    );
    await tester.pump();
  }

  VoidCallback? signAction(WidgetTester tester) => tester
      .widget<ZuniaButton>(
        find.widgetWithText(ZuniaButton, 'Sign and broadcast'),
      )
      .onPressed;

  testWidgets('a swap memo is described in plain language before signing',
      (tester) async {
    final memo = buildXcsSwapMemo(
      contract: _xcs,
      outputDenom: 'udst',
      receiver: to.address,
      slippage: const XcsTwapSlippage(slippagePercentage: '1'),
      onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
    );
    await pumpReview(
      tester,
      SwapPlanState(
        candidate: candidateWith(memo),
        quote: quote,
        memoInspection: validateMemo(memo, receiver: _xcs),
        recoveryAddress: 'osmo1recovery',
      ),
    );

    expect(find.text('Decoded on device'), findsOneWidget);
    expect(find.textContaining('swaps to udst'), findsOneWidget);
    expect(find.textContaining('Recovery address'), findsWidgets);
    expect(signAction(tester), isNotNull);
  });

  testWidgets('a memo the wallet cannot classify blocks signing', (tester) async {
    // Middleware we do not model, or a forward we could not read: either way
    // nothing here can say what happens to the funds on arrival.
    const memo = '{"unknown_middleware":{"do":"something"}}';
    await pumpReview(
      tester,
      SwapPlanState(
        candidate: candidateWith(memo),
        quote: quote,
        memoInspection: validateMemo(memo),
      ),
    );

    expect(find.text('Zunia cannot read this memo'), findsOneWidget);
    expect(signAction(tester), isNull);
    expect(
      find.textContaining('could not account for every part of this memo'),
      findsOneWidget,
    );
  });

  testWidgets('a do_nothing swap is called out as unrecoverable',
      (tester) async {
    final memo = buildXcsSwapMemo(
      contract: _xcs,
      outputDenom: 'udst',
      receiver: to.address,
      slippage: const XcsTwapSlippage(slippagePercentage: '1'),
      onFailedDelivery: const XcsDoNothing(),
    );
    await pumpReview(
      tester,
      SwapPlanState(
        candidate: candidateWith(memo),
        quote: quote,
        memoInspection: validateMemo(memo, receiver: _xcs),
      ),
    );

    // Both the warning read back out of the memo and the callout under the
    // message rows; the callout is below the fold at 320dp.
    expect(find.textContaining('cannot be recovered'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('No recovery address'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No recovery address'), findsOneWidget);
  });

  testWidgets('an expired quote cannot be signed from a stale screen',
      (tester) async {
    await pumpReview(tester, const SwapPlanState());
    expect(find.text('This quote has expired'), findsOneWidget);
    expect(find.widgetWithText(ZuniaButton, 'Sign and broadcast'), findsNothing);
  });

  testWidgets('the gas line names the source chain and only the source chain',
      (tester) async {
    final memo = buildXcsSwapMemo(
      contract: _xcs,
      outputDenom: 'udst',
      receiver: to.address,
      slippage: const XcsTwapSlippage(slippagePercentage: '1'),
      onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
    );
    await pumpReview(
      tester,
      SwapPlanState(
        candidate: candidateWith(memo),
        quote: quote,
        memoInspection: validateMemo(memo, receiver: _xcs),
        recoveryAddress: 'osmo1recovery',
      ),
    );
    await tester.scrollUntilVisible(
      find.textContaining('You pay gas only on source-1'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('You pay gas only on source-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
