import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';
import 'package:zunia_mobile/transfers/channel_verdict.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';

import '../support/catalog.dart';

/// Which channels a send to another chain may cross: the extension's
/// channel-verdict and route-plan suites (0.1.5), against a two-chain LCD with
/// the live Injective and Osmosis channel numbers. channel-5/channel-109 is the
/// pair whose light clients expired while both ends still read STATE_OPEN.
const dest = 'osmosis-1';

IbcChannelCheck check({
  bool ok = true,
  IbcChannelState state = IbcChannelState.open,
  String counterpartyChannelId = 'channel-0',
  String? counterpartyChainId = dest,
  String message = 'Open, connected to osmosis-1',
  CounterpartyCheck? counterparty,
}) =>
    IbcChannelCheck(
      ok: ok,
      state: state,
      channelId: 'channel-141',
      portId: 'transfer',
      counterpartyChannelId: counterpartyChannelId,
      counterpartyChainId: counterpartyChainId,
      message: message,
      counterparty: counterparty,
    );

CounterpartyCheck farSide({
  CounterpartyCheckStatus status = CounterpartyCheckStatus.ok,
  String? chainId = dest,
  String message = 'Confirmed on osmosis-1',
}) =>
    CounterpartyCheck(
      status: status,
      ok: status == CounterpartyCheckStatus.ok,
      chainId: chainId,
      channelId: 'channel-0',
      portId: 'transfer',
      state: IbcChannelState.open,
      pointsBackTo: 'channel-141',
      message: message,
    );

/// chain → channel → (counterparty chain, counterparty channel, client).
const channels = <String, Map<String, (String, String, String)>>{
  'injective-1': {
    'channel-5': ('osmosis-1', 'channel-109', '07-tendermint-11'),
    'channel-8': ('osmosis-1', 'channel-122', '07-tendermint-19'),
  },
  'osmosis-1': {
    'channel-109': ('injective-1', 'channel-5', '07-tendermint-1617'),
    'channel-122': ('injective-1', 'channel-8', '07-tendermint-1703'),
  },
};

class FakeLcd implements LcdClient {
  FakeLcd(this.chainId, this.clientStatus, {this.statusAnswer});

  @override
  final String chainId;
  final Map<String, String> clientStatus;

  /// Replaces the `client_status` answer: (HTTP status, body).
  final (int, Object?)? statusAnswer;

  Never _fail(int status) => throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'HTTP $status',
        chainId: chainId,
        httpStatus: status,
      );

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    final rows = channels[chainId] ?? const {};
    final byClient = rows.values.where((row) => path.endsWith('/${row.$3}')).firstOrNull;
    var match = RegExp(r'/channels/(channel-\d+)/ports/transfer(/client_state)?$').firstMatch(path);
    if (match != null) {
      final row = rows[match.group(1)];
      if (row == null) _fail(404);
      if (match.group(2) != null) {
        return {
          'identified_client_state': {
            'client_id': row.$3,
            'client_state': {'chain_id': row.$1},
          },
        };
      }
      return {
        'channel': {
          'state': 'STATE_OPEN',
          'counterparty': {'port_id': 'transfer', 'channel_id': row.$2},
          'connection_hops': ['connection-${row.$3}'],
        },
      };
    }
    match = RegExp(r'/connections/connection-(.+)$').firstMatch(path);
    if (match != null) {
      return {
        'connection': {'client_id': match.group(1)},
      };
    }
    if (path.contains('/client_states/') && byClient != null) {
      return {
        'client_state': {'chain_id': byClient.$1},
      };
    }
    if (path.contains('/client_status/') && byClient != null) {
      final answer = statusAnswer;
      if (answer != null) {
        if (answer.$1 != 200) _fail(answer.$1);
        return answer.$2;
      }
      return {'status': clientStatus[byClient.$3] ?? 'Active'};
    }
    _fail(501);
  }
}

