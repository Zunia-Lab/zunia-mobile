/// Governance: proposal parsing on both gov versions, the v1 → v1beta1
/// fallback, paging, the feed's filters and order, and the vote message.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/proposal_detail_screen.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/state/governance.dart';
import 'package:zunia_mobile/util/markdown_lite.dart';

const hub = ChainEntry(
  chainId: 'cosmoshub-4',
  chainName: 'Cosmos Hub',
  bech32Prefix: 'cosmos',
  coinType: 118,
  network: 'mainnet',
  coinDenom: 'ATOM',
  coinMinimalDenom: 'uatom',
  coinDecimals: 6,
  feeDenom: 'ATOM',
  feeMinimalDenom: 'uatom',
  feeDecimals: 6,
  rest: 'https://lcd.hub.test',
);

GovProposal p(
  String id, {
  String chainId = 'cosmoshub-4',
  GovStatus status = GovStatus.passed,
  String title = 'A proposal',
  String summary = '',
}) =>
    GovProposal(
      chainId: chainId,
      id: id,
      title: title,
      summary: summary,
      status: status,
    );

void main() {
  group('parsing', () {
    test('gov v1 reads title and summary, or the legacy content inside', () {
      final modern = proposalFromV1('cosmoshub-4', {
        'id': '981',
        'title': 'Upgrade',
        'summary': 'Do the thing',
        'status': 'PROPOSAL_STATUS_VOTING_PERIOD',
        'voting_end_time': '2026-10-20T10:00:00Z',
        'final_tally_result': {
          'yes_count': '0',
          'no_count': '0',
          'abstain_count': '0',
          'no_with_veto_count': '0',
        },
        'messages': [
          {'@type': '/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade'},
        ],
      });
      expect(modern.title, 'Upgrade');
      expect(modern.status, GovStatus.voting);
      expect(modern.votingEndTime, DateTime.utc(2026, 10, 20, 10));
      // All zeros during voting: no tally, not a 0/0/0/0 one.
      expect(modern.tally, isNull);
      expect(modern.messageTypes, ['/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade']);

      final legacy = proposalFromV1('cosmoshub-4', {
        'id': '12',
        'title': '',
        'status': 'PROPOSAL_STATUS_PASSED',
        'messages': [
          {
            '@type': '/cosmos.gov.v1.MsgExecLegacyContent',
            'content': {'title': 'Old style', 'description': 'From content'},
          },
        ],
        'final_tally_result': {'yes_count': '75', 'no_count': '25'},
        'submit_time': '0001-01-01T00:00:00Z',
      });
      expect(legacy.title, 'Old style');
      expect(legacy.summary, 'From content');
      expect(legacy.tally!.yes, 0.75);
      expect(legacy.tally!.leading, VoteOption.yes);
      expect(legacy.submitTime, isNull);
    });

    test('v1beta1 proposals and both vote shapes', () {
      final old = proposalFromV1beta1('juno-1', {
        'proposal_id': '7',
        'content': {'title': 'T', 'description': 'D'},
        'status': 'PROPOSAL_STATUS_REJECTED',
        'final_tally_result': {'yes': '1', 'no': '3'},
      });
      expect(old.status, GovStatus.rejected);
      expect(old.tally!.leading, VoteOption.no);

      expect(voteFrom({'option': 'VOTE_OPTION_NO_WITH_VETO'})!.single, VoteOption.veto);
      final split = voteFrom({
        'options': [
          {'option': 'VOTE_OPTION_YES', 'weight': '0.700000000000000000'},
          {'option': 'VOTE_OPTION_ABSTAIN', 'weight': '0.300000000000000000'},
        ],
      })!;
      expect(split.single, isNull);
      expect(split.options.first.weight, 0.7);
      expect(voteFrom({}), isNull);
    });
  });

  group('the client', () {
    test('falls back to v1beta1 once, then pages with the next key', () async {
      final asked = <Uri>[];
      Future<LcdResponse> fetch(Uri uri, Duration _) async {
        asked.add(uri);
        if (uri.path == '/cosmos/gov/v1/proposals') {
          return const LcdResponse(501, '{"code":12,"message":"Not Implemented"}');
        }
        if (uri.path == '/cosmos/gov/v1beta1/proposals') {
          final key = uri.queryParameters['pagination.key'];
          return LcdResponse(
            200,
            jsonEncode({
              'proposals': [
                {
                  'proposal_id': key == null ? '9' : '3',
                  'content': {'title': 'P'},
                  'status': 'PROPOSAL_STATUS_PASSED',
                },
              ],
              'pagination': {'next_key': key == null ? 'AAE=' : null},
            }),
          );
        }
        return const LcdResponse(404, '{}');
      }

      final client = GovernanceClient(ChainReader(readsAllowed: () => true, fetch: fetch));
      final first = await client.proposals(hub);
      expect(first.rows.single.id, '9');
      expect(first.nextKey, 'AAE=');
      final v1Asks = asked.where((u) => u.path.contains('/v1/')).length;
      final second = await client.proposals(hub, key: first.nextKey);
      expect(second.rows.single.id, '3');
      expect(second.nextKey, isNull);
      // v1 is remembered as missing: the second page goes straight to v1beta1.
      expect(asked.where((u) => u.path.contains('/v1/')).length, v1Asks);
      expect(asked.last.queryParameters['pagination.key'], 'AAE=');
      expect(asked.last.queryParameters['pagination.reverse'], 'true');
    });

    test('no vote recorded is null, not an error', () async {
      Future<LcdResponse> fetch(Uri uri, Duration _) async =>
          const LcdResponse(404, '{"code":5,"message":"vote not found"}');
      final client = GovernanceClient(ChainReader(readsAllowed: () => true, fetch: fetch));
      expect(await client.vote(hub, '1', 'cosmos1x'), isNull);
    });

    test('live reads off reads nothing', () async {
      var asked = 0;
      Future<LcdResponse> fetch(Uri uri, Duration _) async {
        asked++;
        return const LcdResponse(200, '{}');
      }

      final client = GovernanceClient(ChainReader(readsAllowed: () => false, fetch: fetch));
      await expectLater(
        client.proposals(hub),
        throwsA(isA<ChainReadError>().having((e) => e.kind, 'kind', ChainReadErrorKind.disabled)),
      );
      expect(asked, 0);
    });
  });

  group('the feed', () {
    final rows = [
      p('5', status: GovStatus.passed, title: 'Fund the pool'),
      p('9', status: GovStatus.voting, title: 'Raise gas floor'),
      p('7', status: GovStatus.rejected, title: 'Spam'),
      p('2', chainId: 'osmosis-1', status: GovStatus.voting, title: 'Incentives'),
      p('8', status: GovStatus.deposit, title: 'Needs deposit', summary: 'community pool'),
    ];

    test('open votes first, then newest id first', () {
      expect(
        visibleProposals(rows).map((x) => x.key),
        ['cosmoshub-4:9', 'osmosis-1:2', 'cosmoshub-4:8', 'cosmoshub-4:7', 'cosmoshub-4:5'],
      );
    });

    test('filters by network, status and search', () {
      expect(visibleProposals(rows, network: 'osmosis-1').map((x) => x.id), ['2']);
      expect(visibleProposals(rows, filter: GovFilter.voting).map((x) => x.id), ['9', '2']);
      expect(visibleProposals(rows, filter: GovFilter.passed).map((x) => x.id), ['5']);
      expect(visibleProposals(rows, filter: GovFilter.rejected).map((x) => x.id), ['7']);
      expect(visibleProposals(rows, filter: GovFilter.deposit).map((x) => x.id), ['8']);
      expect(visibleProposals(rows, query: '#7').map((x) => x.id), ['7']);
      expect(visibleProposals(rows, query: 'gas').map((x) => x.id), ['9']);
      expect(visibleProposals(rows, query: 'community').map((x) => x.id), ['8']);
      expect(
        visibleProposals(rows, query: 'osmosis', chainNames: const {'osmosis-1': 'Osmosis'})
            .map((x) => x.id),
        ['2'],
      );
    });

    test('pages ten at a time, then asks the chains for more', () {
      expect(
        nextGovernancePage(shown: 10, available: 25, chainsHaveMore: true),
        (count: 20, fetch: false),
      );
      expect(
        nextGovernancePage(shown: 20, available: 25, chainsHaveMore: false),
        (count: 25, fetch: false),
      );
      expect(
        nextGovernancePage(shown: 25, available: 25, chainsHaveMore: true),
        (count: 25, fetch: true),
      );
      expect(
        nextGovernancePage(shown: 25, available: 25, chainsHaveMore: false),
        (count: 25, fetch: false),
      );
    });
  });

  group('proposal text', () {
    test('markdown becomes blocks of plain text, never markup', () {
      final blocks = parseMarkdown(
        '# Title\n\nSome **bold** and a [link](https://forum.example/t/1).\n'
        '- one\n- two\n\n> quoted\n\n```\ncode\n```\n---\n'
        '[bad](javascript:alert(1)) and https://www.example.com/a/very/long/path/that/goes/on/and/on',
      );
      expect(blocks.map((b) => b.kind), [
        MdBlockKind.heading,
        MdBlockKind.paragraph,
        MdBlockKind.list,
        MdBlockKind.quote,
        MdBlockKind.code,
        MdBlockKind.rule,
        MdBlockKind.paragraph,
      ]);
      final para = blocks[1].children;
      expect(para.firstWhere((r) => r.kind == MdInlineKind.strong).plain, 'bold');
      expect(para.firstWhere((r) => r.kind == MdInlineKind.link).href, 'https://forum.example/t/1');
      // A javascript: link keeps its text and loses its target.
      final last = blocks.last.children;
      expect(last.where((r) => r.kind == MdInlineKind.link).map((r) => r.href),
          ['https://www.example.com/a/very/long/path/that/goes/on/and/on']);
      expect(last.map((r) => r.plain).join(), startsWith('bad'));
      expect(last.map((r) => r.href), isNot(contains(startsWith('javascript'))));
      expect(displayMarkdownHref('https://www.example.com/a/very/long/path/that/goes/on/and/on'),
          endsWith('…'));
    });

    test('pasted HTML is read as text', () {
      final blocks = parseMarkdown('<p>Hello <strong>there</strong></p><ul><li>a</li><li>b</li></ul>');
      expect(blocks.first.children.map((r) => r.plain).join(), 'Hello there');
      expect(blocks.any((b) => b.kind == MdBlockKind.list), isTrue);
      expect(parseMarkdown('<script>alert(1)</script><p>ok</p>').map((b) => b.children.map((r) => r.plain).join()),
          ['alert(1)ok']);
    });
  });

  test('a vote signs its option as the number chains verify', () {
    final msg = voteMsgs(voter: 'cosmos1v', proposalId: '981', option: VoteOption.veto).single;
    expect(msg.toJson(), {
      'typeUrl': '/cosmos.gov.v1beta1.MsgVote',
      'value': {'proposal_id': '981', 'voter': 'cosmos1v', 'option': 4},
    });
    expect([for (final o in VoteOption.values) o.code], [1, 2, 3, 4]);
    expect(VoteOption.fromWire('VOTE_OPTION_ABSTAIN'), VoteOption.abstain);
  });
}
