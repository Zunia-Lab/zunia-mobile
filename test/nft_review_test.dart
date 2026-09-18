/// What the approval screen says a signature will do.
///
/// A CW721 transfer arrives on chain as a `MsgExecuteContract`, which a naive
/// wallet shows as "Execute contract". These tests pin that this one decodes
/// the message it is about to sign and names the collectible, the collection
/// and the recipient — and that anything it cannot account for turns the button
/// off instead of being waved through.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/nft_transfer_review_screen.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _source = 'safrochain-1';
const _dest = 'osmosis-1';
const _owner = 'addr_safro1owner00000000000000000000000000000';
const _recipient = 'addr_safro1recipient0000000000000000000000000';
const _collection = 'addr_safro1collection00000000000000000000000';
const _bridge = 'addr_safro1bridge0000000000000000000000000000';
const _osmoRecipient = 'osmo1recipient000000000000000000000000000000';

const _sourceInfo = ChainInfo(
  chainId: _source,
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['cosmwasm'],
  rest: 'https://lcd.safro.example',
);

const _destInfo = ChainInfo(
  chainId: _dest,
  chainName: 'Osmosis',
  bech32Prefix: 'osmo',
  coinMinimalDenom: 'uosmo',
  features: ['cosmwasm'],
  rest: 'https://lcd.osmosis.example',
);

final _entry = ChainEntry(
  chainId: _source,
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinType: 118,
  network: 'testnet',
  coinDenom: 'SAFRO',
  coinMinimalDenom: 'usafro',
  coinDecimals: 6,
  feeDenom: 'SAFRO',
  feeMinimalDenom: 'usafro',
  feeDecimals: 6,
  gasPriceStep: const {'low': 0.01, 'average': 0.025, 'high': 0.04},
  rest: 'http://127.0.0.1:1',
);

class _FakeRegistry implements ChainRegistry {
  const _FakeRegistry();

  @override
  ChainInfo? get(String chainId) => switch (chainId) {
        _source => _sourceInfo,
        _dest => _destInfo,
        _ => null,
      };

  @override
  List<ChainInfo> list() => const [_sourceInfo, _destInfo];
}

/// The button's enabled state, which is the thing under test.
bool _signEnabled(WidgetTester tester) {
  final button = tester.widget<ZuniaButton>(
    find.widgetWithText(ZuniaButton, 'Sign and broadcast'),
  );
  return button.onPressed != null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester tester, {
    required NftTransferReviewScreen screen,
    NftChainSupport? support,
    bool unlocked = true,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interchainRegistryProvider.overrideWithValue(const _FakeRegistry()),
          chainAccountsProvider.overrideWithValue(
            [ChainAccount(chain: _entry, address: _owner)],
          ),
          if (unlocked) phraseProvider.overrideWith((ref) => 'test phrase'),
          nftChainSupportProvider.overrideWith(
            (ref, chainId) async =>
                support ??
                const NftChainSupport(
                  chainId: _source,
                  state: NftChainSupportState.supported,
                  reason: null,
                  evidence: 'test',
                ),
          ),
        ],
        child: MaterialApp(theme: ZuniaTheme.dark(), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a same-chain transfer names the token, collection and recipient',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '42',
        recipient: _recipient,
        collectionName: 'Zebras',
      ),
    );

    expect(find.text('Decoded on device'), findsOneWidget);
    expect(find.textContaining('token 42'), findsOneWidget);
    expect(find.textContaining('Zebras'), findsOneWidget);
    expect(find.textContaining(_recipient), findsOneWidget);
    // Never the bare message type as the whole explanation.
    expect(find.text('Execute contract'), findsNothing);
    expect(_signEnabled(tester), isTrue);
  });

  testWidgets('the raw message is the CW721 execute, shown on request',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '42',
        recipient: _recipient,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Show the raw message'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show the raw message'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('"transfer_nft":{"recipient":"$_recipient"'),
      findsOneWidget,
    );
  });

  testWidgets('a cross-chain send is decoded out of the base64, not described '
      'from intent', (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '7',
        recipient: _osmoRecipient,
        destChainId: _dest,
        bridgeContract: _bridge,
        channelId: 'channel-12',
      ),
    );

    expect(find.textContaining('Escrows token 7'), findsOneWidget);
    expect(find.textContaining('channel-12'), findsWidgets);
    expect(find.textContaining('Osmosis'), findsWidgets);
    // The warning the user has to see before agreeing to a voucher.
    expect(find.text(ics721VoucherWarning), findsOneWidget);
    expect(_signEnabled(tester), isTrue);
  });

  testWidgets('a receiver on the wrong chain is refused, not signed',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '7',
        // A source-chain address for a destination-chain receiver: well formed
        // and completely wrong.
        recipient: _recipient,
        destChainId: _dest,
        bridgeContract: _bridge,
        channelId: 'channel-12',
      ),
    );

    expect(_signEnabled(tester), isFalse);
    expect(find.textContaining('is not a Osmosis address'), findsWidgets);
  });

  testWidgets('no configured bridge means no signature and a stated reason',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '7',
        recipient: _osmoRecipient,
        destChainId: _dest,
        channelId: 'channel-12',
      ),
    );

    expect(_signEnabled(tester), isFalse);
    expect(find.textContaining('bridge contract'), findsWidgets);
  });

  testWidgets('a chain whose CosmWasm support is unknown is never signed for',
      (tester) async {
    await pump(
      tester,
      support: const NftChainSupport(
        chainId: _source,
        state: NftChainSupportState.unknown,
        reason: 'The bundled chain catalog drops the registry feature list.',
        evidence: 'no features',
      ),
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '42',
        recipient: _recipient,
      ),
    );

    expect(_signEnabled(tester), isFalse);
    expect(
      find.textContaining('drops the registry feature list'),
      findsWidgets,
    );
  });

  testWidgets('a locked wallet cannot sign, and the button says so',
      (tester) async {
    await pump(
      tester,
      unlocked: false,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '42',
        recipient: _recipient,
      ),
    );

    expect(_signEnabled(tester), isFalse);
    expect(find.textContaining('Unlock the wallet'), findsOneWidget);
  });

  testWidgets('the fee is shown in the source chain token, never as zero',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '42',
        recipient: _recipient,
      ),
    );

    expect(find.textContaining('SAFRO'), findsWidgets);
    expect(find.text('not available'), findsNothing);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pump(
      tester,
      screen: const NftTransferReviewScreen(
        chainId: _source,
        collectionAddress: _collection,
        tokenId: '7',
        recipient: _osmoRecipient,
        destChainId: _dest,
        bridgeContract: _bridge,
        channelId: 'channel-12',
      ),
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
