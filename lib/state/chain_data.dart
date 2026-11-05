/// Riverpod wiring on top of [ChainClient]: balances, prices and history.
///
/// Built for a wallet with hundreds of enabled chains. Balances are read a few
/// chains at a time and published as each chain answers, so the first rows
/// show in a second instead of after the slowest endpoint; a chain read in the
/// last minute is not read again unless the user pulls to refresh. Every
/// family here returns empty data rather than throwing when live reads are
/// off, so screens render their "reads are off" state instead of an error.
///
/// Token names come from `lib/tokens/token_identity.dart` at display time.
/// After a chain's balance lands, its unknown vouchers are traced and its
/// unnamed tokens' bank metadata read in the background; rows rename
/// themselves when that lands ([identityGenerationProvider]).
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/activity/bundled_links.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';

final chainClientProvider = Provider<ChainClient>((ref) {
  final client = ChainClient(
    enabled: ref.watch(preferencesProvider.select((p) => p.liveReads)),
  );
  ref.onDispose(client.close);
  return client;
});

/// What [balancesProvider] hands to screens: the chains that answered, plus
/// the reason for each chain that is missing.
///
/// A chain whose read failed is absent from the map instead of present with
/// zeros. Every screen already renders an absent chain as '—', while a zero
/// reads as "this account is empty" - a claim the wallet cannot make when the
/// endpoint never answered.
class BalanceReads extends UnmodifiableMapView<String, ChainBalance> {
  BalanceReads(super.values, this.failures);

  /// Keyed by chain id, for chains absent from this map.
  final Map<String, ChainReadFailure> failures;

  static final BalanceReads empty = BalanceReads(const {}, const {});
}

/* -------------------------------------------------------------------------- *
 * Balances
 * -------------------------------------------------------------------------- */

/// One balance read, so tests can stand in for the network.
typedef BalanceFetcher = Future<BalanceRead> Function(ChainEntry chain, String address);

final balanceFetcherProvider = Provider<BalanceFetcher>((ref) {
  final client = ref.watch(chainClientProvider);
  return client.balance;
});

/// How long a chain's balance counts as current.
const Duration balanceTtl = Duration(seconds: 60);

/// Chains read at once. Enough to fill a screen fast, few enough that a
/// phone with 300 chains enabled does not open 900 sockets.
const int balanceConcurrency = 6;

/// One chain's last answer.
@immutable
class ChainRead {
  const ChainRead({this.balance, this.failure, this.at, this.loading = false});

  final ChainBalance? balance;
  final ChainReadFailure? failure;
  final DateTime? at;

  /// A read for this chain is in flight (a previous answer may still show).
  final bool loading;

  ChainRead started() => ChainRead(balance: balance, failure: failure, at: at, loading: true);
}

@immutable
class PortfolioState {
  const PortfolioState({this.chains = const {}, this.refreshing = false, this.readsOff = false});

  /// Keyed by chain id, for the active account's enabled chains.
  final Map<String, ChainRead> chains;

  /// A refresh pass is running.
  final bool refreshing;

  /// Live reads are off: nothing was asked.
  final bool readsOff;

  Map<String, ChainBalance> get balances => {
        for (final MapEntry(:key, :value) in chains.entries)
          if (value.balance != null) key: value.balance!,
      };

  Map<String, ChainReadFailure> get failures => {
        for (final MapEntry(:key, :value) in chains.entries)
          if (value.balance == null && value.failure != null) key: value.failure!,
      };

  /// At least one chain has answered or failed.
  bool get anySettled => chains.values.any((read) => read.balance != null || read.failure != null);

  bool get loadingAny => refreshing || chains.values.any((read) => read.loading);
}

/// Answers kept across account switches and screen rebuilds, keyed by
/// `chainId|address`, so going back to a chain does not read it again.
class BalanceCache {
  final Map<String, ChainRead> _rows = {};

  ChainRead? operator [](String key) => _rows[key];
  void operator []=(String key, ChainRead value) => _rows[key] = value;
  void clear() => _rows.clear();
}

final balanceCacheProvider = Provider<BalanceCache>((ref) {
  // Live reads switched off forgets everything read while they were on.
  ref.watch(preferencesProvider.select((p) => p.liveReads));
  return BalanceCache();
});

/// Traces vouchers nothing names and reads bank metadata, after a balance.
typedef TokenNamer = Future<ChainBalance?> Function(ChainEntry chain, ChainBalance balance);

