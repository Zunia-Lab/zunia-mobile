/// The notice engine: what produces the notification feed and the device
/// notifications, while the app runs.
///
/// Mobile counterpart of zunia-extension/lib/realtime.ts. What runs here:
///
/// - One CometBFT subscription per enabled chain (at most [maxLiveChains]),
///   for the active account's address, covering coins arriving and
///   transactions it signed ([ChainStream]).
/// - On an event: remember the arrival, re-derive the feed, raise a device
///   notification for what is new, and tell the portfolio its balances moved.
/// - A one-minute tick while the app is in the foreground that re-reads
///   claimable rewards (every [rewardsInterval]) and unbonding and governance
///   (every [slowInterval], on a slow clock because an unbonding period is
///   weeks and a voting period days).
/// - A check on resume, since sockets die while the app is in the background.
///
/// Three rules shape it, as in the extension:
///
/// 1. The privacy gate is absolute. A socket to a chain's RPC tells that host
///    the user's IP and the address being watched, which is exactly what live
///    reads govern; no socket or read happens with them off, and every socket
///    closes the moment they go off.
/// 2. It only runs unlocked. Addresses come from the session phrase, so there
///    is nothing to watch while locked, and nothing is kept to watch with.
/// 3. Device notifications need the user's yes. The feed and its unread count
///    work regardless.
///
/// Limitation, stated rather than hidden: nothing runs once the system
/// suspends the app. iOS does that within seconds of leaving it; Android
/// keeps the process, and so the sockets, a while longer. There is no
/// background fetch, because a locked wallet has no addresses to read for,
/// and no push, which needs a server and credentials this build does not
/// have. The resume check catches up on what arrived meanwhile.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/notifications/chain_stream.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/notifications/realtime_protocol.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/util/amounts.dart';

/// Chains given a live socket. The rest are covered by the tick, so it is the
/// latency that degrades past this, not the coverage.
const maxLiveChains = 8;

const tickInterval = Duration(minutes: 1);
const rewardsInterval = Duration(minutes: 5);
const slowInterval = Duration(minutes: 10);

/// Arrivals older than this are dropped: history has caught up by then.
const arrivalTtl = Duration(hours: 6);
const maxArrivals = 30;

/// Device notifications raised by one refresh at most. A wallet coming back
/// after a while should not stack a dozen banners.
const maxAlertsPerRefresh = 3;

/// A burst of events on one chain (a swap pays out, takes a fee, the
/// contract pays again) is one balance change.
const burstWindow = Duration(milliseconds: 600);

const _kRead = 'zunia.notices.read';
const _kAnnounced = 'zunia.notices.announced';
const _kRewards = 'zunia.notices.rewards';
const _kArrivals = 'zunia.notices.arrivals';
const _kContext = 'zunia.notices.context';

/// What the screens read.
@immutable
class NoticeFeed {
  const NoticeFeed({
    this.notices = const [],
    this.health = const {},
    this.running = false,
  });

  final List<Notice> notices;

  /// Socket state per chain being watched.
  final Map<String, StreamState> health;

  /// Unlocked with live reads on: chains are being watched.
  final bool running;

  int get unread => notices.where((n) => !n.read).length;

  /// At least one chain is on a live socket.
  bool get live => health.values.any((s) => s == StreamState.live);
}

/// One chain the engine watches.
@immutable
class WatchedChain {
  const WatchedChain(this.chain, this.address);

  final ChainEntry chain;
  final String address;
}

/// Everything the engine reacts to. Rebuilt by the provider whenever one of
/// them changes.
@immutable
class NoticeEngineInputs {
  const NoticeEngineInputs({
    this.accounts = const [],
    this.accountIndex,
    this.liveReads = false,
    this.deviceAlerts = false,
    this.prefs = NotifyPrefs.defaults,
    this.approvals = const [],
  });

