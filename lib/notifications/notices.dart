/// The notification feed, as pure functions.
///
/// Dart mirror of zunia-extension/lib/notices.ts. [deriveNotices] is pure and
/// takes its clock as an argument. That is not ceremony: the row ids are what
/// "already announced" and "already read" are keyed on, so a derivation that
/// is not reproducible for the same inputs silently re-alerts the user for
/// things they have already dismissed.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/util/amounts.dart';

const _day = 86400000;

enum NoticeKind { approval, transfer, rewards, unbonding, governance }

/// Where a row leads when tapped.
enum NoticeRoute { approve, earn, governance, chain }

@immutable
class NoticeTarget {
  const NoticeTarget(this.route, {this.chainId});

  final NoticeRoute route;
  final String? chainId;

  @override
  bool operator ==(Object other) =>
      other is NoticeTarget && other.route == route && other.chainId == chainId;

  @override
  int get hashCode => Object.hash(route, chainId);

  /// `earn`, `chain:osmosis-1`: carried in a device notification's payload.
  String encode() => chainId == null ? route.name : '${route.name}:$chainId';

  static NoticeTarget? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final split = raw.indexOf(':');
    final name = split < 0 ? raw : raw.substring(0, split);
    final route = NoticeRoute.values.where((r) => r.name == name).firstOrNull;
    if (route == null) return null;
    return NoticeTarget(
      route,
      chainId: split < 0 ? null : raw.substring(split + 1),
    );
  }
}

@immutable
class Notice {
  const Notice({
    required this.id,
    required this.kind,
    required this.title,
    required this.meta,
    required this.timestamp,
    this.target,
    this.read = false,
  });

  final String id;
  final NoticeKind kind;
  final String title;
  final String meta;

  /// Milliseconds since the epoch: the row's place in the feed.
  final int timestamp;
  final NoticeTarget? target;
  final bool read;

  Notice withRead(bool value) => Notice(
        id: id,
        kind: kind,
        title: title,
        meta: meta,
        timestamp: timestamp,
        target: target,
        read: value,
      );

  @override
  bool operator ==(Object other) =>
      other is Notice &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.meta == meta &&
      other.timestamp == timestamp &&
      other.target == target &&
      other.read == read;

  @override
  int get hashCode =>
      Object.hash(id, kind, title, meta, timestamp, target, read);

  @override
  String toString() => 'Notice($id, $title, $meta)';
}

/// A site waiting for the user's decision.
@immutable
class ApprovalNoticeInput {
  const ApprovalNoticeInput({
    required this.id,
    required this.origin,
    required this.title,
    required this.createdAt,
  });

  final String id;
  final String origin;
  final String title;
  final int createdAt;
}

@immutable
class UnbondingNoticeInput {
  const UnbondingNoticeInput({
    required this.chainId,
    required this.validatorAddress,
    required this.amount,
    required this.decimals,
    required this.symbol,
    required this.completionTime,
  });

  final String chainId;
  final String validatorAddress;

  /// Base units.
  final String amount;
  final int decimals;
  final String symbol;

  /// RFC 3339, as the chain reports it; part of the row id.
  final String completionTime;
}

@immutable
class ProposalNoticeInput {
  const ProposalNoticeInput({
    required this.chainId,
    required this.id,
    required this.title,
    required this.voting,
    this.votingEndTime,
  });

  final String chainId;
  final String id;
  final String title;

  /// In its voting period.
  final bool voting;
  final DateTime? votingEndTime;
}

/// A received transfer from the chain's history endpoint.
@immutable
class ReceivedNoticeInput {
  const ReceivedNoticeInput({
    required this.chainId,
    required this.hash,
    required this.meta,
    required this.timestamp,
  });

  final String chainId;
  final String hash;

  /// The amount as the Activity row words it.
  final String meta;
  final int timestamp;
}

/// One `denom`/`amount` pair pulled out of a transfer event.
@immutable
class MovedCoin {
  const MovedCoin(this.denom, this.amount);

  final String denom;

  /// Base units.
  final String amount;

  Map<String, String> toJson() => {'denom': denom, 'amount': amount};

  static MovedCoin? fromJson(Object? value) {
    if (value is! Map) return null;
    final denom = value['denom'];
    final amount = value['amount'];
    if (denom is! String || amount is! String) return null;
    return MovedCoin(denom, amount);
  }