final tokenNamerProvider = Provider<TokenNamer>((ref) {
  final client = ref.watch(chainClientProvider);
  final resolver = ref.watch(denomResolverProvider);
  final memo = <String, ({DateTime at, int? decimals, String? name})>{};
  final failedAt = <String, DateTime>{};
  return (chain, balance) async {
    if (!client.enabled) return null;
    final vouchers = [
      for (final token in balance.tokens)
        if (token.denom.startsWith('ibc/')) token.denom,
    ];
    if (vouchers.isNotEmpty) {
      await identifyHeld(chain.chainId, vouchers, lookup: (chainId, denom) async {
        final resolved = await resolver.resolve(chainId, denom);
        return (
          baseDenom: resolved.baseDenom,
          path: resolved.path,
          originChainId: resolved.originChainId,
          hopChainIds: resolved.hopChainIds,
        );
      }).timeout(const Duration(seconds: 20), onTimeout: () => const {});
    }
    // Metadata only for what the identity could not name: a known token
    // never costs a request here.
    final now = DateTime.now();
    final unnamed = [
      for (final token in balance.tokens)
        if (token.denom != chain.coinMinimalDenom &&
            identityOf(chain.chainId, token.denom).provenance == TokenProvenance.unknown)
          token.denom,
    ];
    final ask = [
      for (final denom in unnamed)
        if ((memo['${chain.chainId}:$denom']?.at ?? DateTime(0)).isBefore(now.subtract(const Duration(minutes: 30))) &&
            (failedAt['${chain.chainId}:$denom'] ?? DateTime(0)).isBefore(now.subtract(const Duration(minutes: 1))))
          denom,
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < ask.length && next < 24) {
        final denom = ask[next++];
        final key = '${chain.chainId}:$denom';
        final facts = await client.bankMetadata(chain, denom);
        if (facts == null) {
          failedAt[key] = DateTime.now();
        } else {
          memo[key] = (at: DateTime.now(), decimals: facts.decimals, name: facts.name);
        }
      }
    }

    if (ask.isNotEmpty) await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    var changed = false;
    final tokens = [
      for (final token in balance.tokens)
        if (memo['${chain.chainId}:${token.denom}'] case final facts?)
          () {
            if (facts.decimals != token.metadataDecimals || facts.name != token.metadataName) {
              changed = true;
            }
            return token.withMetadata(facts.decimals, facts.name);
          }()
        else
          token,
    ];
    return changed ? balance.withTokens(tokens) : null;
  };
});

class PortfolioController extends StateNotifier<PortfolioState> {
  PortfolioController({
    required List<ChainAccount> accounts,
    required BalanceFetcher fetch,
    required BalanceCache cache,
    required bool readsOn,
    TokenNamer? namer,
  })  : _accounts = accounts,
        _fetch = fetch,
        _cache = cache,
        _namer = namer,
        _readsOn = readsOn,
        super(PortfolioState(
          readsOff: !readsOn,
          chains: {
            for (final account in accounts)
              account.chain.chainId: ?cache[_key(account)],
          },
        ));

  final List<ChainAccount> _accounts;
  final BalanceFetcher _fetch;
  final BalanceCache _cache;
  final TokenNamer? _namer;
  final bool _readsOn;
  Future<void>? _running;
  bool _disposed = false;

  static String _key(ChainAccount account) => '${account.chain.chainId}|${account.address}';

  /// Read every chain whose answer is older than [balanceTtl], or all of
  /// them with [force]. Chains with a balance last time go first: they are
  /// the rows the user is looking at. Concurrent calls share one pass.
  Future<void> refresh({bool force = false}) {
    if (!_readsOn) {
      state = PortfolioState(
        readsOff: true,
        chains: {
          for (final account in _accounts)
            account.chain.chainId:
                const ChainRead(failure: ChainReadFailure(ChainReadFailureKind.readsDisabled)),
        },
      );
      return Future.value();
    }
    final running = _running;
    if (running != null && !force) return running;
    final run = _refresh(force);
    _running = run;
    return run.whenComplete(() {
      if (identical(_running, run)) _running = null;
    });
  }

