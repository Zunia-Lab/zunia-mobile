import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';
import 'package:zunia_mobile/transfers/send_arrival.dart';

import '../support/catalog.dart';

/// What the recipient of a Send to another chain ends up holding (extension
/// lib/__tests__/send-arrival.test.ts, 0.1.5), against the bundled token
/// table and catalog.
const osmoUsdcN = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';
const injUsdcN = 'ibc/2CBC2EA121AE42563B08028466F37B600F2D7D4282342DE938283CC3FB2BC00E';
const osmoUsdcAxl = 'ibc/D189335C6E4A68B513C10AB227BF1C1D38C746766278BA3EEB4FB14124F1D858';
const osmoUsdcInj = 'ibc/794C7D7F3B857713878A3A1927251FA6AC1EEE520424C1F6FAFE9BA26D476138';
const osmoEthPica = 'ibc/A23E590BA7E0D808706FB5085A449B3B9D6864AE4DDE7DAF936243CEBB2A3D43';
const usdcInj = 'erc20:0xa00C59fF5a080D2b954d0c75e46E22a0c371235a';
const unlisted = 'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';

String sha256Upper(String text) => sha256.convert(utf8.encode(text)).toString().toUpperCase();

/// Noble USDC held on Injective, sent to Osmosis over Injective channel-8,
/// which Osmosis receives on channel-122.
final rewrapped = 'ibc/${sha256Upper('transfer/channel-122/transfer/channel-148/uusdc')}';

ChannelLink link(String from, String to, String channel, [String? counterparty]) => ChannelLink(
      sourceChainId: from,
      destChainId: to,
      channelId: channel,
      counterpartyChannelId: counterparty,
    );

final osmosisToNoble = link('osmosis-1', 'noble-1', 'channel-750', 'channel-1');
final nobleToOsmosis = link('noble-1', 'osmosis-1', 'channel-1', 'channel-750');
final injectiveToOsmosis = link('injective-1', 'osmosis-1', 'channel-8', 'channel-122');
final injectiveToOsmosis118 = link('injective-1', 'osmosis-1', 'channel-6', 'channel-118');

String short(String denom) => 'ibc/${denom.substring(4, 8)}…${denom.substring(denom.length - 6)}';