  @override
  bool operator ==(Object other) =>
      other is MovedCoin && other.denom == denom && other.amount == amount;

  @override
  int get hashCode => Object.hash(denom, amount);

  @override
  String toString() => '$amount$denom';
}

/// A transfer a live socket saw land, before the history endpoint has it.
///
/// Kept apart from the history rows because it is a different kind of claim:
/// history is what the chain has indexed, this is what a socket said a moment
/// ago. They converge, and the shared `transfer:<hash>` id is what makes the
/// duplicate collapse.
@immutable
class ArrivalNotice {
  const ArrivalNotice({
    required this.chainId,
    required this.hash,
    required this.coins,
    required this.at,
  });

  final String chainId;
  final String hash;
  final List<MovedCoin> coins;
  final int at;

  Map<String, Object> toJson() => {
        'chainId': chainId,
        'hash': hash,
        'coins': [for (final c in coins) c.toJson()],
        'at': at,
      };

  static ArrivalNotice? fromJson(Object? value) {
    if (value is! Map) return null;
    final chainId = value['chainId'];
    final hash = value['hash'];
    final at = value['at'];
    final coins = value['coins'];
    if (chainId is! String || hash is! String || at is! int || coins is! List) {
      return null;
    }
    return ArrivalNotice(
      chainId: chainId,
      hash: hash,
      coins: [for (final c in coins) ?MovedCoin.fromJson(c)],
      at: at,
    );
  }
}

/// Names a coin for one line of notification text, on the chain it landed on.
typedef CoinDescriber = String Function(String chainId, MovedCoin coin);

/// The honest fallback: base units and the denom, never a guessed scale.
/// Inventing six decimals for an unknown IBC denom would put a wrong number in
/// a notification, and a wrong number is worse than a raw one.
String describeCoinRaw(String chainId, MovedCoin coin) {
  final denom = coin.denom;
  final short = denom.startsWith('ibc/') && denom.length > 16
      ? 'ibc/${denom.substring(4, 8)}…${denom.substring(denom.length - 6)}'
      : denom;
  return '${coin.amount} base units $short';
}

/// Everything the feed is derived from.
@immutable
class NoticeInput {
  const NoticeInput({
    this.approvals = const [],
    this.chainNames = const {},
    this.received = const [],
    this.proposals = const [],
    this.unbonding = const [],
    this.arrivals = const [],
    this.read = const [],
    required this.now,
    this.rewards,
    this.prefs,
    this.unlocked = true,
    this.describeCoin = describeCoinRaw,
  });

  final List<ApprovalNoticeInput> approvals;
  final Map<String, String> chainNames;
  final List<ReceivedNoticeInput> received;
  final List<ProposalNoticeInput> proposals;
  final List<UnbondingNoticeInput> unbonding;
  final List<ArrivalNotice> arrivals;
  final List<String> read;
  final int now;

  /// The claimable-rewards cycle ([nextRewardsNotice]). Absent means no
  /// rewards row.
  final RewardsNoticeState? rewards;

  /// Which kinds the user wants. Rows of other kinds are not derived at all,
  /// so they reach neither the feed, nor the count, nor a device notification.
  /// Approvals always show. Absent means everything.
  final NotifyPrefs? prefs;

  /// Nothing balance-derived shows while the wallet is locked.
  final bool unlocked;
  final CoinDescriber describeCoin;
}

String _hostOf(String origin) {
  final uri = Uri.tryParse(origin);
  return uri != null && uri.host.isNotEmpty ? uri.host : origin;
}

int? _daysLeft(int? atMs, int now) {
  if (atMs == null) return null;
  final ms = atMs - now;
  if (ms <= 0) return null;
  return (ms / _day).ceil();
}

int? _parseMs(String iso) => DateTime.tryParse(iso)?.millisecondsSinceEpoch;

String _amount(String base, int decimals) =>
    formatBaseUnitsExact(base, decimals: decimals, maxFractionDigits: 3);

bool _wanted(NoticeKind kind, NotifyPrefs? prefs) {
  if (prefs == null) return true;
  return switch (kind) {
    NoticeKind.transfer => prefs.transfers,
    NoticeKind.unbonding => prefs.unbonding,
    NoticeKind.governance => prefs.governance,
    NoticeKind.rewards => prefs.rewards != RewardReminder.off,
    NoticeKind.approval => true,
  };
}

