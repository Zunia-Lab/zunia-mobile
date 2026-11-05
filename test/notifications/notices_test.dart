/// The notice engine's pure rules, ported case for case from
/// zunia-extension/lib/__tests__/notices.test.ts so both products alert on
/// the same things.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';

final t0 = DateTime.utc(2026, 10, 5, 9).millisecondsSinceEpoch;
const day = 86400000;

RewardsReading chain(
  String chainId,
  String rewards, {
  bool failed = false,
}) =>
    RewardsReading(
      chainId: chainId,
      rewards: rewards,
      decimals: chainId == 'injective-1' ? 18 : 6,
      failed: failed,
    );

/// Feed the cycle one look per block.
List<RewardsNoticeState> run(
  List<List<RewardsReading>> looks, {
  RewardsNoticeState start = RewardsNoticeState.initial,
  int? repeatMs,
}) {
  var state = start;
  final states = <RewardsNoticeState>[];
  for (var i = 0; i < looks.length; i++) {
    state = nextRewardsNotice(state, looks[i], t0 + i * 6000, repeatMs: repeatMs);
    states.add(state);
  }
  return states;
}

List<Notice> feed(
  RewardsNoticeState rewards, {
  bool unlocked = true,
  List<ApprovalNoticeInput> approvals = const [],
  List<ProposalNoticeInput> proposals = const [],
  List<UnbondingNoticeInput> unbonding = const [],
  List<ArrivalNotice> arrivals = const [],
  List<ReceivedNoticeInput> received = const [],
  List<String> read = const [],
  NotifyPrefs? prefs,
}) =>
    deriveNotices(
      NoticeInput(
        approvals: approvals,
        chainNames: const {'cosmoshub-4': 'Cosmos Hub', 'osmosis-1': 'Osmosis'},
        received: received,
        proposals: proposals,
        unbonding: unbonding,
        arrivals: arrivals,
        read: read,
        now: t0,
        rewards: rewards,
        prefs: prefs,
        unlocked: unlocked,
      ),
    );

