/// Fresh balance reads for the Swap tab.
///
/// The tab's base read ([swapHoldingsProvider]) happens once, when the app
/// builds it. Everything that must be current sooner goes through
/// [SwapBalanceController]: it re-reads chosen chains in the background (their
/// cached numbers stay on screen meanwhile), lays the answers over the base
/// read, and follows a swap after it is broadcast until the money has moved.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/tx/tx_inclusion.dart';

/// Every denom [address] holds on [chain], read past the transport's cache.
/// Null when the chain cannot be read: unknown is not zero.
Future<List<HeldToken>?> readHeldTokens(LcdClient lcd, String address) async {
  try {
    final body = await lcd.getJson(
      '/cosmos/bank/v1beta1/balances/${Uri.encodeComponent(address)}',
      const LcdRequestOptions(
        cacheTtl: Duration.zero,
        query: {'pagination.limit': 1000},
      ),
    );
    final rows = body is Map ? body['balances'] : null;
    if (rows is! List) return null;
    return [
      for (final row in rows)
        if (row is Map && row['denom'] is String && row['amount'] is String)
          HeldToken(row['denom'] as String, row['amount'] as String),
    ];
  } on InterchainError {
    return null;
  }
}

@immutable
class SwapBalanceReads {
  const SwapBalanceReads({
    this.fresh = const {},
    this.refreshing = const {},
    this.failed = const {},
    this.checkedAt = const {},
  });

  /// Chains read again since the base read, laid over it.
  final Map<String, List<HeldToken>> fresh;

  /// Chains being read right now.
  final Set<String> refreshing;

  /// Chains whose last re-read did not answer.
  final Set<String> failed;
  final Map<String, DateTime> checkedAt;

  bool get busy => refreshing.isNotEmpty;

  SwapBalanceReads copyWith({
    Map<String, List<HeldToken>>? fresh,
    Set<String>? refreshing,
    Set<String>? failed,
    Map<String, DateTime>? checkedAt,
  }) => SwapBalanceReads(
    fresh: fresh ?? this.fresh,
    refreshing: refreshing ?? this.refreshing,
    failed: failed ?? this.failed,
    checkedAt: checkedAt ?? this.checkedAt,
  );
}

/// One swap being followed after it was broadcast.
class _Follow {
  _Follow(this.hash);
  final String hash;
  bool stopped = false;
  final Completer<void> _wake = Completer<void>();

  /// Ends the wait between reads at once.
  void stop() {
    stopped = true;
    if (!_wake.isCompleted) _wake.complete();
  }

  Future<void> sleep(Duration length) =>
      Future.any([Future<void>.delayed(length), _wake.future]);
}

typedef InclusionWaiter =
    Future<Inclusion> Function(ChainEntry chain, String hash);

class SwapBalanceController extends StateNotifier<SwapBalanceReads> {
  SwapBalanceController(
    this._ref, {
    this.pollEvery = const Duration(seconds: 8),
    this.window = const Duration(minutes: 3),
    InclusionWaiter? waitForTx,
  }) : _waitForTx =
           waitForTx ?? ((chain, hash) => waitForInclusion(chain, hash)),
       super(const SwapBalanceReads());

  final Ref _ref;

  /// How often the destination is read while a cross-chain swap is in flight
  /// (6 to 10 seconds is the brief), and for how long.
  final Duration pollEvery;
  final Duration window;
  final InclusionWaiter _waitForTx;

  final Map<String, Future<bool>> _inflight = {};
  final Map<String, _Follow> _follows = {};

  @override
  void dispose() {
    for (final follow in _follows.values) {
      follow.stop();
    }
    super.dispose();
  }

  /// Forget every re-read: the base read is about to be made again and is
  /// newer than all of them.
  void reset() {
    if (!mounted) return;
    state = const SwapBalanceReads();
  }