  Future<void> _refresh(bool force) async {
    final now = DateTime.now();
    final due = [
      for (final account in _accounts)
        if (force ||
            _cache[_key(account)]?.at == null ||
            now.difference(_cache[_key(account)]!.at!) >= balanceTtl ||
            _cache[_key(account)]?.balance == null)
          account,
    ]..sort((a, b) {
        int rank(ChainAccount account) {
          final hit = _cache[_key(account)]?.balance;
          if (hit == null) return 1;
          return hit.available != '0' || hit.tokens.isNotEmpty ? 0 : 2;
        }

        return rank(a) - rank(b);
      });
    if (due.isEmpty) return;
    _publish(refreshing: true, update: {
      for (final account in due) account.chain.chainId: (state.chains[account.chain.chainId] ?? const ChainRead()).started(),
    });
    var next = 0;
    Future<void> worker() async {
      while (next < due.length && !_disposed) {
        final account = due[next++];
        BalanceRead read;
        try {
          read = await _fetch(account.chain, account.address);
        } on Object catch (error) {
          read = BalanceUnavailable(
            ChainReadFailure(ChainReadFailureKind.unreachable, detail: '$error'),
          );
        }
        if (_disposed) return;
        final previous = _cache[_key(account)];
        final ChainRead row = switch (read) {
          BalanceLoaded(:final balance) => ChainRead(balance: _carryMetadata(previous?.balance, balance), at: DateTime.now()),
          // A failed refresh keeps the last balance read this session, marked
          // with the failure, instead of turning a known balance into nothing.
          BalanceUnavailable(:final failure) => ChainRead(
              balance: previous?.balance,
              failure: failure,
              at: previous?.at,
            ),
        };
        _cache[_key(account)] = row;
        _publish(update: {account.chain.chainId: row});
        final balance = row.balance;
        if (read is BalanceLoaded && balance != null) unawaited(_name(account, balance));
      }
    }

    await Future.wait([for (var i = 0; i < balanceConcurrency; i++) worker()]);
    _publish(refreshing: false);
  }

  /// Metadata names and decimals carry over to the next read of the same denom.
  static ChainBalance _carryMetadata(ChainBalance? previous, ChainBalance next) {
    if (previous == null) return next;
    final known = {for (final token in previous.tokens) token.denom: token};
    var carried = false;
    final tokens = [
      for (final token in next.tokens)
        if (known[token.denom] case final old? when old.metadataDecimals != null || old.metadataName != null)
          () {
            carried = true;
            return token.withMetadata(old.metadataDecimals, old.metadataName);
          }()
        else
          token,
    ];
    return carried ? next.withTokens(tokens) : next;
  }

  Future<void> _name(ChainAccount account, ChainBalance balance) async {
    final namer = _namer;
    if (namer == null) return;
    try {
      final named = await namer(account.chain, balance);
      if (named == null || _disposed) return;
      final row = ChainRead(balance: named, at: _cache[_key(account)]?.at ?? DateTime.now());
      _cache[_key(account)] = row;
      _publish(update: {account.chain.chainId: row});
    } on Object {
      // Names that could not be learned now are learned on the next read.
    }
  }

