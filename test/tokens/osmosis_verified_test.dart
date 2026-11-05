/// A token Osmosis lists without having verified it (SAF while
/// osmosis-labs/assetlists#3876 is open) is named, priced and swapped like any
/// proven token, but shows no seal and is never called verified: that word is
/// Osmosis's to give. Every token Osmosis verified keeps its seal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

import '../support/catalog.dart';

const safOnOsmosis = 'ibc/DBAA4846F611A7603EFCE6F9F46F4F561D48B1F492A576022F000614A17089CE';
const usdcNOnOsmosis = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';

void main() {
  setUpAll(loadBundledData);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChainCatalog.instance.setCustom(const []);
    resetTokenIdentityState();
  });

  test('SAF is proven wherever it is held, and has no seal until Osmosis verifies it', () {
    for (final (chainId, denom) in [('safrochain-1', 'usaf'), ('osmosis-1', safOnOsmosis)]) {
      final saf = identityOf(chainId, denom);
      final label = '$chainId:$denom';
      expect(saf.ticker, 'SAF', reason: label);
      expect(saf.originChainId, 'safrochain-1', reason: label);
      expect(saf.osmosisDenom, safOnOsmosis, reason: label);
      expect(saf.proven, isTrue, reason: label);
      expect(saf.unverifiedOnOsmosis, isTrue, reason: label);
      expect(saf.showsSeal, isFalse, reason: label);
    }
  });

  test('a token Osmosis verified keeps its seal', () {
    for (final (chainId, denom) in [
      ('cosmoshub-4', 'uatom'),
      ('noble-1', 'uusdc'),
      ('osmosis-1', usdcNOnOsmosis),
    ]) {
      final identity = identityOf(chainId, denom);
      final label = '$chainId:$denom';
      expect(identity.proven, isTrue, reason: label);
      expect(identity.unverifiedOnOsmosis, isFalse, reason: label);
      expect(identity.showsSeal, isTrue, reason: label);
    }
  });

  testWidgets('the token avatar draws no seal for SAF and one for ATOM', (tester) async {
    Future<bool> sealed(TokenIdentity identity) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ZuniaTheme.dark(),
          home: Center(child: TokenAvatar(identity: identity)),
        ),
      );
      return tester.widget<ZuniaTokenLogo>(find.byType(ZuniaTokenLogo).first).verified;
    }

    expect(await sealed(identityOf('safrochain-1', 'usaf')), isFalse);
    expect(await sealed(identityOf('osmosis-1', safOnOsmosis)), isFalse);
    expect(await sealed(identityOf('cosmoshub-4', 'uatom')), isTrue);
  });

  test('a signing prompt names SAF without calling it verified', () {
    final safrochain = ChainCatalog.instance.find('safrochain-1');
    final hub = ChainCatalog.instance.find('cosmoshub-4');
    final saf = resolvedCoinLine(safrochain, const FeeCoin('usaf', '1500000'));
    expect(saf, startsWith('= 1.5 SAF · native on '));
    expect(saf, isNot(contains('verified')));
    expect(
      resolvedCoinLine(hub, const FeeCoin('uatom', '1500000')),
      '= 1.5 ATOM · native on Cosmos Hub · verified by registry',
    );
  });
}
