/// The token screen: what it shows, what it refuses, and what it never fetches.
///
/// Two rules under test. Artwork is not fetched unless the user turned it on
/// *and* live reads are on, and the switch has to be real — a hidden image
/// widget still issues the request, so the assertion is that no `Image` is
/// built at all. And a control is only live when its whole path works: a token
/// this wallet does not hold, or a chain with no configured ICS721 bridge, gets
/// a disabled button with the reason next to it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/nft_detail_screen.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/nft_metadata_fetcher.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _chainId = 'safrochain-1';
const _owner = 'addr_safro1owner00000000000000000000000000000';
const _other = 'addr_safro1someoneelse000000000000000000000';
const _collection = 'addr_safro1collection00000000000000000000000';

const _chainInfo = ChainInfo(
  chainId: _chainId,
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['cosmwasm'],
  rest: 'https://lcd.safro.example',
);

final _entry = ChainEntry(
  chainId: _chainId,
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
  rest: 'http://127.0.0.1:1',
);

class _FakeRegistry implements ChainRegistry {
  const _FakeRegistry();

  @override
  ChainInfo? get(String chainId) => chainId == _chainId ? _chainInfo : null;

  @override
  List<ChainInfo> list() => const [_chainInfo];
}

NftTokenDetail _detail({
  String owner = _owner,
  String? imageUrl,
  String? imageReason,
}) =>
    NftTokenDetail(
      token: const NftToken(
        tokenId: '42',
        collectionAddress: _collection,
        chainId: _chainId,
        name: 'Zebra #42',
        description: 'A striped horse.',
        imageUri: 'https://img.test/42.png',
        attributes: [NftAttribute(traitType: 'Coat', value: 'Striped')],
        tokenUri: 'https://meta.test/42',
      ).copyWith(owner: owner),
      collection: const NftCollection(
        chainId: _chainId,
        contractAddress: _collection,
        name: 'Zebras',
        symbol: 'ZEB',
        tokenCount: 100,
      ),
      imageUrl: imageUrl,
      imageReason: imageReason,
    );

bool _enabled(WidgetTester tester, String label) {
  final button =
      tester.widget<ZuniaButton>(find.widgetWithText(ZuniaButton, label));
  return button.onPressed != null;
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    NftTokenDetail? detail,
    Map<String, Object> prefs = const {},
    Size size = const Size(320, 640),
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
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
          phraseProvider.overrideWith((ref) => 'test phrase'),
          nftTokenDetailProvider.overrideWith(
            (ref, key) async => detail ?? _detail(),
          ),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: const NftDetailScreen(
            chainId: _chainId,
            collectionAddress: _collection,
            tokenId: '42',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the token, its collection and its traits', (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});

    expect(find.text('Zebra #42'), findsOneWidget);
    expect(find.textContaining('ZEBRAS'), findsWidgets);
    expect(find.text('A striped horse.'), findsOneWidget);
    expect(find.text('Striped'), findsOneWidget);
  });

  testWidgets('artwork is not fetched while the switch is off', (tester) async {
    await pump(
      tester,
      // Live reads on, artwork off: the one case where a lazy implementation
      // would quietly fetch anyway.
      prefs: const {'zunia.prefs.liveReads': true},
      detail: _detail(
        imageUrl: null,
        imageReason: 'Artwork is off.',
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text(kZuniaNftMediaLoadLabel.toUpperCase()), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('No artwork shown'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No artwork shown'), findsOneWidget);
    // Still no image after scrolling the whole screen into view.
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no explorer is invented; the identifiers are copyable instead',
      (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});
    await tester.scrollUntilVisible(
      find.textContaining('no explorer configured'),
      160,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('no explorer configured'), findsOneWidget);
    expect(find.text('COLLECTION ADDRESS'), findsOneWidget);
    expect(find.text('TOKEN ID'), findsOneWidget);
  });

  testWidgets('a token held by someone else cannot be moved from here',
      (tester) async {
    await pump(
      tester,
      prefs: const {'zunia.prefs.liveReads': true},
      detail: _detail(owner: _other),
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(ZuniaButton, 'Transfer here'),
      160,
      scrollable: find.byType(Scrollable).first,
    );

    expect(_enabled(tester, 'Transfer here'), isFalse);
    expect(_enabled(tester, 'Send cross-chain'), isFalse);
    expect(find.textContaining('held by another address'), findsOneWidget);
  });

  testWidgets('cross-chain is off in a build with no ICS721 route, and says why',
      (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});
    await tester.scrollUntilVisible(
      find.widgetWithText(ZuniaButton, 'Send cross-chain'),
      160,
      scrollable: find.byType(Scrollable).first,
    );

    // The same-chain path works; only the cross-chain one is unconfigured.
    expect(_enabled(tester, 'Transfer here'), isTrue);
    expect(_enabled(tester, 'Send cross-chain'), isFalse);
    expect(find.textContaining('no ICS721 bridge or channel'), findsOneWidget);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('createNftMetadataFetcher', () {
    test('needs both switches before any transport exists', () {
      expect(
        createNftMetadataFetcher(liveReads: false, mediaEnabled: false),
        isNull,
      );
      expect(
        createNftMetadataFetcher(liveReads: true, mediaEnabled: false),
        isNull,
      );
      expect(
        createNftMetadataFetcher(liveReads: false, mediaEnabled: true),
        isNull,
      );
      expect(
        createNftMetadataFetcher(liveReads: true, mediaEnabled: true),
        isNotNull,
      );
    });

    test('refuses a non-https URL without opening a connection', () async {
      final fetch = createNftMetadataFetcher(
        liveReads: true,
        mediaEnabled: true,
      )!;
      await expectLater(
        fetch('http://meta.test/1'),
        throwsA(isA<InterchainError>().having(
          (e) => e.code,
          'code',
          InterchainErrorCode.malformedResponse,
        )),
      );
      await expectLater(
        fetch('not a url'),
        throwsA(isA<InterchainError>()),
      );
    });
  });

  group('nftMediaBlockedReason', () {
    test('names the switch that is actually in the way', () {
      expect(
        nftMediaBlockedReason(
          liveReads: false,
          mediaEnabled: true,
          hasIpfsGateway: true,
        ),
        contains('Live reads are off'),
      );
      expect(
        nftMediaBlockedReason(
          liveReads: true,
          mediaEnabled: false,
          hasIpfsGateway: true,
        ),
        contains('Artwork is off'),
      );
      // Both switches on, but this build ships no gateway, so IPFS artwork
      // still cannot load and the screen must say that rather than show a
      // blank frame.
      expect(
        nftMediaBlockedReason(
          liveReads: true,
          mediaEnabled: true,
          hasIpfsGateway: false,
        ),
        contains('no IPFS gateway configured'),
      );
      expect(
        nftMediaBlockedReason(
          liveReads: true,
          mediaEnabled: true,
          hasIpfsGateway: true,
        ),
        isNull,
      );
    });
  });
}