class ReadsOffLcd implements LcdClient {
  @override
  String get chainId => 'osmosis-1';

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async =>
      throw InterchainError(InterchainErrorCode.readsDisabled, 'reads off');
}

void main() {
  setUpAll(loadBundledData);

  group('classifyChannelCheck', () {
    test('verifies a channel the far side confirms', () {
      final verdict = classifyChannelCheck(check(counterparty: farSide()), dest);
      expect(verdict.kind, ChannelVerdictKind.verified);
      expect(verdict.note, 'Confirmed on osmosis-1');
      expect(verdict.counterpartyChannelId, 'channel-0');
      expect(verdictAllowsUse(verdict), isTrue);
    });

    test("does not verify on the source chain's word alone", () {
      final verdict =
          classifyChannelCheck(check(counterparty: farSide(status: CounterpartyCheckStatus.unreachable)), dest);
      expect(verdict.kind, ChannelVerdictKind.openUnconfirmed);
      expect(verdict.note, contains('could not be asked'));
      expect(verdictAllowsUse(verdict), isTrue);
    });

    test('says so when nothing named the far chain', () {
      final verdict = classifyChannelCheck(check(counterpartyChainId: null, message: 'Open and ready'), dest);
      expect(verdict.kind, ChannelVerdictKind.openUnconfirmed);
      expect(verdict.note, contains('nothing confirmed that it leads to $dest'));
    });

    test('does not take a far side on another chain as confirmation', () {
      expect(classifyChannelCheck(check(counterparty: farSide(chainId: 'juno-1')), dest).kind,
          ChannelVerdictKind.openUnconfirmed);
    });

    test('rejects a channel the chain does not know, and an empty entry', () {
      const messages = ChannelMessages();
      for (final message in [messages.notFound, messages.emptyInput]) {
        final verdict = classifyChannelCheck(check(ok: false, state: IbcChannelState.unknown, message: message), dest);
        expect(verdict.kind, ChannelVerdictKind.rejected);
        expect(verdictAllowsUse(verdict), isFalse);
      }
    });

    test('rejects a closed channel, a wrong chain, and a far side that disagrees', () {
      for (final failed in [
        check(ok: false, state: IbcChannelState.closed, message: 'Channel is closed'),
        check(ok: false, counterpartyChainId: 'juno-1', message: 'Connected to juno-1'),
        check(
          ok: false,
          message: 'Points somewhere else',
          counterparty: farSide(status: CounterpartyCheckStatus.mismatch),
        ),
      ]) {
        expect(classifyChannelCheck(failed, dest).kind, ChannelVerdictKind.rejected);
      }
    });

    test('calls an unreachable chain inconclusive, not wrong', () {
      const messages = ChannelMessages();
      for (final message in [messages.unreachable, messages.noEndpoint, messages.readsDisabled]) {
        final verdict = classifyChannelCheck(check(ok: false, state: IbcChannelState.unknown, message: message), dest);
        expect(verdict.kind, ChannelVerdictKind.inconclusive);
        expect(verdict.note, contains('Nothing confirmed this channel'));
        expect(verdictAllowsUse(verdict), isTrue);
      }
    });

    test('leaves the counterparty id out when the chain did not give one', () {
      expect(classifyChannelCheck(check(counterpartyChannelId: '', counterparty: farSide()), dest).counterpartyChannelId,
          isNull);
    });
  });

  group('canonical channel seeds', () {
    List<String> rows() => [
          for (final row in TokenRegistry.instance!.channelRows)
            '${row.sourceChainId} ${row.channelId} > ${row.destChainId} ${row.counterpartyChannelId}',
        ];

    test('hold the pairs the audit verified live, in both directions', () {
      expect(
        rows(),
        containsAll([
          'injective-1 channel-8 > osmosis-1 channel-122',
          'osmosis-1 channel-122 > injective-1 channel-8',
          'noble-1 channel-1 > osmosis-1 channel-750',
          'osmosis-1 channel-750 > noble-1 channel-1',
          'axelar-dojo-1 channel-3 > osmosis-1 channel-208',
          'osmosis-1 channel-208 > axelar-dojo-1 channel-3',
          'cosmoshub-4 channel-141 > osmosis-1 channel-0',
          'osmosis-1 channel-0 > cosmoshub-4 channel-141',
        ]),
      );
    });

    test('leave out the parallel channels whose clients expired', () {
      final registry = TokenRegistry.instance!;
      expect(registry.canonicalChannelIds('osmosis-1', 'injective-1'), ['channel-122']);
      expect(registry.canonicalChannelIds('injective-1', 'osmosis-1'), ['channel-8']);
      expect(registry.isCanonicalHop('osmosis-1', 'channel-109', 'injective-1'), isFalse);
    });

    test('name each channel end once, every row mirrored', () {
      final ends = [for (final row in TokenRegistry.instance!.channelRows) '${row.sourceChainId} ${row.channelId}'];
      expect(ends.toSet().length, ends.length);
      final keys = rows().toSet();
      for (final row in TokenRegistry.instance!.channelRows) {
        expect(
          keys.contains('${row.destChainId} ${row.counterpartyChannelId} > ${row.sourceChainId} ${row.channelId}'),
          isTrue,
        );
      }
    });
  });

  group('routableLinks', () {
    ChannelLink link(String channelId, ChannelLinkSource source, [String destChainId = 'osmosis-1']) => ChannelLink(
          sourceChainId: 'injective-1',
          destChainId: destChainId,
          channelId: channelId,
          port: 'transfer',
          source: source,
        );
    RoutingKnowledge knowledge([List<String> refused = const []]) => RoutingKnowledge(
          canonical: (source, destination) =>
              source == 'injective-1' && destination == 'osmosis-1' ? const ['channel-8'] : const [],
          refused: (candidate) => refused.contains(candidate.channelId),
        );

    test('keeps only the canonical and manual channels of a canonical pair', () {
      final links = [
        link('channel-5', ChannelLinkSource.verified),
        link('channel-8', ChannelLinkSource.seed),
        link('channel-6', ChannelLinkSource.manual),
      ];
      expect(routableLinks(links, knowledge()).map((l) => l.channelId), ['channel-8', 'channel-6']);
    });

    test('falls back to the other channels when the canonical one is ruled out', () {
      final links = [link('channel-5', ChannelLinkSource.verified), link('channel-8', ChannelLinkSource.seed)];
      expect(routableLinks(links, knowledge(['channel-8'])).map((l) => l.channelId), ['channel-5']);
    });

    test('leaves pairs the registry does not name alone, minus refused channels', () {
      final links = [
        link('channel-40', ChannelLinkSource.verified, 'noble-1'),
        link('channel-41', ChannelLinkSource.seed, 'noble-1'),
      ];
      expect(routableLinks(links, knowledge(['channel-41'])).map((l) => l.channelId), ['channel-40']);
    });

    test('filters the reverse links the directory derives, too', () {
      final directory = createChannelDirectory(const [
        ChannelLink(
          sourceChainId: 'osmosis-1',
          destChainId: 'injective-1',
          channelId: 'channel-109',
          counterpartyChannelId: 'channel-5',
          source: ChannelLinkSource.verified,
        ),
        ChannelLink(
          sourceChainId: 'osmosis-1',
          destChainId: 'injective-1',
          channelId: 'channel-122',
          counterpartyChannelId: 'channel-8',
          source: ChannelLinkSource.seed,
        ),
      ]);
      expect(routableLinks(directory.from('injective-1'), knowledge()).map((l) => l.channelId), ['channel-8']);
    });
  });

  group('the channel graph against two chains', () {
    late Map<String, String> status;
    late List<ChannelRoute> stored;
    late TransferPlanner planner;
    (int, Object?)? statusAnswer;

    TransferPlanner build() {
      LcdClient lcd(String chainId) => FakeLcd(chainId, status, statusAnswer: statusAnswer);
      final registry = CatalogChainRegistry(ChainCatalog.instance);
      return TransferPlanner(TransferPlannerDeps(
        registry: registry,
        channels: IbcChannelService(lcd: (chain) => lcd(chain.chainId), registry: registry),
        routes: () => stored,
        rememberRoutes: (rows) async => stored = [...stored, ...rows],
        lcdFor: lcd,
        resolveDenom: null,
        probeCapabilities: (_) async {},
        capabilities: (_) => null,
      ));
    }

    void cacheExpiredPair() {
      final now = DateTime.now().millisecondsSinceEpoch;
      stored = [
        ChannelRoute(
          sourceChainId: 'injective-1',
          destChainId: 'osmosis-1',
          channelId: 'channel-5',
          counterpartyChannelId: 'channel-109',
          verifiedAt: now,
          source: ChannelRouteSource.discovered,
        ),
        ChannelRoute(
          sourceChainId: 'osmosis-1',
          destChainId: 'injective-1',
          channelId: 'channel-109',
          counterpartyChannelId: 'channel-5',
          verifiedAt: now,
          source: ChannelRouteSource.discovered,
        ),
      ];
    }

    List<String> channelsTo(List<ChannelLink> links, String destination) =>
        [for (final link in links) if (link.destChainId == destination) link.channelId];

    setUp(() {
      status = {'07-tendermint-11': 'Expired', '07-tendermint-1617': 'Expired'};
      stored = [];
      statusAnswer = null;
      planner = build();
    });

    test('reads the client and its status', () async {
      final read = await readChannelClient(FakeLcd('osmosis-1', status), 'osmosis-1', 'channel-122', 'transfer');
      expect(read.kind, ChannelClientReadKind.ok);
      expect(read.clientId, '07-tendermint-1703');
      expect(read.trackedChainId, 'injective-1');
      expect(read.status, 'Active');
      final expired = await readChannelClient(FakeLcd('osmosis-1', status), 'osmosis-1', 'channel-109', 'transfer');
      expect(expired.status, 'Expired');
    });

    test('calls a route the node does not serve unsupported', () async {
      for (final code in [404, 405, 501]) {
        final read = await readChannelClient(
          FakeLcd('osmosis-1', status, statusAnswer: (code, {'code': 12})),
          'osmosis-1',
          'channel-122',
          'transfer',
        );
        expect(read.kind, ChannelClientReadKind.unsupported, reason: '$code');
      }
    });

    test('calls anything else unreachable, never an answer', () async {
      for (final answer in <(int, Object?)>[
        (503, {'message': 'unavailable'}),
        (400, {'message': 'bad request'}),
        (200, <String, Object?>{}),
        (200, {'status': ''}),
      ]) {
        final read = await readChannelClient(
          FakeLcd('osmosis-1', status, statusAnswer: answer),
          'osmosis-1',
          'channel-122',
          'transfer',
        );
        expect(read.kind, ChannelClientReadKind.unreachable, reason: '$answer');
      }
      expect((await readChannelClient(null, 'nowhere-1', 'channel-0', 'transfer')).kind,
          ChannelClientReadKind.unreachable);
    });

    test('throws when live reads are off, so a plan says why instead of guessing', () async {
      await expectLater(
        readChannelClient(ReadsOffLcd(), 'osmosis-1', 'channel-122', 'transfer'),
        throwsA(isA<InterchainError>().having((e) => e.code, 'code', InterchainErrorCode.readsDisabled)),
      );
    });

    test('prefers canonical channel-8 over a cached channel-5, in both directions', () {
      cacheExpiredPair();
      final directory = planner.channelDirectory();
      expect(channelsTo(directory.from('injective-1'), 'osmosis-1'), ['channel-8']);
      expect(channelsTo(directory.from('osmosis-1'), 'injective-1'), ['channel-122']);
    });

    test('keeps a channel the user entered next to the canonical one', () {
      stored = const [
        ChannelRoute(
          sourceChainId: 'injective-1',
          destChainId: 'osmosis-1',
          channelId: 'channel-6',
          counterpartyChannelId: '',
          verifiedAt: 0,
          source: ChannelRouteSource.manual,
        ),
      ];
      final directory = planner.channelDirectory();
      expect(channelsTo(directory.from('injective-1'), 'osmosis-1')..sort(), ['channel-6', 'channel-8']);
    });

    test('refuses a channel whose light client expired, though both ends read open', () async {
      cacheExpiredPair();
      final hop = await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-5');
      expect(hop.verdict, ChannelHopVerdict.clientInactive);
      expect(hop.usable, isFalse);
      expect(
        hop.message,
        'Zunia will not use channel-5 from Injective to Osmosis. Its light client on Injective is expired, '
        'so nothing sent over it can arrive.',
      );
    });

    test("refuses a channel whose far end's client expired", () async {
      status = {'07-tendermint-1617': 'Expired'};
      planner = build();
      final hop = await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-5');
      expect(hop.usable, isFalse);
      expect(hop.message, contains('Its light client on Osmosis is expired'));
    });

    test('confirms the canonical channel and records it as verified', () async {
      final hop = await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-8');
      expect(hop.verdict, ChannelHopVerdict.active);
      expect(hop.counterpartyChannelId, 'channel-122');
      final row = stored.single;
      expect(row.channelId, 'channel-8');
      expect(row.source, ChannelRouteSource.discovered);
      expect(row.verifiedAt, greaterThan(0));
      expect(row.counterpartyChannelId, 'channel-122');
    });

    test('drops a channel this session found expired, and falls back to the rest', () async {
      cacheExpiredPair();
      status['07-tendermint-19'] = 'Expired';
      planner = build();
      expect((await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-8')).verdict,
          ChannelHopVerdict.clientInactive);
      final directory = planner.channelDirectory();
      expect(channelsTo(directory.from('injective-1'), 'osmosis-1'), ['channel-5']);
    });

    test('uses the canonical channel when a node will not report client status, with a caveat', () async {
      statusAnswer = (501, {'code': 12});
      planner = build();
      final canonical = await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-8');
      expect(canonical.verdict, ChannelHopVerdict.activeUnconfirmed);
      expect(canonical.usable, isTrue);
      expect(canonical.warning, contains("canonical channel for this pair"));
      final other = await planner.checkChannelHop('injective-1', 'osmosis-1', 'channel-5');
      expect(other.verdict, ChannelHopVerdict.statusUnreadable);
      expect(other.usable, isFalse);
    });

    test('plans a direct transfer over the canonical channel and checks it on both chains', () async {
      final result = await planner.planTransfer(PlanInput(
        sourceChainId: 'injective-1',
        destChainId: 'osmosis-1',
        inputDenom: 'inj',
        amountBaseUnits: '1000000000000000000',
        sender: 'inj1sender',
        recipient: 'osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw',
        resolveAddresses: (_) async => const {},
      ));
      expect(result.error, isNull);
      final best = result.best!;
      expect(best.plan.hops.single.channelId, 'channel-8');
      expect(best.blockedReason, isNull);
      expect(best.hops.single.channelVerified, isTrue);
      expect(best.plan.requiresPfm, isFalse);
    });

    test('blocks a plan over a channel the user pinned when the chains refuse it', () async {
      final result = await planner.planTransfer(PlanInput(
        sourceChainId: 'injective-1',
        destChainId: 'osmosis-1',
        inputDenom: 'inj',
        amountBaseUnits: '1',
        sender: 'inj1sender',
        recipient: 'osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw',
        manualChannels: const [
          ManualChannel(fromChainId: 'injective-1', toChainId: 'osmosis-1', channelId: 'channel-5'),
        ],
        resolveAddresses: (_) async => const {},
      ));
      final best = result.best!;
      expect(best.plan.hops.single.channelId, 'channel-5');
      expect(best.failedCheck?.verdict, ChannelHopVerdict.clientInactive);
      expect(best.blockedReason, contains('Its light client on Injective is expired'));
    });
  });
}