  void _publish({bool? refreshing, Map<String, ChainRead> update = const {}}) {
    if (_disposed) return;
    state = PortfolioState(
      chains: {...state.chains, ...update},
      refreshing: refreshing ?? state.refreshing,
      readsOff: state.readsOff,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Balances of the active account on every enabled chain, published as each
/// chain answers.
final portfolioProvider = StateNotifierProvider<PortfolioController, PortfolioState>((ref) {
  final controller = PortfolioController(
    accounts: ref.watch(chainAccountsProvider),
    fetch: ref.watch(balanceFetcherProvider),
    cache: ref.watch(balanceCacheProvider),
    readsOn: ref.watch(preferencesProvider.select((p) => p.liveReads)),
    namer: ref.watch(tokenNamerProvider),
  );
  unawaited(controller.refresh());
  return controller;
});

/// Balances for every enabled chain of the active account, as a plain map for
/// the screens that only need the numbers (Swap, Earn, Bridge). Loading until
/// the first chain answers; after that it carries what has answered so far.
final balancesProvider = FutureProvider<Map<String, ChainBalance>>((ref) {
  final accounts = ref.watch(chainAccountsProvider);
  if (accounts.isEmpty) return BalanceReads.empty;
  final state = ref.watch(portfolioProvider);
  if (!state.anySettled && state.loadingAny) {
    // Stays loading; the provider runs again when the first chain answers.
    return Completer<Map<String, ChainBalance>>().future;
  }
  return BalanceReads(state.balances, state.failures);
});

/// Why a chain is missing from [balancesProvider], keyed by chain id.
///
/// Empty while the read is still in flight - "not read yet" is the provider's
/// loading state, not a failure.
final balanceFailuresProvider = Provider<Map<String, ChainReadFailure>>((ref) {
  final reads = ref.watch(balancesProvider).valueOrNull;
  return reads is BalanceReads ? reads.failures : const {};
});

/// Bumped whenever a voucher is newly proven, so memoized rows rename.
final identityGenerationProvider = StateNotifierProvider<_GenerationNotifier, int>(
  (ref) => _GenerationNotifier(),
);

class _GenerationNotifier extends StateNotifier<int> {
  _GenerationNotifier() : super(tokenFactsGeneration.value) {
    tokenFactsGeneration.addListener(_changed);
  }

  void _changed() {
    if (mounted) state = tokenFactsGeneration.value;
  }

  @override
  void dispose() {
    tokenFactsGeneration.removeListener(_changed);
    super.dispose();
  }
}

/* -------------------------------------------------------------------------- *
 * Prices
 * -------------------------------------------------------------------------- */

final priceServiceProvider = Provider<PriceService>((ref) => PriceService());

/// The chains whose coin is worth pricing: every enabled chain, plus the
/// issuers of what is held there (USDC.n on Osmosis is priced as Noble's).
/// A string, so the price read only reruns when the set itself changes.
final priceTargetKeyProvider = Provider<String>((ref) {
  final accounts = ref.watch(chainAccountsProvider);
  final balances = ref.watch(portfolioProvider.select((s) => s.balances));
  ref.watch(identityGenerationProvider);
  final ids = <String>{for (final account in accounts) account.chain.chainId};
  for (final account in accounts) {
    for (final token in balances[account.chain.chainId]?.tokens ?? const <HeldToken>[]) {
      final identity = rowIdentity(account.chain, token);
      final origin = identity.originChainId;
      if (origin != null && identity.proven && identity.decimalsKnown) ids.add(origin);
    }
  }
  final sorted = ids.toList()..sort();
  return sorted.join(',');
});

/// Spot prices in the user's currency. Absent, never zero, when unknown.
final pricesProvider = FutureProvider<PriceSnapshot>((ref) async {
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  final currency = normaliseCurrency(ref.watch(preferencesProvider.select((p) => p.currency)));
  final key = ref.watch(priceTargetKeyProvider);
  if (!live || key.isEmpty || !ChainCatalog.isLoaded) {
    return PriceSnapshot(currency: currency, prices: const {});
  }
  final sources = await loadExchangeSources();
  final targets = <PriceTarget>[];
  for (final chainId in key.split(',')) {
    final entry = ChainCatalog.instance.find(chainId);
    if (entry == null) continue;
    final gecko = entry.coinGeckoId;
    final exchange = gecko == null ? sources[chainId] : null;
    if (gecko == null && exchange == null) continue;
    targets.add(PriceTarget(chainId: chainId, coinGeckoId: gecko, exchange: exchange));
  }
  if (targets.isEmpty) return PriceSnapshot(currency: currency, prices: const {});
  // Read again when the prices age out, as long as something is listening.
  final timer = Timer(priceCacheTtl, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(priceServiceProvider).prices(targets, currency);
});

/// The chains priced from one exchange market, not an aggregate (SAF).
Set<String> exchangePricedChains(PriceSnapshot snapshot) => {
      for (final MapEntry(:key, :value) in snapshot.prices.entries)
        if (value.source != null) key,
    };

/* -------------------------------------------------------------------------- *
 * Staking reads other screens use
 * -------------------------------------------------------------------------- */

ChainEntry? _chain(String chainId) =>
    ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;

String? _addressFor(Ref ref, String chainId) {
  for (final account in ref.watch(chainAccountsProvider)) {
    if (account.chain.chainId == chainId) return account.address;
  }
  return null;
}

final validatorsProvider =
    FutureProvider.family<List<ValidatorInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  if (chain == null) return const [];
  return ref.watch(chainClientProvider).validators(chain);
});

final delegationsProvider =
    FutureProvider.family<List<DelegationInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  return ref.watch(chainClientProvider).delegations(chain, address);
});

final unbondingProvider =
    FutureProvider.family<List<UnbondingInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  return ref.watch(chainClientProvider).unbonding(chain, address);
});

final proposalsProvider =
    FutureProvider.family<List<ProposalInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  if (chain == null) return const [];
  return ref.watch(chainClientProvider).proposals(chain);
});

/* -------------------------------------------------------------------------- *
 * History
 * -------------------------------------------------------------------------- */

