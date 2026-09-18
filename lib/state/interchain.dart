/// Riverpod wiring for the interchain engine.
///
/// Every chain-facing piece of the swap and cross-send flows is built here from
/// `lib/services/interchain`, so there is one channel service, one denom
/// resolver and one channel graph in the app. Screens hold none of this state
/// themselves.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/preferences.dart';

/// An empty registry, for the window before the catalog asset has loaded.
///
/// Returning this rather than throwing keeps a screen that mounts early in its
/// "no chains yet" state instead of crashing on first build.
class _EmptyRegistry implements ChainRegistry {
  const _EmptyRegistry();

  @override
  ChainInfo? get(String chainId) => null;

  @override
  List<ChainInfo> list() => const [];
}

final interchainRegistryProvider = Provider<ChainRegistry>((ref) {
  if (!ChainCatalog.isLoaded) return const _EmptyRegistry();
  return CatalogChainRegistry(ChainCatalog.instance);
});

/// The engine's transport, gated on the same `liveReads` preference every other
/// read in the app uses.
final lcdFactoryProvider = Provider<LcdClientFactory>((ref) {
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  return createLcdClientFactory(
    readsAllowed: () => live,
    cacheTtl: const Duration(seconds: 30),
  );
});

final channelServiceProvider = Provider<IbcChannelService>((ref) {
  return IbcChannelService(
    lcd: ref.watch(lcdFactoryProvider),
    registry: ref.watch(interchainRegistryProvider),
  );
});

final denomContextProvider = Provider<DenomContext>((ref) {
  final channels = ref.watch(channelServiceProvider);
  return DenomContext(
    lcd: ref.watch(lcdFactoryProvider),
    registry: ref.watch(interchainRegistryProvider),
    // Proving where a voucher came from needs the channel's counterparty, and
    // the channel service is the only thing that reads it.
    counterparty: (chainId, portId, channelId) async {
      final check = await channels.validateIbcChannel(
        chainId,
        channelId,
        portId: portId,
      );
      return check.counterpartyChainId;
    },
  );
});

final denomResolverProvider = Provider<DenomResolver>(
  (ref) => createDenomResolver(ref.watch(denomContextProvider)),
);

/// Resolves a chain id to an LCD for packet tracking.
final lcdResolverProvider = Provider<LcdResolver>((ref) {
  final registry = ref.watch(interchainRegistryProvider);
  final factory = ref.watch(lcdFactoryProvider);
  return (chainId) {
    final chain = registry.get(chainId);
    if (chain == null || lcdEndpointsFromChain(chain).isEmpty) return null;
    return factory(chain);
  };
});

/// The Osmosis sidecar query server, which prices swaps.
///
/// A separate client from the chain LCD because it is a different host with a
/// different path space, and it is gated on the same live-reads preference: a
/// wallet told to stay offline must not call a pricing service either.
final swapRouterClientProvider = Provider<LcdClient>((ref) {
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  return HttpLcdClient(
    chainId: kSwapVenueChainId,
    endpoints: const [kOsmosisRouterBaseUrl],
    readsAllowed: () => live,
    // A quote is worthless once it is seconds old, so nothing is cached.
    cacheTtl: Duration.zero,
  );
});

/* -------------------------------------------------------------------------- *
 * Channel route cache
 * -------------------------------------------------------------------------- */

const String _kRouteSnapshot = 'zunia.interchain.routes';

/// The channel pairs this wallet has seen, persisted between launches.
///
/// A cache, never an authority: everything in it is re-verified on chain before
/// a transfer is built, and a route older than [kRouteMaxAge] is not offered as
/// verified.
class RouteRegistryStore extends ChangeNotifier {
  RouteRegistryStore() : _registry = RouteRegistry(seedChannelRoutes) {
    unawaited(_restore());
  }

  RouteRegistry _registry;

  RouteRegistry get registry => _registry;

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kRouteSnapshot);
    if (raw == null) return;
    final restored = RouteRegistry.fromSnapshot(raw)..putMany(seedChannelRoutes);
    _registry = restored;
    notifyListeners();
  }

  /// Remember channels discovered on chain, so the next plan starts from them.
  Future<void> remember(Iterable<ChannelRoute> routes) async {
    if (routes.isEmpty) return;
    _registry.putMany(routes);
    notifyListeners();
    final store = await SharedPreferences.getInstance();
    await store.setString(_kRouteSnapshot, _registry.toSnapshot());
  }

  /// Links for the planner's graph, tagged with how much they can be trusted.
  List<ChannelLink> links({DateTime? now}) {
    final at = now ?? DateTime.now();
    return [
      for (final route in _registry.list())
        ChannelLink(
          sourceChainId: route.sourceChainId,
          destChainId: route.destChainId,
          channelId: route.channelId,
          counterpartyChannelId: route.counterpartyChannelId.isEmpty
              ? null
              : route.counterpartyChannelId,
          source: switch (route.source) {
            ChannelRouteSource.manual => ChannelLinkSource.manual,
            // Only a check we made recently counts as verified. A stale
            // discovery is offered, and flagged, exactly like a seed row.
            ChannelRouteSource.discovered =>
              _registry.isFresh(route, now: at)
                  ? ChannelLinkSource.verified
                  : ChannelLinkSource.seed,
            ChannelRouteSource.seed => ChannelLinkSource.seed,
          },
          state: route.source == ChannelRouteSource.discovered &&
                  _registry.isFresh(route, now: at)
              ? IbcChannelState.open
              : IbcChannelState.unknown,
        ),
    ];
  }
}

final routeRegistryProvider = ChangeNotifierProvider<RouteRegistryStore>(
  (ref) => RouteRegistryStore(),
);

