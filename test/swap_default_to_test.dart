/// The To a swap opens on when the user has not picked one, and how SAF goes.
///
/// Selling SAF on Safrochain: the contract's route table has no SAF route, but
/// SAF reaches Osmosis in one hop (Safrochain channel-1, arriving as
/// `transfer/channel-110497/usaf`), so Skip Go's entry point swaps it in one
/// signature. The default is USDC on Osmosis, where pool 3600 pairs SAF, never
/// a held voucher elsewhere (USDC.inj on Safrochain would need the output sent
/// on through Injective).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/swap/one_signature.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';

import 'support/swap_fixtures.dart';
import 'support/swap_world.dart';

const safOnOsmosis =
    'ibc/DBAA4846F611A7603EFCE6F9F46F4F561D48B1F492A576022F000614A17089CE';

/// USDC.inj as Safrochain holds it: Injective channel-495 ↔ Safrochain channel-2.
const usdcInjOnSafrochain =
    'ibc/0F6F3B3E5C1A3F4B5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4';

void main() {
  setUpAll(loadSwapWorld);

  List<SwapChain> chains() => [
    SwapChain(chain('safrochain-1'), bech('addr_safro', 1)),
    SwapChain(chain('cosmoshub-4'), hubMe),
    SwapChain(chain('osmosis-1'), osmoMe),
  ];

  final holdings = <String, List<HeldToken>>{
    'safrochain-1': const [
      HeldToken('usaf', '5000000000'),
      HeldToken(usdcInjOnSafrochain, '2500000'),
    ],
    'cosmoshub-4': const [HeldToken('uatom', '1000000')],
    'osmosis-1': const [HeldToken('uosmo', '1000000')],
  };

  List<SwapAsset> buy(SwapAsset from) => buyOptions(
    chains(),
    holdings,
    data.book,
    catalog: data.catalog,
    from: from,
    osmosis: osmosis,
    routes: table,
  );

  SwapAsset held(String key) => sellOptions(
    chains(),
    holdings,
    data.book,
    osmosis: osmosis,
  ).firstWhere((asset) => asset.key == key);

  test('SAF on Safrochain has a voucher on Osmosis and nothing refuses it as not traded', () {
    final saf = held('safrochain-1:usaf');
    expect(saf.identity.osmosisDenom, safOnOsmosis);
    final rows = buy(saf);
    expect(rows.where((row) => row.disabledReason == notTradedReason('SAF')), isEmpty);
  });

  test('sells SAF on Safrochain for USDC on Osmosis by default, in one signature', () {
    final saf = held('safrochain-1:usaf');
    bool reaches(SwapAsset to) => oneSignatureReaches(saf, to, data.book);
    final to = pickTo(
      buy(saf),
      null,
      fromChainId: saf.chainId,
      oneSignature: reaches,
    )!;
    expect(to.chainId, 'osmosis-1');
    expect(to.identity.family, 'USDC');
    expect(reaches(to), isTrue);
    expect(
      swapPathFor(
        saf.chainId,
        to.chainId,
        to.executable,
        venueChainId: 'osmosis-1',
        oneSignature: reaches(to),
      ),
      SwapPath.oneSignature,
    );
    // Without the entry point the same pair still moves to Osmosis first.
    expect(
      swapPathFor(saf.chainId, to.chainId, to.executable, venueChainId: 'osmosis-1'),
      SwapPath.moveFirst,
    );
  });

  test('SAF reaches Osmosis over Safrochain channel-1 and arrives as its listed voucher', () {
    final saf = held('safrochain-1:usaf');
    final inbound = venueInboundOf(saf, data.book)!;
    expect(inbound.channelId, 'channel-1');
    expect(inbound.port, 'transfer');
    expect(inbound.arrivalDenom, safOnOsmosis);
  });

  test('USDC.inj held on Safrochain does not reach Osmosis in one hop', () {
    final voucher = held('safrochain-1:$usdcInjOnSafrochain');
    expect(venueInboundOf(voucher, data.book), isNull);
  });

  test('SAF rows are offered without a seal, and ATOM keeps its seal', () {
    final saf = held('safrochain-1:usaf');
    expect(saf.identity.proven, isTrue);
    expect(saf.identity.unverifiedOnOsmosis, isTrue);
    expect(saf.identity.showsSeal, isFalse);
    final atom = held('cosmoshub-4:uatom');
    expect(atom.identity.unverifiedOnOsmosis, isFalse);
    expect(atom.identity.showsSeal, isTrue);
    final safRows = buy(atom).where((row) => row.identity.originChainId == 'safrochain-1').toList();
    expect(safRows, isNotEmpty);
    for (final row in safRows) {
      expect(row.disabledReason, isNot(notTradedReason('SAF')), reason: row.key);
      expect(row.identity.proven, isTrue, reason: row.key);
      expect(row.identity.showsSeal, isFalse, reason: row.key);
    }
  });

  test('a row the user picked stays picked', () {
    final saf = held('safrochain-1:usaf');
    final rows = buy(saf);
    final atom = rows.firstWhere((row) => row.key == 'cosmoshub-4:uatom');
    expect(pickTo(rows, atom.key, fromChainId: saf.chainId), same(atom));
  });

  test('prefers a row one transaction reaches over a held one that needs a move first', () {
    final atom = held('cosmoshub-4:uatom');
    final to = pickTo(buy(atom), null, fromChainId: atom.chainId)!;
    expect(
      swapPathFor(atom.chainId, to.chainId, to.executable, venueChainId: 'osmosis-1'),
      isNot(SwapPath.moveFirst),
    );
  });
}