/// One chain's recent history; throws [ChainReadException] when the chain
/// could not be asked, so a screen can tell that from "no history".
final activityProvider =
    FutureProvider.family<List<ActivityItem>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  await loadBundledLinks();
  return ref
      .watch(chainClientProvider)
      .activity(chain, address, limit: 25, feeRecipients: swapFeeRecipients);
});

/// History reads at once across chains.
const int activityConcurrency = 4;

/// Rows asked of each chain in the merged feed.
const int activityPerChain = 10;

@immutable
class ActivityFeedState {
  const ActivityFeedState({
    this.items = const [],
    this.failed = const {},
    this.pending = const {},
    this.readsOff = false,
  });

  /// Newest first, across every chain that answered.
  final List<ActivityItem> items;

  /// Chains whose history could not be read, with why.
  final Map<String, String> failed;

  /// Chains not read yet in this pass.
  final Set<String> pending;
  final bool readsOff;

  bool get loading => pending.isNotEmpty;
}

/// History fetcher, so tests can stand in for the network.
typedef ActivityFetcher = Future<List<ActivityItem>> Function(ChainEntry chain, String address);

final activityFetcherProvider = Provider<ActivityFetcher>((ref) {
  final client = ref.watch(chainClientProvider);
  return (chain, address) async {
    await loadBundledLinks();
    return client.activity(chain, address, limit: activityPerChain, feeRecipients: swapFeeRecipients);
  };
});

class ActivityFeedController extends StateNotifier<ActivityFeedState> {
  ActivityFeedController({
    required List<ChainAccount> accounts,
    required ActivityFetcher fetch,
    required bool readsOn,
    required Set<String> funded,
  })  : _accounts = accounts,
        _fetch = fetch,
        _readsOn = readsOn,
        _funded = funded,
        super(ActivityFeedState(readsOff: !readsOn));

  final List<ChainAccount> _accounts;
  final ActivityFetcher _fetch;
  final bool _readsOn;
  final Set<String> _funded;
  bool _disposed = false;
  Future<void>? _running;

  /// Read every chain's history, chains holding something first.
  Future<void> refresh() {
    if (!_readsOn || _accounts.isEmpty) return Future.value();
    return _running ??= _refresh().whenComplete(() => _running = null);
  }

  Future<void> _refresh() async {
    final order = [..._accounts]..sort((a, b) {
        final af = _funded.contains(a.chain.chainId) ? 0 : 1;
        final bf = _funded.contains(b.chain.chainId) ? 0 : 1;
        return af - bf;
      });
    state = ActivityFeedState(
      items: state.items,
      pending: {for (final account in order) account.chain.chainId},
    );
    var next = 0;
    Future<void> worker() async {
      while (next < order.length && !_disposed) {
        final account = order[next++];
        final chainId = account.chain.chainId;
        try {
          final rows = await _fetch(account.chain, account.address);
          if (_disposed) return;
          final merged = [
            ...state.items.where((item) => item.chainId != chainId),
            ...rows,
          ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          state = ActivityFeedState(
            items: merged,
            failed: {...state.failed}..remove(chainId),
            pending: {...state.pending}..remove(chainId),
          );
        } on Object catch (error) {
          if (_disposed) return;
          state = ActivityFeedState(
            items: state.items,
            failed: {...state.failed, chainId: '$error'},
            pending: {...state.pending}..remove(chainId),
          );
        }
      }
    }

    await Future.wait([for (var i = 0; i < activityConcurrency; i++) worker()]);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// History merged across every enabled chain, published as chains answer.
final activityFeedProvider = StateNotifierProvider<ActivityFeedController, ActivityFeedState>((ref) {
  final balances = ref.read(portfolioProvider).balances;
  final controller = ActivityFeedController(
    accounts: ref.watch(chainAccountsProvider),
    fetch: ref.watch(activityFetcherProvider),
    readsOn: ref.watch(preferencesProvider.select((p) => p.liveReads)),
    funded: {
      for (final MapEntry(:key, :value) in balances.entries)
        if (value.available != '0' || value.tokens.isNotEmpty) key,
    },
  );
  unawaited(controller.refresh());
  return controller;
});

/// Activity merged across every enabled chain, newest first: the plain list
/// other screens read (Missions, Notifications).
final allActivityProvider = FutureProvider<List<ActivityItem>>((ref) {
  final state = ref.watch(activityFeedProvider);
  if (state.readsOff) return const [];
  if (state.items.isEmpty && state.loading) {
    return Completer<List<ActivityItem>>().future;
  }
  return state.items;
});