/* -------------------------------------------------------------------------- *
 * Swap venue
 * -------------------------------------------------------------------------- */

/// Whether the crosschain-swaps contract can be used, and if not, why not.
///
/// Every `false` here carries a sentence a screen can render next to a disabled
/// control. There is no state in which the feature is quietly unavailable.
@immutable
class SwapVenueStatus {
  const SwapVenueStatus._({
    required this.ready,
    required this.chainId,
    required this.contractAddress,
    required this.reason,
    this.checked = false,
  });

  const SwapVenueStatus.unavailable(String reason, {String? chainId})
      : this._(
          ready: false,
          chainId: chainId ?? kSwapVenueChainId,
          contractAddress: null,
          reason: reason,
        );

  const SwapVenueStatus.ready({
    required String chainId,
    required String contractAddress,
  }) : this._(
          ready: true,
          chainId: chainId,
          contractAddress: contractAddress,
          reason: null,
          checked: true,
        );

  final bool ready;
  final String chainId;
  final String? contractAddress;

  /// Why the swap is off. Null only when [ready].
  final String? reason;

  /// True when the address was confirmed to exist on chain this session.
  final bool checked;

  SwapVenue? get venue => ready && contractAddress != null
      ? SwapVenue(chainId: chainId, contractAddress: contractAddress!)
      : null;
}

/// Check the configured crosschain-swaps contract against the chain.
///
/// Fails closed at every step. An address that is unset, on a chain we have no
/// endpoint for, or absent from the chain's wasm index disables the swap with
/// the specific reason rather than being taken on trust: this address is the
/// one field where a wrong value silently sends funds somewhere unrecoverable.
final swapVenueStatusProvider = FutureProvider<SwapVenueStatus>((ref) async {
  final address = kOsmosisXcsContract.trim();
  if (address.isEmpty) {
    return const SwapVenueStatus.unavailable(
      'This build has no Osmosis crosschain-swaps contract address. Swaps stay '
      'off until OSMOSIS_XCS_CONTRACT is set: the address is deployment data, '
      'and a wrong one would send funds to a contract that cannot return them.',
    );
  }

  final registry = ref.watch(interchainRegistryProvider);
  final chain = registry.get(kSwapVenueChainId);
  if (chain == null) {
    return SwapVenueStatus.unavailable(
      '$kSwapVenueChainId is not in the chain catalog, so the swap contract '
      'cannot be checked.',
    );
  }
  if (lcdEndpointsFromChain(chain).isEmpty) {
    return SwapVenueStatus.unavailable(
      '${chain.chainName} has no REST endpoint configured, so the swap '
      'contract cannot be checked.',
      chainId: chain.chainId,
    );
  }

  final client = ref.watch(lcdFactoryProvider)(chain);
  try {
    final body = await client.getJson(
      '/cosmwasm/wasm/v1/contract/${Uri.encodeComponent(address)}',
      const LcdRequestOptions(cacheTtl: Duration(minutes: 10)),
    );
    final row = body is Map<String, Object?> ? body : null;
    final info = row?['contract_info'];
    if (info is! Map) {
      return SwapVenueStatus.unavailable(
        '${chain.chainName} answered without contract info for $address, so '
        'the swap contract could not be confirmed.',
        chainId: chain.chainId,
      );
    }
    return SwapVenueStatus.ready(
      chainId: chain.chainId,
      contractAddress: address,
    );
  } on InterchainError catch (error) {
    final reason = switch (error.code) {
      InterchainErrorCode.readsDisabled =>
        'Live reads are off, so the swap contract on ${chain.chainName} has '
            'not been checked. Turn them on in Settings to swap.',
      _ when error.httpStatus == 404 || error.httpStatus == 400 =>
        'No contract exists at $address on ${chain.chainName}. Swaps stay off '
            'rather than sending funds to an address nothing answers for.',
      _ => 'Could not reach ${chain.chainName} to check the swap contract at '
          '$address. Swaps stay off until it can be confirmed.',
    };
    return SwapVenueStatus.unavailable(reason, chainId: chain.chainId);
  }
});

/* -------------------------------------------------------------------------- *
 * Capabilities
 * -------------------------------------------------------------------------- */

/// Middleware support, probed once per chain per session.
///
/// The engine treats a null as "nobody checked" and warns; it never reads a
/// null as "unsupported". The probes are heuristics — a public node may hide a
/// module's query route — so a `false` here only ever downgrades a route to a
/// warning, and the user can still proceed.
class ChainCapabilityCache {
  ChainCapabilityCache(this._channels);

  final IbcChannelService _channels;
  final Map<String, ChainCapabilities> _known = {};

  ChainCapabilities? operator [](String chainId) => _known[chainId];

  ChainCapabilityLookup get lookup => (chainId) => _known[chainId];

  /// Probe a chain, filling the cache. Safe to call repeatedly.
  Future<void> probe(String chainId) async {
    if (_known.containsKey(chainId)) return;
    try {
      final pfm = await _channels.detectPfmSupport(chainId);
      final hooks = await _channels.detectIbcHooksSupport(chainId);
      _known[chainId] = ChainCapabilities(
        pfm: pfm.status == ModuleSupportStatus.unknown ? null : pfm.supported,
        ibcHooks:
            hooks.status == ModuleSupportStatus.unknown ? null : hooks.supported,
      );
    } on InterchainError {
      // A probe that could not run leaves the entry absent, which the planner
      // reports as "unconfirmed" rather than as unsupported.
    }
  }
}

final chainCapabilityCacheProvider = Provider<ChainCapabilityCache>(
  (ref) => ChainCapabilityCache(ref.watch(channelServiceProvider)),
);
