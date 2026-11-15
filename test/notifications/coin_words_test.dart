/// A user received 15 USDC on Safrochain and the notification said "15 SAF":
/// every received amount was written with the chain's coin. These pin the
/// wording to the denom that moved, with where it comes from.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/notifications/coin_words.dart';
import 'package:zunia_mobile/notifications/notice_engine.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';

import '../support/catalog.dart';

/// Injective's USDC (erc20 module), as Injective's bank spells it.
const usdcInj = 'erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a';

/// That USDC on Safrochain, over Safrochain's channel-2 to Injective.
const usdcInjOnSafro = 'ibc/1E180C085A3A2688CDF2A781E5990BE8AA92CE69CB62A8CC6BB9F5EE17DD5C38';

void main() {
  setUpAll(() async {
    await loadBundledData();
  });

  setUp(() {
    resetTokenIdentityState();
    // What tracing the voucher on Safrochain proves (the hash checks it).
    debugAddTraceFact(
      'safrochain-1',
      usdcInjOnSafro,
      TraceFact(
        o: 'injective-1',
        b: usdcInj,
        p: 'transfer/channel-2',
        h: const ['injective-1'],
        at: DateTime(2026, 11, 15).millisecondsSinceEpoch,
      ),
    );
  });

  group('describeMovedCoin', () {
    test('USDC from Injective on Safrochain says so, never SAF', () {
      final words = describeMovedCoin('safrochain-1', usdcInjOnSafro, '15000000');
      expect(words, startsWith('15 USDC.inj'));
      expect(words, contains('Injective'));
      expect(words, isNot(contains('SAF')));
    });

    test('the same USDC on Injective needs no origin note', () {
      expect(describeMovedCoin('injective-1', usdcInj, '15000000'), '15 USDC.inj');
    });

    test("the chain's own coin keeps its symbol and scale", () {
      expect(describeMovedCoin('safrochain-1', 'usaf', '15000000'), '15 SAF');
      expect(describeMovedCoin('injective-1', 'inj', '160000000000000000'), '0.16 INJ');
    });

    test('a voucher nothing traced stays in base units, never scaled', () {
      resetTokenIdentityState();
      final words = describeMovedCoin('safrochain-1', usdcInjOnSafro, '15000000');
      expect(words, startsWith('15000000 base units ibc/'));
    });

    test('describeCoinOn, for live arrivals, words it the same way', () {
      final chain = ChainCatalog.instance.find('safrochain-1');
      expect(
        describeCoinOn(chain, const MovedCoin(usdcInjOnSafro, '15000000')),
        describeMovedCoin('safrochain-1', usdcInjOnSafro, '15000000'),
      );
    });
  });

  test('untracedVouchers lists only vouchers nothing names', () {
    resetTokenIdentityState();
    expect(
      untracedVouchers('safrochain-1', [usdcInjOnSafro, 'usaf', usdcInjOnSafro]),
      [usdcInjOnSafro],
    );
    debugAddTraceFact(
      'safrochain-1',
      usdcInjOnSafro,
      TraceFact(o: 'injective-1', b: usdcInj, p: 'transfer/channel-2', at: 1),
    );
    expect(untracedVouchers('safrochain-1', [usdcInjOnSafro]), isEmpty);
  });

  test("the history's received rows are worded with the moved denom", () {
    final rows = receivedNoticeInputs([
      ActivityItem(
        chainId: 'safrochain-1',
        hash: 'A1',
        kind: ActivityKind.received,
        title: 'Receive USDC.inj over IBC',
        subtitle: 'From Injective',
        timestamp: DateTime(2026, 11, 15),
        success: true,
        amount: '15000000',
        denom: usdcInjOnSafro,
        decimals: 6,
        decimalsKnown: true,
        symbol: 'USDC.inj',
      ),
      ActivityItem(
        chainId: 'safrochain-1',
        hash: 'A2',
        kind: ActivityKind.received,
        title: 'Receive SAF',
        subtitle: '',
        timestamp: DateTime(2026, 11, 15),
        success: true,
        amount: '2500000',
        denom: 'usaf',
        decimals: 6,
        decimalsKnown: true,
        symbol: 'SAF',
      ),
    ]);
    expect(rows.first.meta, startsWith('15 USDC.inj'));
    expect(rows.first.meta, isNot(contains('SAF')));
    expect(rows.last.meta, '2.5 SAF');
  });
}