/// The feed, unread above read, newest first within each.
///
/// Pure: the same inputs and the same `now` always produce the same rows in
/// the same order, ids included.
List<Notice> deriveNotices(NoticeInput input) {
  final now = input.now;
  final rows = <Notice>[];
  String chainName(String chainId) => input.chainNames[chainId] ?? chainId;

  for (final approval in input.approvals) {
    rows.add(
      Notice(
        id: 'approval:${approval.id}',
        kind: NoticeKind.approval,
        title: approval.title,
        meta: '${_hostOf(approval.origin)} · waiting for you',
        target: const NoticeTarget(NoticeRoute.approve),
        timestamp: approval.createdAt,
      ),
    );
  }

  // One generic row per rewards cycle, with no amount in it: the amount grows
  // every block, and a row keyed or worded on it was a new alert every block.
  final rewards = input.rewards;
  if (rewards != null &&
      rewards.phase == RewardsPhase.raised &&
      input.prefs?.rewards != RewardReminder.off &&
      input.unlocked) {
    rows.add(
      Notice(
        id: 'rewards:${rewards.cycle}',
        kind: NoticeKind.rewards,
        title: 'Staking rewards ready to claim',
        meta: 'Open Earn to claim them.',
        target: const NoticeTarget(NoticeRoute.earn),
        timestamp: rewards.raisedAt == 0 ? now : rewards.raisedAt,
      ),
    );
  }

  if (input.unlocked) {
    for (final row in input.unbonding) {
      final at = _parseMs(row.completionTime);
      final remaining = _daysLeft(at, now);
      final amount = '${_amount(row.amount, row.decimals)} ${row.symbol}';
      rows.add(
        Notice(
          id: 'unbonding:${row.chainId}:${row.validatorAddress}:${row.completionTime}',
          kind: NoticeKind.unbonding,
          title: remaining == null
              ? 'Unbonding complete'
              : 'Unbonding in progress',
          meta: remaining == null
              ? '$amount is liquid again'
              : '$amount · ${remaining}d left',
          target: const NoticeTarget(NoticeRoute.earn),
          timestamp: at ?? now,
        ),
      );
    }

    // Arrivals first, so the socket's version of a transfer wins over the
    // history endpoint's: it has the live timestamp, and the dedupe below
    // keeps whichever came first.
    for (final arrival in input.arrivals) {
      final described = [
        for (final coin in arrival.coins) input.describeCoin(arrival.chainId, coin),
      ];
      rows.add(
        Notice(
          id: 'transfer:${arrival.hash}',
          kind: NoticeKind.transfer,
          title: 'Received on ${chainName(arrival.chainId)}',
          meta: described.isEmpty ? 'A transfer arrived' : described.join(' · '),
          target: NoticeTarget(NoticeRoute.chain, chainId: arrival.chainId),
          timestamp: arrival.at,
        ),
      );
    }

    for (final item in input.received.take(8)) {
      rows.add(
        Notice(
          id: 'transfer:${item.hash}',
          kind: NoticeKind.transfer,
          title: 'Received on ${chainName(item.chainId)}',
          meta: item.meta,
          target: NoticeTarget(NoticeRoute.chain, chainId: item.chainId),
          timestamp: item.timestamp,
        ),
      );
    }
  }

  for (final proposal in input.proposals) {
    final end = proposal.votingEndTime?.millisecondsSinceEpoch;
    final remaining = _daysLeft(end, now);
    if (!proposal.voting || remaining == null) continue;
    rows.add(
      Notice(
        id: 'gov:${proposal.chainId}:${proposal.id}',
        kind: NoticeKind.governance,
        title: 'Proposal ${proposal.id} ends in ${remaining}d',
        meta: '${chainName(proposal.chainId)} · ${proposal.title}',
        target: const NoticeTarget(NoticeRoute.governance),
        timestamp: end ?? now,
      ),
    );
  }

  final unique = <String, Notice>{};
  for (final row in rows) {
    if (_wanted(row.kind, input.prefs)) unique.putIfAbsent(row.id, () => row);
  }

  final readIds = input.read.toSet();
  final out = [
    for (final row in unique.values) row.withRead(readIds.contains(row.id)),
  ];
  out.sort((a, b) {
    if (a.read != b.read) return a.read ? 1 : -1;
    return b.timestamp.compareTo(a.timestamp);
  });
  return out;
}