void main() {
  setUpAll(loadBundledData);

  group('sendArrival', () {
    test('Osmosis USDC.n sent to Noble unwinds to uusdc, which is native USDC.n', () {
      final arrival = sendArrival(
        sourceChainId: 'osmosis-1',
        inputDenom: osmoUsdcN,
        destChainId: 'noble-1',
        destChainName: 'Noble',
        outputDenom: 'uusdc',
        links: [osmosisToNoble],
      );
      expect(arrival.kind, ArrivalKind.native);
      expect(arrival.denom, 'uusdc');
      expect(arrival.identity!.ticker, 'USDC.n');
      expect(arrival.identity!.heldOnChainId, 'noble-1');
      expect(arrival.identity!.originChainId, 'noble-1');
      expect(arrival.identity!.proven, isTrue);
      expect(arrival.listedDenom, 'uusdc');
      expect(arrival.text, 'USDC.n · Native on Noble');
      expect(arrival.warning, isNull);
    });

    test('Noble USDC sent from Injective to Osmosis over channel-122 arrives re-wrapped, not as USDC.n', () {
      expect(ibcDenomFor('transfer/channel-122/transfer/channel-148', 'uusdc'), rewrapped);
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: injUsdcN,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: rewrapped,
        links: [injectiveToOsmosis],
      );
      expect(arrival.kind, ArrivalKind.rewrapped);
      expect(arrival.denom, rewrapped);
      expect(arrival.identity!.ticker, isNot('USDC.n'));
      expect(arrival.identity!.provenance, TokenProvenance.unknown);
      expect(arrival.identity!.proven, isFalse);
      expect(arrival.listedDenom, osmoUsdcN);
      expect(arrival.text, 'Re-wrapped USDC.n · on Osmosis');
      expect(arrival.warning!.title, 'Arrives as a different token');
      expect(
        arrival.warning!.body,
        'Osmosis lists USDC.n as ibc/498A…6BA6E4. Sent this way it arrives as ${short(rewrapped)}, '
        'a re-wrapped voucher that no registry names, so wallets and apps may not accept it. '
        'To receive USDC.n on Osmosis, send it to Noble first.',
      );
    });

    test('Noble USDC sent to Osmosis arrives as the USDC.n Osmosis lists', () {
      final arrival = sendArrival(
        sourceChainId: 'noble-1',
        inputDenom: 'uusdc',
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: osmoUsdcN,
        links: [nobleToOsmosis],
      );
      expect(arrival.kind, ArrivalKind.named);
      expect(arrival.denom, osmoUsdcN);
      expect(arrival.identity!.ticker, 'USDC.n');
      expect(arrival.text, 'USDC.n · Noble USDC · on Osmosis');
      expect(arrival.warning, isNull);
    });

    test("Injective USDC sent over the registry's channel arrives as the USDC.inj Osmosis trades", () {
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: usdcInj,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: osmoUsdcInj,
        links: [injectiveToOsmosis],
      );
      expect(arrival.kind, ArrivalKind.named);
      expect(arrival.text, 'USDC.inj · Injective USDC · on Osmosis');
      expect(arrival.warning, isNull);
    });

    test('warns when a channel delivers another voucher than the one the destination lists', () {
      final delivered = ibcDenomFor('transfer/channel-118', usdcInj);
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: usdcInj,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: delivered,
        links: [injectiveToOsmosis118],
      );
      expect(arrival.kind, ArrivalKind.unnamed);
      expect(arrival.denom, delivered);
      expect(arrival.text, 'USDC.inj voucher · on Osmosis');
      expect(arrival.warning!.body, contains('Osmosis lists USDC.inj as ibc/794C…476138.'));
    });

    test('a token no registry lists anywhere arrives as a new voucher, without a warning', () {
      final delivered = ibcDenomFor('transfer/channel-110497', 'usaf');
      final arrival = sendArrival(
        sourceChainId: 'safrochain-1',
        inputDenom: 'usaf',
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: delivered,
        links: [link('safrochain-1', 'osmosis-1', 'channel-1', 'channel-110497')],
      );
      expect(arrival.kind, ArrivalKind.unnamed);
      expect(arrival.denom, delivered);
      expect(arrival.listedDenom, isNull);
      expect(arrival.text, 'SAF voucher · on Osmosis');
      expect(arrival.warning, isNull);
    });

    test("never states the engine's stand-in when it could not compute the denom", () {
      for (final outputDenom in [unlisted, 'uusdc']) {
        final arrival = sendArrival(
          sourceChainId: 'injective-1',
          inputDenom: unlisted,
          destChainId: 'osmosis-1',
          destChainName: 'Osmosis',
          outputDenom: outputDenom,
          warnings: const [engineUncomputedOutput],
          links: [injectiveToOsmosis],
        );
        expect(arrival.kind, ArrivalKind.unknown);
        expect(arrival.denom, isNull);
        expect(arrival.identity, isNull);
        expect(arrival.text, 'Could not be computed');
        expect(
          arrival.warning!.body,
          'Zunia could not work out the denom this becomes on Osmosis. It may arrive as a token no registry names.',
        );
      }
    });

    test("works the denom out from the token's own trace when the engine could not", () {
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: injUsdcN,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: 'uusdc',
        warnings: const [engineUncomputedOutput],
        links: [injectiveToOsmosis],
      );
      expect(arrival.kind, ArrivalKind.rewrapped);
      expect(arrival.denom, rewrapped);
    });

    test('states neither denom when its own trace and the plan disagree', () {
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: injUsdcN,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: osmoUsdcN,
        links: [injectiveToOsmosis],
      );
      expect(arrival.kind, ArrivalKind.unknown);
      expect(arrival.denom, isNull);
      expect(arrival.warning!.body, contains('disagree'));
    });

    test("without a counterparty channel, takes the engine's computed denom", () {
      expect(
        sendArrival(
          sourceChainId: 'osmosis-1',
          inputDenom: osmoUsdcN,
          destChainId: 'noble-1',
          destChainName: 'Noble',
          outputDenom: 'uusdc',
        ).kind,
        ArrivalKind.native,
      );
      final wrapped = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: injUsdcN,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: rewrapped,
        warnings: const ['$engineDoubleWrap, so the recipient receives a double-wrapped denom'],
        links: [link('injective-1', 'osmosis-1', 'channel-8')],
      );
      expect(wrapped.kind, ArrivalKind.rewrapped);
      expect(wrapped.denom, rewrapped);
    });

    test('names a voucher of an unknown token by what it is not', () {
      final arrival = sendArrival(
        sourceChainId: 'injective-1',
        inputDenom: unlisted,
        destChainId: 'osmosis-1',
        destChainName: 'Osmosis',
        outputDenom: ibcDenomFor('transfer/channel-122', 'uunknown'),
      );
      expect(arrival.kind, ArrivalKind.unnamed);
      expect(arrival.text, 'Unnamed voucher · on Osmosis');
      expect(arrival.warning, isNull);
    });

    test("uses the screen's identity only for the denom it names", () {
      final arrival = sendArrival(
        sourceChainId: 'osmosis-1',
        inputDenom: osmoUsdcN,
        destChainId: 'noble-1',
        destChainName: 'Noble',
        outputDenom: 'uusdc',
        links: [osmosisToNoble],
        sent: identityOf('osmosis-1', osmoUsdcAxl),
      );
      expect(arrival.kind, ArrivalKind.native);
      expect(arrival.identity!.ticker, 'USDC.n');
    });
  });

  group('words', () {
    test('Issued on names the issuer wherever the token is held', () {
      expect(issuerText(identityOf('osmosis-1', osmoUsdcN)), 'Noble');
      expect(issuerText(identityOf('injective-1', injUsdcN)), 'Noble');
      expect(issuerText(identityOf('noble-1', 'uusdc')), 'Noble');
      expect(issuerText(identityOf('osmosis-1', osmoUsdcInj)), 'Injective');
      expect(issuerText(identityOf('osmosis-1', 'uosmo')), 'Osmosis');
      expect(issuerText(identityOf('osmosis-1', unlisted)), 'Unknown');
      expect(issuerText(identityOf('osmosis-1', osmoUsdcN).copyWith(proven: false)), 'Noble (not verified)');
    });

    test('an exact amount states every digit that is signed', () {
      AmountScale scale(String chain, String denom) => AmountScale.of(identityOf(chain, denom));
      expect(exactAmountText(BigInt.parse('1123456789012345678'), scale('osmosis-1', osmoEthPica)),
          '1.123456789012345678');
      expect(exactAmountText('1500000', scale('osmosis-1', osmoUsdcN)), '1.5');
      expect(exactAmountText('12340000', scale('osmosis-1', unlisted)), '12340000 base units');
    });

    test('a pending transfer is labelled with its ticker and both chains', () {
      expect(transferLabel(BigInt.from(10000000), identityOf('osmosis-1', osmoUsdcN), 'Noble'),
          '10 USDC.n (Osmosis) → Noble');
      expect(transferLabel('1500000', identityOf('noble-1', 'uusdc'), 'Osmosis'), '1.5 USDC.n (Noble) → Osmosis');
      expect(transferLabel('12340000', identityOf('osmosis-1', unlisted), 'Noble'),
          '12340000 base units IBC·0123 (Osmosis) → Noble');
    });
  });

  group('withRegistryEnds', () {
    test('adds the far end of a registry channel, and only where a pin has none', () {
      const pins = [
        ManualChannel(fromChainId: 'injective-1', toChainId: 'osmosis-1', channelId: 'channel-8'),
        ManualChannel(fromChainId: 'osmosis-1', toChainId: 'noble-1', channelId: 'channel-750'),
        ManualChannel(fromChainId: 'injective-1', toChainId: 'osmosis-1', channelId: 'channel-6'),
        ManualChannel(
          fromChainId: 'osmosis-1',
          toChainId: 'noble-1',
          channelId: 'channel-750',
          counterpartyChannelId: 'channel-9',
        ),
        ManualChannel(fromChainId: 'osmosis-1', toChainId: 'noble-1', channelId: 'channel-750', port: 'wasm.osmo1xyz'),
      ];
      expect(
        [for (final pin in withRegistryEnds(pins)) '${pin.channelId}>${pin.counterpartyChannelId}'],
        ['channel-8>channel-122', 'channel-750>channel-1', 'channel-6>null', 'channel-750>channel-9', 'channel-750>null'],
      );
    });
  });

  group('routeNotes', () {
    test("drops the engine's 'entered by hand' note for the screen's own pin only", () {
      const own = ManualChannel(fromChainId: 'osmosis-1', toChainId: 'noble-1', channelId: 'channel-750');
      const typed = ManualChannel(fromChainId: 'noble-1', toChainId: 'osmosis-1', channelId: 'channel-1');
      final notes = routeNotes(
        const [
          'channel-750 on Osmosis $engineEnteredByHand',
          'channel-1 on Noble $engineEnteredByHand',
          'Something else',
        ],
        const [own, typed],
        const [typed],
        (chainId) => chainId == 'osmosis-1' ? 'Osmosis' : 'Noble',
      );
      expect(notes, ['channel-1 on Noble $engineEnteredByHand', 'Something else']);
    });
  });
}