  /// Empty while locked.
  final List<WatchedChain> accounts;
  final int? accountIndex;
  final bool liveReads;

  /// The user wants device notifications (the app preference).
  final bool deviceAlerts;
  final NotifyPrefs prefs;
  final List<ApprovalNoticeInput> approvals;

  bool get unlocked => accounts.isNotEmpty;
}

/// Unbonding and governance rows, re-read on the slow clock.
@immutable
class NoticeContext {
  const NoticeContext({
    this.at = 0,
    this.unbonding = const [],
    this.proposals = const [],
  });

  final int at;
  final List<UnbondingNoticeInput> unbonding;
  final List<ProposalNoticeInput> proposals;

  Map<String, Object> toJson() => {
        'at': at,
        'unbonding': [
          for (final u in unbonding)
            {
              'chainId': u.chainId,
              'validator': u.validatorAddress,
              'amount': u.amount,
              'decimals': u.decimals,
              'symbol': u.symbol,
              'completionTime': u.completionTime,
            },
        ],
        'proposals': [
          for (final p in proposals)
            {
              'chainId': p.chainId,
              'id': p.id,
              'title': p.title,
              'voting': p.voting,
              if (p.votingEndTime != null)
                'end': p.votingEndTime!.toUtc().toIso8601String(),
            },
        ],
      };

  static NoticeContext parse(Object? raw) {
    if (raw is! Map) return const NoticeContext();
    final at = raw['at'];
    final unbonding = <UnbondingNoticeInput>[];
    for (final row in asList(raw['unbonding'])) {
      final m = asMap(row);
      final decimals = m['decimals'];
      if (m['chainId'] is! String || m['amount'] is! String || decimals is! int) {
        continue;
      }
      unbonding.add(
        UnbondingNoticeInput(
          chainId: m['chainId'] as String,
          validatorAddress: asString(m['validator']),
          amount: m['amount'] as String,
          decimals: decimals,
          symbol: asString(m['symbol']),
          completionTime: asString(m['completionTime']),
        ),
      );
    }
    final proposals = <ProposalNoticeInput>[];
    for (final row in asList(raw['proposals'])) {
      final m = asMap(row);
      if (m['chainId'] is! String || m['id'] is! String) continue;
      proposals.add(
        ProposalNoticeInput(
          chainId: m['chainId'] as String,
          id: m['id'] as String,
          title: asString(m['title']),
          voting: m['voting'] == true,
          votingEndTime: DateTime.tryParse(asString(m['end'])),
        ),
      );
    }
    return NoticeContext(
      at: at is int ? at : 0,
      unbonding: unbonding,
      proposals: proposals,
    );
  }
}

/// Opens a socket per chain. Tests replace it so nothing dials out.
typedef ChainStreamFactory = ChainStream Function({
  required String chainId,
  required String rpc,
  required List<Subscription> subscriptions,
  required void Function(TxNotice notice) onTx,
  required void Function(StreamState state) onState,
});

ChainStream _defaultOpenStream({
  required String chainId,
  required String rpc,
  required List<Subscription> subscriptions,
  required void Function(TxNotice notice) onTx,
  required void Function(StreamState state) onState,
}) =>
    ChainStream(
      chainId: chainId,
      rpc: rpc,
      subscriptions: subscriptions,
      onTx: onTx,
      onState: onState,
    );

/// A coin named on the chain it landed on: the chain's own currencies are
/// scaled, anything else stays in base units ([describeCoinRaw]).
String describeCoinOn(ChainEntry? chain, MovedCoin coin) {
  if (chain != null && RegExp(r'^\d+$').hasMatch(coin.amount)) {
    if (coin.denom == chain.coinMinimalDenom) {
      return '${formatBaseUnitsExact(coin.amount, decimals: chain.coinDecimals, maxFractionDigits: 6)} '
          '${chain.coinDenom}';
    }
    for (final currency in chain.currencies) {
      if (currency.coinMinimalDenom == coin.denom &&
          currency.coinDenom.isNotEmpty) {
        return '${formatBaseUnitsExact(coin.amount, decimals: currency.coinDecimals, maxFractionDigits: 6)} '
            '${currency.coinDenom}';
      }
    }
  }
  return describeCoinRaw(chain?.chainId ?? '', coin);
}