/* -------------------------------------------------------------------------- *
 * Claimable rewards
 * -------------------------------------------------------------------------- */

/// The "rewards ready" notice is a cycle, not a reading of the amount.
///
/// Rewards grow every block, so a notice keyed on the amount was a new alert
/// every block. Instead:
///
/// - `waiting` (a fresh install or account): raised as soon as anything at all
///   is claimable, on any chain;
/// - `raised`: one generic notice stays for as long as the rewards wait.
///   Reading it is final for this cycle: the id does not change, so it never
///   re-alerts;
/// - once the rewards are claimed (nothing claimable, or a drop with every
///   chain back under one whole token) the cycle is `rearmed`, and the next
///   notice waits until some chain has at least one whole token to claim, so a
///   claim is not followed a block later by an alert for a few micro-units.
///
/// With a daily or weekly reminder, rewards still waiting a day or a week after
/// the notice raise it again, as a new cycle.
enum RewardsPhase { waiting, raised, rearmed }

@immutable
class RewardsNoticeState {
  const RewardsNoticeState({
    required this.phase,
    required this.cycle,
    required this.raisedAt,
    required this.last,
  });

  static const initial = RewardsNoticeState(
    phase: RewardsPhase.waiting,
    cycle: 0,
    raisedAt: 0,
    last: {},
  );

  final RewardsPhase phase;

  /// Raised notices so far; the notice id, so each cycle is read on its own.
  final int cycle;

  /// When the current notice was raised.
  final int raisedAt;

  /// Claimable per chain at the last look, in base units, to see a claim.
  final Map<String, String> last;

  Map<String, Object> toJson() => {
        'phase': phase.name,
        'cycle': cycle,
        'raisedAt': raisedAt,
        'last': last,
      };

  @override
  bool operator ==(Object other) =>
      other is RewardsNoticeState &&
      other.phase == phase &&
      other.cycle == cycle &&
      other.raisedAt == raisedAt &&
      mapEquals(other.last, last);

  @override
  int get hashCode => Object.hash(
        phase,
        cycle,
        raisedAt,
        Object.hashAllUnordered(last.entries.map((e) => '${e.key}=${e.value}')),
      );

  @override
  String toString() => 'RewardsNoticeState($phase, $cycle, $raisedAt, $last)';
}

/// One chain's claimable rewards as just read.
@immutable
class RewardsReading {
  const RewardsReading({
    required this.chainId,
    required this.rewards,
    required this.decimals,
    this.failed = false,
  });

  final String chainId;

  /// Base units of the staking denom.
  final String rewards;
  final int decimals;

  /// The read failed; it teaches nothing about a claim.
  final bool failed;
}

final _baseUnitsRe = RegExp(r'^\d{1,80}$');

BigInt _base(String? value) =>
    value != null && _baseUnitsRe.hasMatch(value) ? BigInt.parse(value) : BigInt.zero;

/// How long a waiting reward notice stays quiet before it is raised again.
int? reminderInterval(RewardReminder reminder) => switch (reminder) {
      RewardReminder.daily => _day,
      RewardReminder.weekly => 7 * _day,
      _ => null,
    };

