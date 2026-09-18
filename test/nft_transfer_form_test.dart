/// Step one of an NFT transfer: the recipient, and every reason it is refused.
///
/// The mistake this screen exists to prevent is a well-formed address on the
/// wrong chain. It looks correct, it passes any generic bech32 check, and a
/// CW721 token sent to it is gone — so the prefix is checked against the
/// *destination*, which for a cross-chain send is the other chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/nft_transfer_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _chainId = 'safrochain-1';
const _owner = 'addr_safro1owner00000000000000000000000000000';
const _recipient = 'addr_safro1recipient0000000000000000000000000';
const _collection = 'addr_safro1collection00000000000000000000000';

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

bool _reviewEnabled(WidgetTester tester) {
  final button = tester.widget<ZuniaButton>(
    find.widgetWithText(ZuniaButton, 'Review transfer'),
  );
  return button.onPressed != null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester tester, {
    bool crossChain = false,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chainAccountsProvider.overrideWithValue(
            [ChainAccount(chain: _entry, address: _owner)],
          ),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: NftTransferScreen(
            chainId: _chainId,
            collectionAddress: _collection,
            tokenId: '42',
            collectionName: 'Zebra #42',
            crossChain: crossChain,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty recipient blocks review and says what is missing',
      (tester) async {
    await pump(tester);
    expect(_reviewEnabled(tester), isFalse);
    expect(
      find.textContaining('Enter the address that should receive'),
      findsOneWidget,
    );
  });

  testWidgets('a valid address for the wrong chain is rejected', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'osmo1recipient000000000000000000000000000000',
    );
    await tester.pumpAndSettle();

    expect(_reviewEnabled(tester), isFalse);
    expect(
      find.textContaining('it must start with "addr_safro1"'),
      findsOneWidget,
    );
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
    // The footer points at the field rather than repeating its message, so a
    // single mistake does not read as two.
    expect(find.text('Fix the recipient address above.'), findsOneWidget);
  });

  testWidgets('this wallet\'s own address is rejected on a same-chain transfer',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, _owner);
    await tester.pumpAndSettle();

    expect(_reviewEnabled(tester), isFalse);
    expect(find.textContaining('own address'), findsOneWidget);
    expect(find.text('Fix the recipient address above.'), findsOneWidget);
  });

  testWidgets('a good recipient opens review', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, _recipient);
    await tester.pumpAndSettle();

    expect(_reviewEnabled(tester), isTrue);
  });

  testWidgets('cross-chain is refused outright when no ICS721 route ships',
      (tester) async {
    await pump(tester, crossChain: true);

    expect(find.text('No ICS721 route configured'), findsOneWidget);
    expect(
      find.textContaining('cannot be reused for a collectible'),
      findsOneWidget,
    );
    // The voucher warning is on the form as well as the review screen: it
    // changes what the user is agreeing to, not just what they sign.
    expect(find.text('The other chain mints a voucher'), findsOneWidget);
    expect(_reviewEnabled(tester), isFalse);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    await pump(tester, crossChain: true);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