class NoticeEngine extends StateNotifier<NoticeFeed> {
  NoticeEngine({
    required DeviceAlerts alerts,
    required ChainReader reader,
    ChainStreamFactory? openStream,
    DateTime Function()? clock,
    this.onBalancesMoved,
    bool observeLifecycle = true,
  })  : _alerts = alerts,
        _staking = StakingClient(reader),
        _governance = GovernanceClient(reader),
        _openStream = openStream ?? _defaultOpenStream,
        _clock = clock ?? DateTime.now,
        super(const NoticeFeed()) {
    _ready = _load();
    if (observeLifecycle) {
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(_onResume()),
        onPause: _stopTick,
      );
    }
    _tapSub = _alerts.taps.listen(_onAlertTap);
  }

  final DeviceAlerts _alerts;
  final StakingClient _staking;
  final GovernanceClient _governance;
  final ChainStreamFactory _openStream;
  final DateTime Function() _clock;

  /// Called when a chain event means the account's balances changed, so the
  /// portfolio can re-read them.
  final void Function(String chainId)? onBalancesMoved;

  late final Future<void> _ready;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<AlertTap>? _tapSub;

  NoticeEngineInputs _inputs = const NoticeEngineInputs();
  List<String> _read = const [];
  AnnounceState _announced = const AnnounceState();
  RewardsNoticeState _rewards = RewardsNoticeState.initial;
  List<ArrivalNotice> _arrivals = const [];
  NoticeContext _context = const NoticeContext();
  List<ReceivedNoticeInput> _received = const [];

  final Map<String, ChainStream> _streams = {};
  final Map<String, String> _watching = {};
  final Map<String, StreamState> _health = {};
  final Map<String, Timer> _bursts = {};
  Timer? _tick;
  int _lastRewardsAt = 0;
  bool _passedOnce = false;
  bool _passing = false;
  bool? _passAgain;
  bool _provisionalAsked = false;

  final _taps = StreamController<NoticeTarget?>.broadcast();

  /// Device notifications the user tapped, with where each should lead.
  Stream<NoticeTarget?> get taps => _taps.stream;

  int get _now => _clock().millisecondsSinceEpoch;

  /* ------------------------------------------------------------------------ *
   * Storage
   * ------------------------------------------------------------------------ */

  Future<void> _load() async {
    final store = await SharedPreferences.getInstance();
    Object? json(String key) {
      final raw = store.getString(key);
      if (raw == null) return null;
      try {
        return jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }

    _read = [
      for (final id in asList(json(_kRead)))
        if (id is String) id,
    ];
    _announced = AnnounceState.parse(json(_kAnnounced));
    _rewards = parseRewardsNotice(json(_kRewards));
    _arrivals = [
      for (final row in asList(json(_kArrivals))) ?ArrivalNotice.fromJson(row),
    ];
    _context = NoticeContext.parse(json(_kContext));
  }

  Future<void> _save(String key, Object value) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(key, jsonEncode(value));
  }

  /// The feed belongs to one account: another account's arrivals, rewards
  /// cycle and unbondings must not show under this one.
  Future<void> _forgetAccountState() async {
    _arrivals = const [];
    _context = const NoticeContext();
    _rewards = RewardsNoticeState.initial;
    _received = const [];
    _lastRewardsAt = 0;
    final store = await SharedPreferences.getInstance();
    await store.remove(_kArrivals);
    await store.remove(_kContext);
    await store.remove(_kRewards);
  }

  /* ------------------------------------------------------------------------ *
   * Inputs
   * ------------------------------------------------------------------------ */

  /// New inputs from the app. Idempotent: a chain already watching the right
  /// address keeps its socket.
  Future<void> update(NoticeEngineInputs next) async {
    await _ready;
    if (!mounted) return;
    final previous = _inputs;
    _inputs = next;

    final accountChanged = previous.accountIndex != null &&
        next.accountIndex != previous.accountIndex;
    final locked = previous.unlocked && !next.unlocked;
    if (accountChanged || locked) {
      await _forgetAccountState();
      _passedOnce = false;
    }

    if (!next.unlocked || !next.liveReads) {
      _stopAll();
      _refresh();
      return;
    }

    if (!_provisionalAsked && next.deviceAlerts) {
      // iOS only, and silent: quiet delivery to Notification Center until the
      // user chooses full notifications. Never a prompt at this point.
      _provisionalAsked = true;
      unawaited(_alerts.requestProvisional());
    }

    _syncStreams();
    _startTick();
    final chainsChanged = !listEquals(
      [for (final a in previous.accounts) '${a.chain.chainId}|${a.address}'],
      [for (final a in next.accounts) '${a.chain.chainId}|${a.address}'],
    );
    if (!_passedOnce || chainsChanged || !previous.liveReads) {
      await pass(force: !_passedOnce || chainsChanged);
    } else {
      _refresh();
    }
  }

  /// History rows the Notifications screen loaded, merged into the feed.
  void setReceived(List<ReceivedNoticeInput> rows) {
    _received = rows;
    _refresh();
  }

  /* ------------------------------------------------------------------------ *
   * Sockets
   * ------------------------------------------------------------------------ */

  List<WatchedChain> get _watchable => _inputs.accounts
      .where((a) => websocketUrl(a.chain.rpc) != null)
      .take(maxLiveChains)
      .toList();

  void _syncStreams() {
    final wanted = {for (final a in _watchable) a.chain.chainId: a};
    for (final chainId in [..._streams.keys]) {
      if (wanted[chainId]?.address != _watching[chainId]) _close(chainId);
    }
    for (final entry in wanted.entries) {
      if (_streams.containsKey(entry.key)) continue;
      final account = entry.value;
      _watching[entry.key] = account.address;
      _health[entry.key] = StreamState.connecting;
      _streams[entry.key] = _openStream(
        chainId: entry.key,
        rpc: account.chain.rpc!,
        subscriptions: subscriptionsFor(entry.key, account.address),
        onTx: _onTx,
        onState: (s) {
          if (!mounted) return;
          _health[entry.key] = s;
          _publish();
        },
      );
    }
    _publish();
  }

  void _close(String chainId) {
    _streams.remove(chainId)?.close();
    _watching.remove(chainId);
    _health.remove(chainId);
    _bursts.remove(chainId)?.cancel();
  }

  void _stopAll() {
    for (final chainId in [..._streams.keys]) {
      _close(chainId);
    }
    _stopTick();
  }

  void _onTx(TxNotice notice) {
    if (!mounted) return;
    final arrival = arrivalFrom(notice, _now);
    if (arrival != null && !_arrivals.any((a) => a.hash == arrival.hash)) {
      _arrivals = [arrival, ..._arrivals].take(maxArrivals).toList();
      unawaited(_save(_kArrivals, [for (final a in _arrivals) a.toJson()]));
      _refresh();
    }
    _bursts.remove(notice.chainId)?.cancel();
    _bursts[notice.chainId] = Timer(burstWindow, () {
      _bursts.remove(notice.chainId);
      unawaited(_afterChainEvent(notice.chainId));
    });
  }

  /// A transaction moved this chain's balances: re-read its rewards (a claim
  /// shows up as a drop) and let the portfolio refresh.
  Future<void> _afterChainEvent(String chainId) async {
    if (!mounted) return;
    onBalancesMoved?.call(chainId);
    final account =
        _inputs.accounts.where((a) => a.chain.chainId == chainId).firstOrNull;
    if (account == null) return;
    await _readRewards([account]);
    _refresh();
  }

  /* ------------------------------------------------------------------------ *
   * Polling
   * ------------------------------------------------------------------------ */

  void _startTick() {
    _tick ??= Timer.periodic(tickInterval, (_) => unawaited(pass()));
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  Future<void> _onResume() async {
    if (!mounted || !_inputs.unlocked || !_inputs.liveReads) return;
    // Sockets rarely survive a suspension; reopen them rather than wait for
    // each one's backoff.
    for (final chainId in [..._streams.keys]) {
      _close(chainId);
    }
    _syncStreams();
    _startTick();
    _lastRewardsAt = 0;
    await pass();
  }

  /// One round of reads, each on its own clock, then a re-derive. [force]
  /// reads everything now.
  Future<void> pass({bool force = false}) async {
    if (!mounted) return;
    if (!_inputs.unlocked || !_inputs.liveReads) return;
    if (_passing) {
      // Run once more when the current pass ends, forced if either asked.
      _passAgain = (_passAgain ?? false) || force;
      return;
    }
    _passing = true;
    try {
      final now = _now;
      final watched = _inputs.accounts.take(maxLiveChains).toList();
      final reads = <Future<void>>[];
      if (force || now - _lastRewardsAt >= rewardsInterval.inMilliseconds) {
        reads.add(_readRewards(watched));
      }
      if (force || now - _context.at >= slowInterval.inMilliseconds) {
        reads.add(_slowPass(watched));
      }
      await Future.wait(reads);
      final cutoff = now - arrivalTtl.inMilliseconds;
      _arrivals = _arrivals.where((a) => a.at > cutoff).toList();
      _passedOnce = true;
      _refresh();
    } finally {
      _passing = false;
    }
    final again = _passAgain;
    _passAgain = null;
    if (again != null) await pass(force: again);
  }

  Future<void> _readRewards(List<WatchedChain> chains) async {
    if (chains.isEmpty) return;
    _lastRewardsAt = _now;
    final readings = await Future.wait(
      chains.map((a) async {
        try {
          final total = await _staking.rewardsTotal(a.chain, a.address);
          return RewardsReading(
            chainId: a.chain.chainId,
            rewards: total.toString(),
            decimals: a.chain.coinDecimals,
          );
        } on Object {
          return RewardsReading(
            chainId: a.chain.chainId,
            rewards: '0',
            decimals: a.chain.coinDecimals,
            failed: true,
          );
        }
      }),
    );
    if (!mounted) return;
    final next = nextRewardsNotice(
      _rewards,
      readings,
      _now,
      repeatMs: reminderInterval(_inputs.prefs.rewards),
    );
    if (next != _rewards) {
      _rewards = next;
      await _save(_kRewards, next.toJson());
    }
  }

  Future<void> _slowPass(List<WatchedChain> chains) async {
    if (chains.isEmpty) return;
    final results = await Future.wait(
      chains.map((a) async {
        final unbonding = <UnbondingNoticeInput>[];
        final proposals = <ProposalNoticeInput>[];
        try {
          for (final u in await _staking.unbonding(a.chain, a.address)) {
            unbonding.add(
              UnbondingNoticeInput(
                chainId: u.chainId,
                validatorAddress: u.validatorAddress,
                amount: u.amount.toString(),
                decimals: a.chain.coinDecimals,
                symbol: a.chain.coinDenom,
                completionTime: u.completionTimeRaw,
              ),
            );
          }
        } on Object {
          // This chain's rows are missing until the next pass.
        }
        try {
          final page = await _governance.proposals(a.chain, limit: 20);
          for (final p in page.rows) {
            if (p.status != GovStatus.voting) continue;
            proposals.add(
              ProposalNoticeInput(
                chainId: p.chainId,
                id: p.id,
                title: p.title,
                voting: true,
                votingEndTime: p.votingEndTime,
              ),
            );
          }
        } on Object {
          // As above.
        }
        return (unbonding: unbonding, proposals: proposals);
      }),
    );
    if (!mounted) return;
    _context = NoticeContext(
      at: _now,
      unbonding: [for (final r in results) ...r.unbonding],
      proposals: [for (final r in results) ...r.proposals],
    );
    await _save(_kContext, _context.toJson());
  }

  /* ------------------------------------------------------------------------ *
   * The feed
   * ------------------------------------------------------------------------ */

  List<Notice> _derive() {
    final chains = {for (final a in _inputs.accounts) a.chain.chainId: a.chain};
    return deriveNotices(
      NoticeInput(
        approvals: _inputs.approvals,
        chainNames: {
          for (final c in chains.values) c.chainId: c.chainName,
          for (final a in _arrivals)
            if (!chains.containsKey(a.chainId))
              a.chainId: ChainCatalog.isLoaded
                  ? ChainCatalog.instance.find(a.chainId)?.chainName ??
                      a.chainId
                  : a.chainId,
        },
        received: _received,
        proposals: _context.proposals,
        unbonding: _context.unbonding,
        arrivals: _arrivals,
        read: _read,
        now: _now,
        rewards: _rewards,
        prefs: _inputs.prefs,
        unlocked: _inputs.unlocked,
        describeCoin: (chainId, coin) => describeCoinOn(
          chains[chainId] ??
              (ChainCatalog.isLoaded
                  ? ChainCatalog.instance.find(chainId)
                  : null),
          coin,
        ),
      ),
    );
  }

  void _publish([List<Notice>? notices]) {
    if (!mounted) return;
    state = NoticeFeed(
      notices: notices ?? state.notices,
      health: Map.unmodifiable(_health),
      running: _inputs.unlocked && _inputs.liveReads,
    );
  }

  void _refresh() {
    if (!mounted) return;
    final notices = _derive();
    _publish(notices);
    // Announce only once a full pass has run, so the first look at a wallet
    // records what is already there instead of alerting for all of it.
    if (_passedOnce) unawaited(_announce(notices));
  }

  Future<void> _announce(List<Notice> notices) async {
    final result = pendingAnnouncements(notices, _announced);
    final changed = result.next.seeded != _announced.seeded ||
        !listEquals(result.next.ids, _announced.ids);
    _announced = result.next;
    if (changed) await _save(_kAnnounced, result.next.toJson());
    if (result.announce.isEmpty || !_inputs.deviceAlerts) return;
    for (final notice in result.announce.take(maxAlertsPerRefresh)) {
      await _alerts.show(notice);
    }
  }

  /// Mark [ids] read: in the feed, the unread count and storage.
  Future<void> markRead(Iterable<String> ids) async {
    await _ready;
    _read = markNoticesRead(_read, ids);
    _publish([
      for (final n in state.notices)
        ids.contains(n.id) ? n.withRead(true) : n,
    ]..sort((a, b) {
        if (a.read != b.read) return a.read ? 1 : -1;
        return b.timestamp.compareTo(a.timestamp);
      }));
    await _save(_kRead, _read);
  }

  Future<void> markAllRead() =>
      markRead([for (final n in state.notices) if (!n.read) n.id]);

  void _onAlertTap(AlertTap tap) {
    unawaited(markRead([tap.noticeId]));
    _taps.add(tap.target);
  }

  /// Read everything again now: pull to refresh on the Notifications screen.
  Future<void> refreshNow() async {
    await _ready;
    _lastRewardsAt = 0;
    await pass(force: true);
  }

  @override
  void dispose() {
    _stopAll();
    _lifecycle?.dispose();
    unawaited(_tapSub?.cancel());
    unawaited(_taps.close());
    super.dispose();
  }
}