/// The next state of the rewards cycle, from the readings just taken.
///
/// Pure. A chain whose read failed teaches nothing (a failed read reports
/// zero, which must not pass for a claim), and an empty list (locked, or
/// nothing loaded yet) leaves the state as it was. [repeatMs] re-raises a
/// notice whose rewards are still waiting that long after it was raised; null
/// raises once per cycle.
RewardsNoticeState nextRewardsNotice(
  RewardsNoticeState prev,
  List<RewardsReading> readings,
  int now, {
  int? repeatMs,
}) {
  final seen = readings.where((r) => !r.failed).toList();
  if (seen.isEmpty) return prev;

  final last = {...prev.last};
  var anyClaimable = false;
  var anyWhole = false;
  var claimed = false;
  for (final row in seen) {
    final amount = _base(row.rewards);
    final decimals = row.decimals.clamp(0, 30);
    if (amount > BigInt.zero) anyClaimable = true;
    if (amount >= BigInt.from(10).pow(decimals)) anyWhole = true;
    final before = prev.last[row.chainId];
    if (before != null && amount < _base(before)) claimed = true;
    last[row.chainId] = amount.toString();
  }

  RewardsNoticeState raise() => RewardsNoticeState(
        phase: RewardsPhase.raised,
        cycle: prev.cycle + 1,
        raisedAt: now,
        last: last,
      );
  RewardsNoticeState keep(RewardsPhase phase) => RewardsNoticeState(
        phase: phase,
        cycle: prev.cycle,
        raisedAt: prev.raisedAt,
        last: last,
      );

  switch (prev.phase) {
    case RewardsPhase.waiting:
      return anyClaimable ? raise() : keep(RewardsPhase.waiting);
    case RewardsPhase.raised:
      if (!anyClaimable || (claimed && !anyWhole)) {
        return keep(RewardsPhase.rearmed);
      }
      if (repeatMs != null && now - prev.raisedAt >= repeatMs) return raise();
      return keep(RewardsPhase.raised);
    case RewardsPhase.rearmed:
      return anyWhole ? raise() : keep(RewardsPhase.rearmed);
  }
}

/// A stored rewards state, validated; anything unreadable starts a new cycle.
RewardsNoticeState parseRewardsNotice(Object? value) {
  if (value is! Map) return RewardsNoticeState.initial;
  final phase = RewardsPhase.values
      .where((p) => p.name == value['phase'])
      .firstOrNull;
  final cycle = value['cycle'];
  if (phase == null || cycle is! int || cycle < 0) {
    return RewardsNoticeState.initial;
  }
  final last = <String, String>{};
  final rawLast = value['last'];
  if (rawLast is Map) {
    for (final entry in rawLast.entries) {
      final amount = entry.value;
      if (entry.key is String &&
          amount is String &&
          _baseUnitsRe.hasMatch(amount)) {
        last[entry.key as String] = amount;
      }
    }
  }
  final raisedAt = value['raisedAt'];
  return RewardsNoticeState(
    phase: phase,
    cycle: cycle,
    raisedAt: raisedAt is int ? raisedAt : 0,
    last: last,
  );
}

/* -------------------------------------------------------------------------- *
 * Announcing
 * -------------------------------------------------------------------------- */

/// How many announced (and read) ids are remembered. Bounded so the list
/// cannot grow without limit over months of transfers and proposals.
const maxRememberedNotices = 200;

/// Ids already turned into a device notification.
///
/// [seeded] is recorded explicitly, once. Inferring "first run, do not alert"
/// from an empty id list is also true after the list is trimmed or storage is
/// cleared, and the first genuinely new notice after either was swallowed.
@immutable
class AnnounceState {
  const AnnounceState({this.seeded = false, this.ids = const []});

  final bool seeded;
  final List<String> ids;

  Map<String, Object> toJson() => {'seeded': seeded, 'ids': ids};

  static AnnounceState parse(Object? value) {
    if (value is! Map) return const AnnounceState();
    final ids = value['ids'];
    return AnnounceState(
      seeded: value['seeded'] == true,
      ids: ids is List ? [for (final id in ids) if (id is String) id] : const [],
    );
  }
}

/// Which notices have not been announced yet, and the state to store after.
///
/// The first run records the feed and announces nothing: opening a wallet that
/// has had claimable rewards for a month should not fire a stack of
/// notifications. Every run after that announces what is new and unread.
({List<Notice> announce, AnnounceState next}) pendingAnnouncements(
  List<Notice> notices,
  AnnounceState state,
) {
  final seen = state.ids.toSet();
  final fresh = notices.where((n) => !n.read && !seen.contains(n.id)).toList();
  final ids = [...fresh.map((n) => n.id), ...state.ids]
      .take(maxRememberedNotices)
      .toList();
  return (
    announce: state.seeded ? fresh : const <Notice>[],
    next: AnnounceState(seeded: true, ids: ids),
  );
}

/// Ids marked read, newest kept when the list is trimmed.
List<String> markNoticesRead(List<String> read, Iterable<String> ids) {
  final merged = <String>{...read, ...ids}.toList();
  return merged.length > maxRememberedNotices
      ? merged.sublist(merged.length - maxRememberedNotices)
      : merged;
}
