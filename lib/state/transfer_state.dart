/// Cross-chain sends: the planner, and the transfers still in flight.
///
/// The planner (`lib/transfers/route_plan.dart`) is one per session, so a
/// channel checked on both chains is not asked about again for ten minutes
/// and a channel the chains refused stays out of the graph. The in-flight
/// list survives restarts (`lib/transfers/pending_transfers.dart`) and is
/// followed while the app is open: each record is polled until it lands,
/// comes back, or needs the user, and then dropped (a recoverable swap stays,
/// because it is the way back to the recover action).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';

/// One planner per session; the route cache is read, not watched, so a
/// discovery that writes to it does not throw away this session's checks.
final transferPlannerProvider = Provider<TransferPlanner>((ref) {
  final store = ref.read(routeRegistryProvider);
  final capabilities = ref.watch(chainCapabilityCacheProvider);
  return TransferPlanner(TransferPlannerDeps(
    registry: ref.watch(interchainRegistryProvider),
    channels: ref.watch(channelServiceProvider),
    routes: () => store.registry.list(),
    rememberRoutes: store.remember,
    lcdFor: (chainId) => ref.read(lcdResolverProvider)(chainId),
    resolveDenom: (chain, denom) => ref.read(denomResolverProvider).resolve(chain.chainId, denom),
    probeCapabilities: capabilities.probe,
    capabilities: capabilities.lookup,
  ));
});

/// The wallet's own address on each chain, for the receiver on an
/// intermediate hop. Derived with the unlocked phrase; a chain whose address
/// cannot be derived is left out, and the planner then blocks the route
/// rather than addressing a packet to "pfm".
Future<Map<String, String>> Function(List<String>) intermediateAddresses(Ref ref) =>
    (chainIds) async {
      final phrase = ref.read(phraseProvider);
      final index = ref.read(walletProvider).active?.index ?? 0;
      if (phrase == null || !ChainCatalog.isLoaded) return const {};
      final out = <String, String>{};
      for (final chainId in chainIds) {
        final chain = ChainCatalog.instance.find(chainId);
        if (chain == null) continue;
        try {
          out[chainId] = WalletKernel.instance
              .deriveAddress(phrase: phrase, chain: chain, accountIndex: index)
              .address;
        } on Object {
          // Left out on purpose; see above.
        }
      }
      return out;
    };

final intermediateAddressesProvider =
    Provider<Future<Map<String, String>> Function(List<String>)>(intermediateAddresses);

/* -------------------------------------------------------------------------- *
 * In flight
 * -------------------------------------------------------------------------- */

@immutable
class PendingTransfersState {
  const PendingTransfersState({this.records = const [], this.tracked = const {}, this.loaded = false});

  /// Newest first.
  final List<PendingTransfer> records;

  /// Last poll per transaction hash.
  final Map<String, TrackedTransfer> tracked;
  final bool loaded;
}

/// How often an in-flight transfer is asked about.
const Duration transferPollInterval = Duration(seconds: 15);

/// Polls one record; tests replace it.
typedef TransferPoller = Future<TrackedTransfer> Function(PendingTransfer record);

final transferPollerProvider = Provider<TransferPoller>((ref) {
  return (record) => pollTransfer(record, ref.read(lcdResolverProvider));
});

class PendingTransfersController extends StateNotifier<PendingTransfersState> {
  PendingTransfersController(this._poll, {PendingTransferStore store = const PendingTransferStore()})
      : _store = store,
        super(const PendingTransfersState()) {
    unawaited(_load());
  }

  final TransferPoller _poll;
  final PendingTransferStore _store;
  final StreamController<TrackedTransfer> _settled = StreamController.broadcast();
  Timer? _timer;
  bool _polling = false;

  /// One event per transfer that reached an outcome, for a toast.
  Stream<TrackedTransfer> get settled => _settled.stream;

  Future<void> _load() async {
    final records = await _store.list();
    if (!mounted) return;
    state = PendingTransfersState(records: records, tracked: state.tracked, loaded: true);
    _schedule();
  }

  /// Remember a transfer that was just broadcast, before any screen changes,
  /// so an app that closes on the next frame keeps the only view of the funds.
  Future<void> add(PendingTransfer record) async {
    final records = await _store.save(record);
    if (!mounted) return;
    state = PendingTransfersState(records: records, tracked: state.tracked, loaded: true);
    _schedule();
    unawaited(pollNow());
  }

  /// Stop following a transfer (the user dismissed it).
  Future<void> forget(String txHash) async {
    final records = await _store.remove(txHash);
    if (!mounted) return;
    state = PendingTransfersState(
      records: records,
      tracked: {...state.tracked}..remove(txHash),
      loaded: true,
    );
    _schedule();
  }

  void _schedule() {
    final active = state.records.any((record) => !(state.tracked[record.txHash]?.finished ?? false));
    if (!active) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(transferPollInterval, (_) => unawaited(pollNow()));
  }

  /// Ask every unfinished record once.
  Future<void> pollNow() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      for (final record in [...state.records]) {
        final previous = state.tracked[record.txHash];
        if (previous?.finished ?? false) continue;
        final result = await _poll(record);
        if (!mounted) return;
        state = PendingTransfersState(
          records: state.records,
          tracked: {...state.tracked, record.txHash: result},
          loaded: true,
        );
        if (result.outcome != null && previous?.outcome != result.outcome) {
          _settled.add(result);
          // A recoverable swap stays listed: it is the way to the recover action.
          if (result.outcome != RouteOutcome.recoverable) {
            final records = await _store.remove(record.txHash);
            if (!mounted) return;
            // Kept on screen for this visit, so the row turns to its outcome
            // instead of vanishing.
            state = PendingTransfersState(
              records: [
                ...records,
                if (!records.any((row) => row.txHash == record.txHash)) record,
              ]..sort((a, b) => b.startedAt.compareTo(a.startedAt)),
              tracked: state.tracked,
              loaded: true,
            );
          }
        }
      }
    } finally {
      _polling = false;
      if (mounted) _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_settled.close());
    super.dispose();
  }
}

final pendingTransfersProvider =
    StateNotifierProvider<PendingTransfersController, PendingTransfersState>(
  (ref) => PendingTransfersController(ref.watch(transferPollerProvider)),
);

/// The plan a pending record follows, for screens that only need its hops.
List<RouteHop> hopsOf(PendingTransfer record) => record.plan.hops;