void main() {
  group('the claimable-rewards notice', () {
    test('is raised once, and stays the same notice while rewards grow', () {
      final states = run([
        [chain('cosmoshub-4', '0')],
        [chain('cosmoshub-4', '1200')],
        [chain('cosmoshub-4', '1350')],
        [chain('cosmoshub-4', '1500')],
        [chain('cosmoshub-4', '2500000')],
      ]);
      expect(states.map((s) => s.phase), [
        RewardsPhase.waiting,
        RewardsPhase.raised,
        RewardsPhase.raised,
        RewardsPhase.raised,
        RewardsPhase.raised,
      ]);
      expect(states.skip(1).map((s) => s.cycle).toSet(), {1});
      final ids = {
        for (final s in states.skip(1)) ...feed(s).map((n) => n.id),
      };
      expect(ids, {'rewards:1'});
    });

    test('names no token and no amount, and leads to Earn', () {
      final state = run([
        [chain('cosmoshub-4', '4210000')],
      ]).single;
      final row = feed(state).single;
      expect(row.title, 'Staking rewards ready to claim');
      expect('${row.title} ${row.meta}', isNot(matches(RegExp('ATOM|4\\.21|Cosmos Hub'))));
      expect(row.target, const NoticeTarget(NoticeRoute.earn));
    });

    test('re-arms after a claim and waits for a whole token', () {
      final states = run([
        [chain('cosmoshub-4', '3000000')],
        [chain('cosmoshub-4', '40')],
        [chain('cosmoshub-4', '900000')],
        [chain('cosmoshub-4', '999999')],
        [chain('cosmoshub-4', '1000000')],
      ]);
      expect(states.map((s) => s.phase), [
        RewardsPhase.raised,
        RewardsPhase.rearmed,
        RewardsPhase.rearmed,
        RewardsPhase.rearmed,
        RewardsPhase.raised,
      ]);
      expect(states[4].cycle, 2);
      expect(feed(states[1]), isEmpty);
    });

    test('re-arms when nothing is claimable any more', () {
      final states = run([
        [chain('cosmoshub-4', '500')],
        [chain('cosmoshub-4', '0')],
      ]);
      expect(states.map((s) => s.phase), [RewardsPhase.raised, RewardsPhase.rearmed]);
    });

    test('keeps the notice when only part of the rewards was claimed', () {
      final states = run([
        [chain('cosmoshub-4', '3000000'), chain('injective-1', '2000000000000000000')],
        [chain('cosmoshub-4', '10'), chain('injective-1', '2000000000000000500')],
      ]);
      expect(states.map((s) => s.phase), [RewardsPhase.raised, RewardsPhase.raised]);
      expect(states[1].cycle, 1);
    });

    test('does not take a failed read or a locked wallet for a claim', () {
      final states = run([
        [chain('cosmoshub-4', '3000000')],
        [chain('cosmoshub-4', '0', failed: true)],
        [],
        [chain('cosmoshub-4', '3000100')],
      ]);
      expect(states.map((s) => s.phase).toSet(), {RewardsPhase.raised});
      expect(states[3].cycle, 1);
    });

    test('is not shown while the wallet is locked', () {
      final state = run([
        [chain('cosmoshub-4', '3000000')],
      ]).single;
      expect(feed(state, unlocked: false), isEmpty);
    });

    test('comes back daily or weekly when the user asked for reminders', () {
      expect(reminderInterval(RewardReminder.once), isNull);
      expect(reminderInterval(RewardReminder.off), isNull);
      expect(reminderInterval(RewardReminder.daily), day);
      expect(reminderInterval(RewardReminder.weekly), 7 * day);
      var state = nextRewardsNotice(
        RewardsNoticeState.initial,
        [chain('cosmoshub-4', '5')],
        t0,
        repeatMs: day,
      );
      state = nextRewardsNotice(state, [chain('cosmoshub-4', '9')], t0 + day - 1, repeatMs: day);
      expect(state.cycle, 1);
      state = nextRewardsNotice(state, [chain('cosmoshub-4', '12')], t0 + day, repeatMs: day);
      expect(state.phase, RewardsPhase.raised);
      expect(state.cycle, 2);
      expect(state.raisedAt, t0 + day);
    });

    test('reads back what it stored, and starts over on anything else', () {
      final stored = {
        'phase': 'rearmed',
        'cycle': 3,
        'raisedAt': t0,
        'last': {'cosmoshub-4': '12', 'bad': '1.5'},
      };
      expect(
        parseRewardsNotice(stored),
        RewardsNoticeState(
          phase: RewardsPhase.rearmed,
          cycle: 3,
          raisedAt: t0,
          last: const {'cosmoshub-4': '12'},
        ),
      );
      for (final junk in [
        null,
        'raised',
        {'phase': 'loud', 'cycle': 1},
        {'phase': 'raised', 'cycle': -1},
      ]) {
        expect(parseRewardsNotice(junk), RewardsNoticeState.initial);
      }
    });
  });

  group('notification preferences', () {
    const raised = RewardsNoticeState(
      phase: RewardsPhase.raised,
      cycle: 4,
      raisedAt: 0,
      last: {},
    );
    final approval = ApprovalNoticeInput(
      id: 'a1',
      origin: 'https://app.osmosis.zone',
      title: 'Sign a swap',
      createdAt: t0,
    );
    final proposal = ProposalNoticeInput(
      chainId: 'cosmoshub-4',
      id: '981',
      title: 'Upgrade',
      voting: true,
      votingEndTime: DateTime.fromMillisecondsSinceEpoch(t0 + 3 * day),
    );

    test('drop the kinds the user turned off, and always keep approvals', () {
      const off = NotifyPrefs(
        transfers: false,
        unbonding: false,
        governance: false,
        rewards: RewardReminder.off,
      );
      final rows = feed(raised, approvals: [approval], proposals: [proposal], prefs: off);
      expect(rows.map((r) => r.kind), [NoticeKind.approval]);
      expect(rows.single.meta, 'app.osmosis.zone · waiting for you');

      const everything = NotifyPrefs(
        transfers: true,
        unbonding: true,
        governance: true,
        rewards: RewardReminder.once,
      );
      final all = feed(raised, approvals: [approval], proposals: [proposal], prefs: everything);
      expect(all.map((r) => r.kind).toSet(), {
        NoticeKind.approval,
        NoticeKind.governance,
        NoticeKind.rewards,
      });
      final gov = all.firstWhere((r) => r.kind == NoticeKind.governance);
      expect(gov.title, 'Proposal 981 ends in 3d');
      expect(gov.meta, 'Cosmos Hub · Upgrade');
    });

    test('are quiet by default: transfers and one rewards notice', () {
      expect(
        NotifyPrefs.defaults,
        const NotifyPrefs(
          transfers: true,
          unbonding: false,
          governance: false,
          rewards: RewardReminder.once,
        ),
      );
      final rows = feed(
        raised,
        approvals: [approval],
        proposals: [proposal],
        prefs: NotifyPrefs.defaults,
      );
      expect(rows.map((r) => r.kind).toSet(), {NoticeKind.approval, NoticeKind.rewards});
    });

    test('parse stored values field by field', () {
      expect(parseNotifyPrefs(null), NotifyPrefs.defaults);
      expect(
        parseNotifyPrefs({'transfers': false, 'rewards': 'weekly', 'governance': 'yes'}),
        NotifyPrefs.defaults.copyWith(transfers: false, rewards: RewardReminder.weekly),
      );
      expect(parseNotifyPrefs({'rewards': 'hourly'}).rewards, RewardReminder.once);
    });
  });

  group('feed rows', () {
    test('a socket arrival and the history row for it are one notice', () {
      final rows = feed(
        RewardsNoticeState.initial,
        arrivals: [
          ArrivalNotice(
            chainId: 'osmosis-1',
            hash: 'H1',
            coins: const [MovedCoin('uosmo', '1500000')],
            at: t0,
          ),
        ],
        received: [
          ReceivedNoticeInput(
            chainId: 'osmosis-1',
            hash: 'H1',
            meta: 'history says so',
            timestamp: t0 - 1000,
          ),
        ],
      );
      expect(rows.map((r) => r.id), ['transfer:H1']);
      expect(rows.single.title, 'Received on Osmosis');
      // The socket's row wins: it is the one with the live timestamp.
      expect(rows.single.timestamp, t0);
      expect(rows.single.target, const NoticeTarget(NoticeRoute.chain, chainId: 'osmosis-1'));
    });

    test('a coin nothing names stays in base units, never scaled', () {
      expect(
        describeCoinRaw(
          'osmosis-1',
          const MovedCoin(
            'ibc/0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
            '12340000',
          ),
        ),
        '12340000 base units ibc/0123…ABCDEF',
      );
    });

    test('unbonding says how long is left, then that it is liquid', () {
      final soon = DateTime.fromMillisecondsSinceEpoch(t0 + 2 * day + 5).toUtc();
      final past = DateTime.fromMillisecondsSinceEpoch(t0 - day).toUtc();
      UnbondingNoticeInput entry(DateTime at) => UnbondingNoticeInput(
            chainId: 'cosmoshub-4',
            validatorAddress: 'cosmosvaloper1x',
            amount: '2500000',
            decimals: 6,
            symbol: 'ATOM',
            completionTime: at.toIso8601String(),
          );
      final rows = feed(
        RewardsNoticeState.initial,
        unbonding: [entry(soon), entry(past)],
        prefs: NotifyPrefs.defaults.copyWith(unbonding: true),
      );
      expect(rows.map((r) => r.title).toSet(), {'Unbonding in progress', 'Unbonding complete'});
      expect(rows.firstWhere((r) => r.title == 'Unbonding in progress').meta, '2.5 ATOM · 3d left');
      expect(rows.firstWhere((r) => r.title == 'Unbonding complete').meta, '2.5 ATOM is liquid again');
    });

    test('read rows sort below unread, newest first within each', () {
      final rows = feed(
        RewardsNoticeState.initial,
        arrivals: [
          for (final (hash, at) in [('A', t0 - 3000), ('B', t0 - 2000), ('C', t0 - 1000)])
            ArrivalNotice(
              chainId: 'osmosis-1',
              hash: hash,
              coins: const [MovedCoin('uosmo', '1')],
              at: at,
            ),
        ],
        read: const ['transfer:C'],
      );
      expect(rows.map((r) => r.id), ['transfer:B', 'transfer:A', 'transfer:C']);
      expect(rows.last.read, isTrue);
    });

    test('a target round-trips through a notification payload', () {
      const target = NoticeTarget(NoticeRoute.chain, chainId: 'osmosis-1');
      expect(NoticeTarget.decode(target.encode()), target);
      expect(NoticeTarget.decode('earn'), const NoticeTarget(NoticeRoute.earn));
      expect(NoticeTarget.decode('nowhere'), isNull);
    });
  });

  group('announcing', () {
    Notice notice(String id, {bool read = false}) => Notice(
          id: id,
          kind: NoticeKind.transfer,
          title: id,
          meta: '',
          timestamp: t0,
          read: read,
        );

    test('the first run records the feed and announces nothing', () {
      final first = pendingAnnouncements([notice('a'), notice('b')], const AnnounceState());
      expect(first.announce, isEmpty);
      expect(first.next.seeded, isTrue);
      expect(first.next.ids, ['a', 'b']);

      final second = pendingAnnouncements([notice('c'), notice('a'), notice('b')], first.next);
      expect(second.announce.map((n) => n.id), ['c']);
    });

    test('a read notice is never announced, and nothing is announced twice', () {
      const seeded = AnnounceState(seeded: true, ids: ['x']);
      final result = pendingAnnouncements([notice('x'), notice('y', read: true)], seeded);
      expect(result.announce, isEmpty);
    });

    test('an emptied list after seeding still announces what is new', () {
      // The bug this guards: "first run" inferred from an empty id list
      // swallowed the first notice after the list was trimmed or cleared.
      const seededButEmpty = AnnounceState(seeded: true);
      final result = pendingAnnouncements([notice('n')], seededButEmpty);
      expect(result.announce.map((n) => n.id), ['n']);
    });

    test('the remembered ids are bounded', () {
      final many = [for (var i = 0; i < 260; i++) notice('id$i')];
      final result = pendingAnnouncements(many, const AnnounceState(seeded: true));
      expect(result.next.ids.length, maxRememberedNotices);
      expect(markNoticesRead([for (var i = 0; i < 250; i++) 'r$i'], ['new']).length,
          maxRememberedNotices);
    });
  });
}