  /// Read [chainIds] again (every enabled chain when null). The old numbers
  /// stay in [state] until the new ones arrive. Chains read within [minAge]
  /// are left alone. True when every chain asked for answered.
  Future<bool> refresh(Iterable<String>? chainIds, {Duration? minAge}) async {
    final wanted = chainIds?.toSet();
    final registry = _ref.read(interchainRegistryProvider);
    final factory = _ref.read(lcdFactoryProvider);
    final now = DateTime.now();
    final reads = <Future<bool>>[];
    for (final account in _ref.read(chainAccountsProvider)) {
      final id = account.chain.chainId;
      if (wanted != null && !wanted.contains(id)) continue;
      final chain = registry.get(id);
      if (chain == null || lcdEndpointsFromChain(chain).isEmpty) continue;
      final inflight = _inflight[id];
      if (inflight != null) {
        reads.add(inflight);
        continue;
      }
      final seen = state.checkedAt[id];
      if (minAge != null && seen != null && now.difference(seen) < minAge) {
        continue;
      }
      final read = _read(id, factory(chain), account.address);
      _inflight[id] = read;
      reads.add(read);
    }
    if (reads.isEmpty) return true;
    final results = await Future.wait(reads);
    return results.every((ok) => ok);
  }

  Future<bool> _read(String chainId, LcdClient lcd, String address) async {
    if (mounted) {
      state = state.copyWith(refreshing: {...state.refreshing, chainId});
    }
    try {
      final tokens = await readHeldTokens(lcd, address);
      if (!mounted) return tokens != null;
      state = state.copyWith(
        refreshing: {...state.refreshing}..remove(chainId),
        fresh: tokens == null ? null : {...state.fresh, chainId: tokens},
        failed: tokens == null
            ? {...state.failed, chainId}
            : ({...state.failed}..remove(chainId)),
        checkedAt: {...state.checkedAt, chainId: DateTime.now()},
      );
      return tokens != null;
    } finally {
      _inflight.remove(chainId);
    }
  }

  Map<String, String> _amounts(String chainId) => {
    for (final t in state.fresh[chainId] ?? const <HeldToken>[])
      t.denom: t.amount,
  };

  /// A swap was signed and broadcast. Read [source] once the transaction is in
  /// a block, whatever the block decided (a failed one still paid its fee).
  /// A swap that lands on another chain also reads [destination] every
  /// [pollEvery] for up to [window], until something there changed or
  /// [finishSwap] says the packets are done; then both chains once more, which
  /// is where a refund shows up.
  void followSwap({
    required ChainEntry source,
    required String txHash,
    String? destinationChainId,
  }) {
    _follows[txHash]?.stop();
    final follow = _follows[txHash] = _Follow(txHash);
    unawaited(_run(follow, source, destinationChainId));
  }

  /// The packet tracker reached a terminal state (delivered, timed out or
  /// failed) for the swap sent in [txHash].
  void finishSwap(String txHash) => _follows[txHash]?.stop();

  Future<void> _run(
    _Follow follow,
    ChainEntry source,
    String? destinationChainId,
  ) async {
    final dest = destinationChainId == source.chainId
        ? null
        : destinationChainId;
    try {
      // The baseline is read before the packets can have arrived.
      if (dest != null) await refresh([dest]);
      // No read of the destination yet (its baseline read failed too): the
      // first one that answers becomes the baseline, rather than an empty map
      // that any balance at all would differ from.
      var before =
          dest != null && state.fresh.containsKey(dest) ? _amounts(dest) : null;
      final started = DateTime.now();

      final inclusion = await _waitForTx(source, follow.hash);
      if (!mounted) return;
      await refresh([source.chainId]);
      _ref.invalidate(balancesProvider);
      // Refused in its block: nothing was sent on, only the fee left.
      if (dest == null || inclusion is FailedInBlock) return;

      while (!follow.stopped &&
          mounted &&
          DateTime.now().difference(started) < window) {
        await follow.sleep(pollEvery);
        if (follow.stopped || !mounted) break;
        await refresh([dest]);
        if (!state.fresh.containsKey(dest)) continue;
        final now = _amounts(dest);
        if (before == null) {
          before = now;
        } else if (!mapEquals(before, now)) {
          follow.stop();
        }
      }
      if (!mounted) return;
      // Delivered, refunded or timed out: both ends are read once more.
      await refresh([source.chainId, dest]);
      _ref.invalidate(balancesProvider);
    } finally {
      if (identical(_follows[follow.hash], follow)) {
        _follows.remove(follow.hash);
      }
    }
  }
}

final swapBalancesProvider =
    StateNotifierProvider<SwapBalanceController, SwapBalanceReads>(
      (ref) => SwapBalanceController(ref),
    );
