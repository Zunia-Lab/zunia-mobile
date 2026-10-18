/// Swap: what can be sold and bought, which way each pair reaches Osmosis,
/// the plan and price for the pair on screen, and the review that gets signed.
///
/// Matches zunia-extension 0.1.5 (`entrypoints/popup/screens/SwapScreen.tsx`)
/// in logic. Four paths (`lib/swap/swap_path.dart`): the crosschain-swaps
/// contract (`contract`), Osmosis's own pools for funds already there (`pool`,
/// `pool-deliver`), and `move-first` for funds the contract cannot swap where
/// they are. Every path charges Zunia's commission (`lib/swap/swap_fee.dart`)
/// in the same transaction, and every control is enabled only when its whole
/// path works, with the first thing that does not work named under it.
///
/// Inputs live in [SwapController]; everything shown is derived from them in
/// [buildSwapView], a pure function, so a stale answer for inputs since edited
/// is never shown as current: a plan or a price belongs to exactly one
/// [SwapView.planKey].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/interchain/xcs_route.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/swap/osmosis_assets.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_amounts.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_data.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_review.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

/// Gas the form reserves for the network fee before Max, as the extension.
const int swapReserveGasLimit = 300000;

/// The clock prices are timed with. Tests move it by hand.
final swapClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/* -------------------------------------------------------------------------- *
 * Settings
 * -------------------------------------------------------------------------- */

/// The swap's own settings, kept between launches.
@immutable
class SwapSettings {
  const SwapSettings({
    this.slippagePercent,
    this.feeSpeed = FeeSpeed.average,
    this.routeDetails = false,
  });

  /// Null until the user picks one: the release's default applies.
  final double? slippagePercent;
  final FeeSpeed feeSpeed;

  /// Show hops, channels and the contract under the form.
  final bool routeDetails;

  double slippageOr(double fallback) => slippagePercent ?? fallback;

  SwapSettings copyWith({
    double? slippagePercent,
    FeeSpeed? feeSpeed,
    bool? routeDetails,
  }) => SwapSettings(
    slippagePercent: slippagePercent ?? this.slippagePercent,
    feeSpeed: feeSpeed ?? this.feeSpeed,
    routeDetails: routeDetails ?? this.routeDetails,
  );
}

const String _kSlippage = 'zunia.swap.slippage';
const String _kFeeSpeed = 'zunia.swap.feeSpeed';
const String _kRouteDetails = 'zunia.swap.routeDetails';

class SwapSettingsController extends StateNotifier<SwapSettings> {
  SwapSettingsController({bool restore = true}) : super(const SwapSettings()) {
    if (restore) unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final store = await SharedPreferences.getInstance();
      final slippage = store.getDouble(_kSlippage);
      final speed = store.getString(_kFeeSpeed);
      final details = store.getBool(_kRouteDetails);
      if (!mounted) return;
      state = SwapSettings(
        slippagePercent: slippage,
        feeSpeed: FeeSpeed.values.firstWhere(
          (value) => value.name == speed,
          orElse: () => FeeSpeed.average,
        ),
        routeDetails: details ?? false,
      );
    } on Object {
      // Settings are a convenience: the defaults stand without storage.
    }
  }

  Future<void> update(SwapSettings next) async {
    state = next;
    try {
      final store = await SharedPreferences.getInstance();
      if (next.slippagePercent != null) {
        await store.setDouble(_kSlippage, next.slippagePercent!);
      }
      await store.setString(_kFeeSpeed, next.feeSpeed.name);
      await store.setBool(_kRouteDetails, next.routeDetails);
    } on Object {
      // Kept for this session.
    }
  }
}

final swapSettingsProvider =
    StateNotifierProvider<SwapSettingsController, SwapSettings>(
      (ref) => SwapSettingsController(),
    );

/// Whether [percent] is a tolerance the contract and the pools can take: the
/// swaprouter reads it on a 0-100 scale, and past the release's maximum it
/// stops protecting anything.
bool slippageAllowed(double percent, double max) =>
    percent.isFinite && percent > 0 && percent <= max;

/* -------------------------------------------------------------------------- *
 * Reads
 * -------------------------------------------------------------------------- */

/// This wallet's address on a chain: the enabled account's, else derived on
/// demand with the kernel (Osmosis, or a token's home chain the user has not
/// enabled). Null when the wallet is locked or the chain is unknown.
typedef SwapAddressResolver = String? Function(String chainId);

final swapAddressResolverProvider = Provider<SwapAddressResolver>((ref) {
  final accounts = ref.watch(chainAccountsProvider);
  final phrase = ref.watch(phraseProvider);
  final index = ref.watch(walletProvider.select((w) => w.active?.index ?? 0));
  final cache = <String, String?>{
    for (final account in accounts) account.chain.chainId: account.address,
  };
  return (chainId) {
    if (cache.containsKey(chainId)) return cache[chainId];
    String? address;
    if (phrase != null && ChainCatalog.isLoaded) {
      final chain = ChainCatalog.instance.find(chainId);
      if (chain != null) {
        try {
          address = WalletKernel.instance
              .deriveAddress(phrase: phrase, chain: chain, accountIndex: index)
              .address;
        } on Object {
          address = null;
        }
      }
    }
    return cache[chainId] = address;
  };
});

/// The Osmosis SQS router, from the release's endpoints. No caching: a quote
/// is worthless once it is seconds old. Gated on live reads like every read.
final swapRouterProvider = Provider<LcdClient>((ref) {
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  final config = ref.watch(swapDataProvider).valueOrNull?.config;
  return HttpLcdClient(
    chainId: config?.venueChainId ?? kSwapVenueChainId,
    endpoints: config?.routerEndpoints ?? osmosisRouterEndpoints,
    readsAllowed: () => live,
    cacheTtl: Duration.zero,
  );
});

/// Every denom each enabled chain holds, base units. A chain whose read
/// fails is left out, so its tokens are not offered rather than offered at 0.
final swapHoldingsProvider = FutureProvider<Map<String, List<HeldToken>>>((
  ref,
) async {
  final accounts = ref.watch(chainAccountsProvider);
  final factory = ref.watch(lcdFactoryProvider);
  final registry = ref.watch(interchainRegistryProvider);
  final out = <String, List<HeldToken>>{};
  await Future.wait([
    for (final account in accounts)
      () async {
        final chain = registry.get(account.chain.chainId);
        if (chain == null || lcdEndpointsFromChain(chain).isEmpty) return;
        try {
          final body = await factory(chain).getJson(
            '/cosmos/bank/v1beta1/balances/${Uri.encodeComponent(account.address)}',
            const LcdRequestOptions(
              cacheTtl: Duration(seconds: 15),
              query: {'pagination.limit': 1000},
            ),
          );
          final rows = body is Map ? body['balances'] : null;
          if (rows is! List) return;
          out[account.chain.chainId] = [
            for (final row in rows)
              if (row is Map &&
                  row['denom'] is String &&
                  row['amount'] is String)
                HeldToken(row['denom'] as String, row['amount'] as String),
          ];
        } on InterchainError {
          // Unknown is not zero: the chain's tokens are simply not offered.
        }
      }(),
  ]);
  return out;
});

/// The Osmosis side of the To list, and why it is missing when it is.
@immutable
class OsmosisAssetsRead {
  const OsmosisAssetsRead(this.assets, [this.error]);
  final List<OsmosisAsset> assets;
  final String? error;
}

final osmosisSwapAssetsProvider = FutureProvider<OsmosisAssetsRead>((
  ref,
) async {
  final data = await ref.watch(swapDataProvider.future);
  final router = ref.watch(swapRouterProvider);
  try {
    return OsmosisAssetsRead(
      await listOsmosisAssets(router: router, book: data.book),
    );
  } on InterchainError catch (error) {
    return OsmosisAssetsRead(const [], error.message);
  }
});

/// The verified contract's route table; null while there is no contract or
/// when it cannot be read, which gates nothing.
final xcsRouteTableProvider = FutureProvider<XcsRouteTable?>((ref) async {
  final venue = await ref.watch(swapVenueStatusProvider.future);
  final contract = venue.contractAddress;
  if (!venue.ready || contract == null) return null;
  final chain = ref.watch(interchainRegistryProvider).get(venue.chainId);
  if (chain == null) return null;
  return loadXcsRoutes(contract, lcd: ref.watch(lcdFactoryProvider)(chain));
});

/* -------------------------------------------------------------------------- *
 * Plans
 * -------------------------------------------------------------------------- */

/// One hop the user may override by hand.
@immutable
class SwapHopChoice {
  const SwapHopChoice({
    required this.index,
    required this.fromChainId,
    required this.toChainId,
    required this.channelId,
    required this.options,
    this.manual = false,
  });

  final int index;
  final String fromChainId;
  final String? toChainId;
  final String channelId;

  /// Channels discovered on chain for this pair.
  final List<IbcChannelOption> options;
  final bool manual;
}

/// The contract path's plan and price, for the key it answered.
@immutable
class ContractPlan {
  const ContractPlan({
    required this.key,
    required this.at,
    this.plan,
    this.receiver,
    this.links = const [],
    this.hops = const [],
    this.warnings = const [],
    this.error,
    this.blockedReason,
    this.blockedCode,
    this.venueInputDenom,
    this.venueOutputDenom,
    this.quote,
    this.quoteError,
    this.quoteCode,
    this.contract,
  });

  final String key;

  /// When the price came back.
  final DateTime at;
  final RoutePlan? plan;

  /// The ICS20 receiver (the contract), or the contract for a call.
  final String? receiver;
  final List<ChannelLink> links;
  final List<SwapHopChoice> hops;
  final List<String> warnings;

  /// The planner could not run.
  final String? error;

  /// The plan exists and must not be signed.
  final String? blockedReason;
  final String? blockedCode;
  final String? venueInputDenom;
  final String? venueOutputDenom;
  final OsmosisSwapQuote? quote;
  final String? quoteError;
  final String? quoteCode;
  final String? contract;

  ContractPlan withPrice(VenueQuote price, DateTime at) => ContractPlan(
    key: key,
    at: at,
    plan: plan,
    receiver: receiver,
    links: links,
    hops: hops,
    warnings: warnings,
    error: error,
    blockedReason: blockedReason,
    blockedCode: blockedCode,
    venueInputDenom: venueInputDenom,
    venueOutputDenom: venueOutputDenom,
    quote: price.quote,
    quoteError: price.error,
    quoteCode: price.code,
    contract: contract,
  );
}

/// A pool path's plan and price, for the key it answered.
@immutable
class PoolPlan {
  const PoolPlan({
    required this.key,
    required this.at,
    required this.venueInputDenom,
    required this.venueOutputDenom,
    required this.amountBaseUnits,
    required this.quote,
    this.delivery,
    this.deliveryError,
  });

  final String key;
  final DateTime at;
  final String venueInputDenom;
  final String venueOutputDenom;

  /// Base units priced: what the swap sells.
  final String amountBaseUnits;
  final PoolQuote quote;

  /// The checked transfer leg (`pool-deliver`).
  final PoolDelivery? delivery;
  final String? deliveryError;

  PoolPlan withQuote(PoolQuote next, DateTime at) => PoolPlan(
    key: key,
    at: at,
    venueInputDenom: venueInputDenom,
    venueOutputDenom: venueOutputDenom,
    amountBaseUnits: amountBaseUnits,
    quote: next,
    delivery: delivery,
    deliveryError: deliveryError,
  );
}

/// A venue price, or why there is none.
@immutable
class VenueQuote {
  const VenueQuote({this.quote, this.error, this.code});
  final OsmosisSwapQuote? quote;
  final String? error;
  final String? code;
}

const String _noContractRoute =
    'The Osmosis swap contract has no route for this pair. Signing would send the tokens, the packet would be rejected, and the funds would come back. The swap stays unsigned.';
const String _routeUnreadable =
    'Zunia could not confirm the Osmosis swap contract will accept this pair, so the swap stays unsigned.';
const String _routeUnpriced =
    "The pools on the Osmosis swap contract's route for this pair could not be priced, so the swap stays unsigned.";

/// Why a contract swap has no price, with the tickers on screen when the
/// reason is a known one; the planner's own sentence otherwise.
String? quoteBlockText(
  String? code,
  String? reason,
  SwapAsset? from,
  SwapAsset? to,
) {
  if (code == null || from == null || to == null) return reason;
  final sold = from.ticker;
  final bought = to.ticker;
  return switch (code) {
    'no-contract-route' =>
      '${noRouteReason(sold, bought)} The swap stays unsigned.',
    'route-unreadable' =>
      'Zunia could not confirm that the Osmosis swap contract takes $sold to $bought, so the swap stays unsigned.',
    'route-unpriced' =>
      "The pools on the Osmosis swap contract's route from $sold to $bought could not be priced, so the swap stays unsigned.",
    'same-token' =>
      'Both sides are $bought on Osmosis, so there is nothing to swap. Use Send to move it.',
    'venue-denom-mismatch-in' =>
      'Zunia would trade a different ${from.identity.family} variant than the ${from.ticker} you picked, so the swap stays unsigned.',
    'venue-denom-mismatch-out' =>
      'Zunia would trade a different ${to.identity.family} variant than the ${to.ticker} you picked, so the swap stays unsigned.',
    _ => reason,
  };
}

/// Why a pool swap has no price, in the picker's words for the same pair.
String? poolQuoteText(
  PoolQuoteBlockedCode? code,
  String? reason,
  SwapAsset? from,
  SwapAsset? to,
) {
  if (code == null || from == null || to == null) return reason;
  return switch (code) {
    PoolQuoteBlockedCode.noPoolRoute =>
      'Osmosis has no pool route from ${from.ticker} to ${to.ticker} at this amount, so there is nothing to sign.',
    PoolQuoteBlockedCode.sameToken =>
      'Both sides are ${to.ticker} on Osmosis, so there is nothing to swap. Use Send to move it.',
    _ => reason,
  };
}

/* -------------------------------------------------------------------------- *
 * The form
 * -------------------------------------------------------------------------- */

/// The swap a user set out to make when its tokens first had to move to
/// Osmosis (`move-first`): Swap opens on it again once they arrive.
@immutable
class SwapIntent {
  const SwapIntent(this.fromKey, this.toKey);
  final String fromKey;
  final String toKey;
}

/// Long enough for any transfer to Osmosis to arrive; older, the user has
/// moved on.
const Duration swapIntentTtl = Duration(hours: 1);
const String _kIntent = 'zunia.swap.intent';

Future<void> rememberSwapIntent(SwapIntent intent, {DateTime? now}) async {
  try {
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kIntent,
      jsonEncode({
        'fromKey': intent.fromKey,
        'toKey': intent.toKey,
        'at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      }),
    );
  } on Object {
    // Without storage Swap just opens as usual.
  }
}

/// The pair, once: reading it forgets it. Null when there is none, or it is
/// over an hour old.
Future<SwapIntent?> takeSwapIntent({DateTime? now}) async {
  try {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kIntent);
    await store.remove(_kIntent);
    if (raw == null) return null;
    final row = jsonDecode(raw);
    if (row is! Map) return null;
    final from = row['fromKey'];
    final to = row['toKey'];
    final at = row['at'];
    if (from is! String || to is! String || at is! int) return null;
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch - at;
    if (age < 0 || age > swapIntentTtl.inMilliseconds) return null;
    return SwapIntent(from, to);
  } on Object {
    return null;
  }
}

/// What the user picked and typed, and the answers for those inputs.
@immutable
class SwapFormState {
  const SwapFormState({
    this.fromKey,
    this.toKey,
    this.amountText = '',
    this.amountScale = '',
    this.manual = const [],
    this.retryToken = 0,
    this.contract,
    this.pool,
    this.refreshingKey,
  });

  /// Null until the user picks.
  final String? fromKey;
  final String? toKey;

  /// The typed text, and the token and exponent it was typed for: text typed
  /// for one scale is never read with another.
  final String amountText;
  final String amountScale;

  /// Channels the user typed, by hop.
  final List<RouteHopOverride> manual;

  /// Bumped by the retry controls: the same inputs, asked again.
  final int retryToken;
  final ContractPlan? contract;
  final PoolPlan? pool;

  /// The key whose price is being fetched again.
  final String? refreshingKey;

  SwapFormState copyWith({
    String? fromKey,
    String? toKey,
    String? amountText,
    String? amountScale,
    List<RouteHopOverride>? manual,
    int? retryToken,
    ContractPlan? contract,
    PoolPlan? pool,
    String? refreshingKey,
    bool clearRefreshing = false,
  }) => SwapFormState(
    fromKey: fromKey ?? this.fromKey,
    toKey: toKey ?? this.toKey,
    amountText: amountText ?? this.amountText,
    amountScale: amountScale ?? this.amountScale,
    manual: manual ?? this.manual,
    retryToken: retryToken ?? this.retryToken,
    contract: contract ?? this.contract,
    pool: pool ?? this.pool,
    refreshingKey: clearRefreshing ? null : refreshingKey ?? this.refreshingKey,
  );
}

/// What a typed amount is read against: the token, and its exponent.
String scaleOf(SwapAsset asset) =>
    '${asset.key}|${asset.decimalsKnown ? asset.decimals : '?'}';

/* -------------------------------------------------------------------------- *
 * The view
 * -------------------------------------------------------------------------- */

/// Everything the swap form shows, derived from the inputs.
@immutable
class SwapView {
  const SwapView({
    required this.data,
    required this.liveReads,
    required this.loading,
    required this.sources,
    required this.destinations,
    required this.from,
    required this.to,
    required this.path,
    required this.pathPending,
    required this.amountText,
    required this.amountUnits,
    required this.fee,
    required this.available,
    required this.spendable,
    required this.overBalance,
    required this.slippage,
    required this.slippageOk,
    required this.signer,
    required this.destAddress,
    required this.recoveryAddress,
    required this.venue,
    required this.venueLoading,
    required this.routeTable,
    required this.planKey,
    required this.contract,
    required this.pool,
    required this.planning,
    required this.refreshing,
    required this.quote,
    required this.quoteError,
    required this.quotedAt,
    required this.blockedReason,
    required this.ready,
    required this.moveBlocked,
    required this.osmosisError,
    required this.holdingsLoaded,
    required this.manual,
  });

  final SwapData? data;
  final bool liveReads;

  /// The bundled data or the balances are still loading.
  final bool loading;
  final List<SwapAsset> sources;
  final List<SwapAsset> destinations;
  final SwapAsset? from;
  final SwapAsset? to;
  final SwapPath? path;

  /// Funds on Osmosis bound elsewhere wait for the route table, so the path
  /// does not switch under a quote already shown.
  final bool pathPending;
  final String amountText;

  /// What the user spends in all, the Zunia fee included.
  final BigInt? amountUnits;

  /// The Zunia fee on [amountUnits]; null without an amount.
  final SwapFee? fee;
  final BigInt? available;

  /// The balance less the network fee reserve, when the fee is paid in the
  /// token sold.
  final BigInt? spendable;
  final bool overBalance;
  final double slippage;
  final bool slippageOk;

  /// This wallet's address on the From's chain.
  final String? signer;

  /// This wallet's address on the To's chain.
  final String? destAddress;

  /// This wallet's address on Osmosis: `local_recovery_addr`.
  final String? recoveryAddress;
  final SwapVenueStatus? venue;
  final bool venueLoading;
  final XcsRouteTable? routeTable;

  /// Every input a plan depends on; `''` when nothing can be planned.
  final String planKey;
  final ContractPlan? contract;
  final PoolPlan? pool;
  final bool planning;
  final bool refreshing;
  final OsmosisSwapQuote? quote;
  final String? quoteError;
  final DateTime? quotedAt;

  /// The first thing that does not work, under the button; null when it can
  /// be pressed (or while something is still loading).
  final String? blockedReason;
  final bool ready;

  /// Why the move-first step cannot start.
  final String? moveBlocked;
  final String? osmosisError;
  final bool holdingsLoaded;
  final List<RouteHopOverride> manual;

  String get venueChainId => data?.venueChainId ?? kSwapVenueChainId;

  /// The pool plan's checked delivery, for `pool-deliver`.
  PoolDelivery? get delivery =>
      path == SwapPath.poolDeliver ? pool?.delivery : null;

  /// What the form would sign right now, for a review to be checked against.
  LiveSwap get live => LiveSwap(
    from: from,
    to: to,
    path: path,
    amountUnits: amountUnits,
    fee: fee,
    planKey: planKey,
    planning: planning,
    planFingerprint: contract?.plan == null
        ? null
        : routePlanFingerprint(contract!.plan!, contract!.receiver ?? ''),
    delivery: delivery,
    blockedReason: blockedReason,
  );
}

/// Inputs to [buildSwapView] that come from providers, so a test can build a
/// view without any.
@immutable
class SwapEnv {
  const SwapEnv({
    required this.data,
    required this.chains,
    required this.holdings,
    required this.holdingsLoaded,
    required this.osmosis,
    required this.routes,
    required this.routesLoading,
    required this.venue,
    required this.venueLoading,
    required this.liveReads,
    required this.resolve,
  });

  final SwapData? data;
  final List<SwapChain> chains;
  final Map<String, List<HeldToken>> holdings;
  final bool holdingsLoaded;
  final OsmosisAssetsRead osmosis;
  final XcsRouteTable? routes;
  final bool routesLoading;
  final SwapVenueStatus? venue;
  final bool venueLoading;
  final bool liveReads;
  final SwapAddressResolver resolve;
}

String _manualKey(List<RouteHopOverride> manual) => [
  for (final m in manual)
    '${m.hopIndex}:${m.fromChainId}>${m.toChainId}:${m.channelId}',
].join('|');

/// The planner request as one string: every input a plan depends on.
String swapPlanKey({
  required SwapAsset from,
  required SwapAsset to,
  required BigInt amountUnits,
  required SwapFee? fee,
  required double slippage,
  required List<RouteHopOverride> manual,
  required String venueKey,
  required int retryToken,
  required String venueChainId,
}) => [
  from.chainId,
  from.denom,
  to.chainId,
  to.denom,
  amountUnits.toString(),
  fee != null && fee.fee > BigInt.zero
      ? '${fee.fee}>${fee.recipient ?? ''}'
      : '',
  slippage,
  _manualKey(manual),
  venueKey,
  from.chainId == venueChainId ? from.denom : from.identity.osmosisDenom ?? '',
  to.chainId == venueChainId ? to.denom : to.identity.osmosisDenom ?? '',
  retryToken,
].join('~');

/// Derive what the form shows from its inputs. Pure.
SwapView buildSwapView({
  required SwapEnv env,
  required SwapFormState form,
  required SwapSettings settings,
}) {
  final data = env.data;
  final venueChainId = data?.venueChainId ?? kSwapVenueChainId;
  final config = data?.config;
  final slippage = settings.slippageOr(config?.defaultSlippagePercent ?? 1);
  final slippageOk = slippageAllowed(
    slippage,
    config?.maxSlippagePercent ?? 50,
  );
  final osmosis = env.osmosis.assets;

  final sources = data == null
      ? const <SwapAsset>[]
      : sellOptions(env.chains, env.holdings, data.book, osmosis: osmosis);
  SwapAsset? from;
  if (form.fromKey != null) {
    for (final asset in sources) {
      if (asset.key == form.fromKey) from = asset;
    }
  }
  from ??= sources.isEmpty ? null : sources.first;
  final destinations = data == null
      ? const <SwapAsset>[]
      : buyOptions(
          env.chains,
          env.holdings,
          data.book,
          catalog: data.catalog,
          from: from,
          osmosis: osmosis,
          routes: env.routes,
        );
  final to = pickTo(destinations, form.toKey);

  final path = from != null && to != null
      ? swapPathFor(
          from.chainId,
          to.chainId,
          to.executable,
          venueChainId: venueChainId,
        )
      : null;
  final pathPending =
      from != null &&
      to != null &&
      from.chainId == venueChainId &&
      to.chainId != venueChainId &&
      (env.venueLoading || env.routesLoading);

  // The typed text belongs to the token and the exponent it was typed for.
  final amountText = from != null && form.amountScale == scaleOf(from)
      ? form.amountText
      : '';
  final amountUnits = from == null
      ? null
      : swapUnitsOf(amountText, from.identity);
  final fee =
      from != null &&
          data != null &&
          amountUnits != null &&
          amountUnits > BigInt.zero
      ? data.fees.feeFor(from.chainId, amountUnits)
      : null;

  final available = from?.amount;
  var reserve = BigInt.zero;
  if (from != null && ChainCatalog.isLoaded) {
    final entry = ChainCatalog.instance.find(from.chainId);
    if (entry != null) {
      final gas = (swapReserveGasLimit * defaultGasAdjustment).ceil();
      final reserveFee = TxEngine.feeFor(entry, gas, settings.feeSpeed);
      final coin = reserveFee.amount.isEmpty ? null : reserveFee.amount.first;
      if (coin != null && coin.denom == from.denom) {
        reserve = BigInt.parse(coin.amount);
      }
    }
  }
  final spendable = available == null
      ? null
      : available <= reserve
      ? BigInt.zero
      : available - reserve;
  final overBalance =
      amountUnits != null && spendable != null && amountUnits > spendable;

  final signer = from == null ? null : env.resolve(from.chainId);
  final destAddress = to == null ? null : env.resolve(to.chainId);
  final recoveryAddress = env.resolve(venueChainId);
  final venue = env.venue;
  final venueReady = venue?.ready ?? false;

  final sameAsset =
      from != null &&
      to != null &&
      from.chainId == to.chainId &&
      from.denom == to.denom;
  final canPlan =
      env.liveReads &&
      data != null &&
      from != null &&
      to != null &&
      signer != null &&
      destAddress != null &&
      to.disabledReason == null &&
      amountUnits != null &&
      amountUnits > BigInt.zero &&
      fee != null &&
      !overBalance &&
      slippageOk &&
      !sameAsset &&
      path != null &&
      !pathPending &&
      (path != SwapPath.contract || (venueReady && recoveryAddress != null));
  final planKey = canPlan
      ? swapPlanKey(
          from: from,
          to: to,
          amountUnits: fee.net,
          fee: fee,
          slippage: slippage,
          manual: form.manual,
          venueKey: path == SwapPath.contract
              ? venue?.contractAddress ?? ''
              : 'osmosis-pools:${path.name}',
          retryToken: form.retryToken,
          venueChainId: venueChainId,
        )
      : '';

  final contract =
      path == SwapPath.contract &&
          form.contract?.key == planKey &&
          planKey.isNotEmpty
      ? form.contract
      : null;
  final pool =
      path != SwapPath.contract &&
          form.pool?.key == planKey &&
          planKey.isNotEmpty
      ? form.pool
      : null;
  final planning =
      planKey.isNotEmpty &&
      (path == SwapPath.contract ? contract == null : pool == null);
  final refreshing = planKey.isNotEmpty && form.refreshingKey == planKey;

  final OsmosisSwapQuote? quote;
  final String? quoteError;
  final DateTime? quotedAt;
  if (path == SwapPath.contract) {
    quote = contract?.quote;
    quoteError = quoteBlockText(
      contract?.quoteCode,
      contract?.quoteError,
      from,
      to,
    );
    quotedAt = contract?.quote == null ? null : contract?.at;
  } else {
    quote = pool?.quote.quote;
    quoteError = poolQuoteText(pool?.quote.code, pool?.quote.error, from, to);
    quotedAt = pool?.quote.quote == null ? null : pool?.at;
  }

  String? blocked() {
    if (!env.liveReads) {
      return 'Swapping reads channels, denom traces and pool prices from public endpoints. Turn on live reads in Settings.';
    }
    if (data == null) return null;
    if (sources.isEmpty) {
      return env.holdingsLoaded
          ? 'This wallet holds no non-zero balance to swap.'
          : null;
    }
    if (from == null) {
      return 'Pick what you are swapping and what you want back.';
    }
    if (to == null) {
      if (from.testnet) return testnetReason;
      return destinations.isNotEmpty
          ? 'Nothing can be bought with ${from.ticker} here. Search the To list to see each token and why.'
          : 'Pick what you want back.';
    }
    if (to.disabledReason != null) return to.disabledReason;
    if (path == SwapPath.contract || pathPending) {
      if (env.venueLoading || pathPending) return null;
      if (venue?.reason != null) return venue!.reason;
    }
    if (signer == null) {
      return 'Zunia has no address on ${from.chainName}, so it cannot sign there.';
    }
    if (destAddress == null) {
      return 'Zunia has no address on ${to.chainName}, so it has nowhere to deliver.';
    }
    if (sameAsset) return 'Both sides are the same asset on the same chain.';
    if (amountText.isEmpty) {
      return from.decimalsKnown
          ? 'Enter an amount to swap.'
          : "Use Max to set the amount: this token's decimals are unknown.";
    }
    if (amountUnits == null) {
      return 'That amount is not a number this chain can hold.';
    }
    if (amountUnits <= BigInt.zero) return 'Enter an amount above zero.';
    if (overBalance) {
      return 'More than the ${from.ticker} left after the network fee.';
    }
    if (!slippageOk) {
      return 'Slippage must be between 0 and ${_percentText(config?.maxSlippagePercent ?? 50)}%. Above that the tolerance stops protecting anything.';
    }
    if (path != SwapPath.contract) {
      if (planning || pool == null) return null;
      if (quoteError != null) return quoteError;
      if (quote == null) return 'Waiting for a price from the Osmosis router.';
      if (path == SwapPath.poolDeliver) {
        if (pool.deliveryError != null) return pool.deliveryError;
        if (pool.delivery == null) {
          return 'Zunia is planning the transfer to ${to.chainName}.';
        }
      }
      return null;
    }
    if (recoveryAddress == null) {
      return 'Zunia could not derive your address on $venueChainId, so it cannot set a recovery address. Without one, funds stranded by a failed delivery could not be reclaimed, so the swap is refused.';
    }
    if (planning || contract == null) return null;
    if (contract.error != null) return contract.error;
    if (contract.plan == null) {
      return contract.warnings.isNotEmpty
          ? contract.warnings.first
          : 'No route exists from here to there for this asset.';
    }
    if (contract.blockedReason != null) {
      final worded = quoteBlockText(
        contract.blockedCode,
        contract.blockedReason,
        from,
        to,
      );
      return worded ?? contract.blockedReason;
    }
    if (quoteError != null) return quoteError;
    if (quote == null) return 'Waiting for a price from the Osmosis router.';
    return null;
  }

  final blockedReason = blocked();
  final ready =
      blockedReason == null &&
      quote != null &&
      from != null &&
      signer != null &&
      !planning &&
      (path == SwapPath.contract
          ? contract?.plan != null
          : isPoolPath(path) &&
                (pool?.quote.ready ?? false) &&
                (path == SwapPath.pool || pool?.delivery != null));

  final venueEnabled = env.chains.any((chain) => chain.chainId == venueChainId);
  final moveBlocked = path != SwapPath.moveFirst
      ? null
      : !venueEnabled
      ? 'Turn on Osmosis in Networks: the tokens move to your Osmosis address first.'
      : pool?.quote.code == PoolQuoteBlockedCode.noPoolRoute
      ? quoteError
      : null;

  return SwapView(
    data: data,
    liveReads: env.liveReads,
    loading: data == null || (!env.holdingsLoaded && sources.isEmpty),
    sources: sources,
    destinations: destinations,
    from: from,
    to: to,
    path: path,
    pathPending: pathPending,
    amountText: amountText,
    amountUnits: amountUnits,
    fee: fee,
    available: available,
    spendable: spendable,
    overBalance: overBalance,
    slippage: slippage,
    slippageOk: slippageOk,
    signer: signer,
    destAddress: destAddress,
    recoveryAddress: recoveryAddress,
    venue: venue,
    venueLoading: env.venueLoading,
    routeTable: env.routes,
    planKey: planKey,
    contract: contract,
    pool: pool,
    planning: planning,
    refreshing: refreshing,
    quote: quote,
    quoteError: quoteError,
    quotedAt: quotedAt,
    blockedReason: blockedReason,
    ready: ready,
    moveBlocked: moveBlocked,
    osmosisError: env.osmosis.error,
    holdingsLoaded: env.holdingsLoaded,
    manual: form.manual,
  );
}

String _percentText(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

final swapViewProvider = Provider<SwapView>((ref) {
  final data = ref.watch(swapDataProvider).valueOrNull;
  final accounts = ref.watch(chainAccountsProvider);
  final holdings = ref.watch(swapHoldingsProvider);
  final osmosis = ref.watch(osmosisSwapAssetsProvider);
  final routes = ref.watch(xcsRouteTableProvider);
  final venue = ref.watch(swapVenueStatusProvider);
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  return buildSwapView(
    env: SwapEnv(
      data: data,
      chains: [
        for (final account in accounts)
          SwapChain(account.chain, account.address),
      ],
      holdings: holdings.valueOrNull ?? const {},
      holdingsLoaded: holdings.hasValue || holdings.hasError,
      osmosis: osmosis.valueOrNull ?? const OsmosisAssetsRead([]),
      routes: routes.valueOrNull,
      routesLoading: routes.isLoading,
      venue: venue.valueOrNull,
      venueLoading: venue.isLoading,
      liveReads: live,
      resolve: ref.watch(swapAddressResolverProvider),
    ),
    form: ref.watch(swapControllerProvider),
    settings: ref.watch(swapSettingsProvider),
  );
});

/* -------------------------------------------------------------------------- *
 * The controller
 * -------------------------------------------------------------------------- */

/// What the review screen opens on: the frozen review and the messages built
/// from it, with the memo the kernel will sign.
@immutable
class PreparedSwap {
  const PreparedSwap({
    required this.review,
    required this.msgs,
    required this.memo,
    required this.chain,
  });

  final SwapReview review;
  final List<TxMsg> msgs;
  final String memo;
  final ChainEntry chain;
}

class SwapException implements Exception {
  const SwapException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Holds the form's inputs and fetches plans and prices for them.
class SwapController extends StateNotifier<SwapFormState> {
  SwapController(this._ref, {bool restoreIntent = true})
    : super(const SwapFormState()) {
    if (restoreIntent) unawaited(_restoreIntent());
  }

  final Ref _ref;
  int _reviewCount = 0;

  DateTime _now() => _ref.read(swapClockProvider)();

  Future<void> _restoreIntent() async {
    final intent = await takeSwapIntent();
    if (intent == null || !mounted) return;
    state = SwapFormState(
      fromKey: state.fromKey ?? intent.fromKey,
      toKey: state.toKey ?? intent.toKey,
      amountText: state.amountText,
      amountScale: state.amountScale,
      manual: state.manual,
      retryToken: state.retryToken,
      contract: state.contract,
      pool: state.pool,
    );
  }

  void pickFrom(String key) {
    state = SwapFormState(
      fromKey: key,
      toKey: state.toKey,
      retryToken: state.retryToken,
      contract: state.contract,
      pool: state.pool,
    );
  }

  void pickTo(String key) {
    state = SwapFormState(
      fromKey: state.fromKey,
      toKey: key,
      amountText: state.amountText,
      amountScale: state.amountScale,
      retryToken: state.retryToken,
      contract: state.contract,
      pool: state.pool,
    );
  }

  void setAmount(String text, SwapAsset from) {
    state = state.copyWith(amountText: text, amountScale: scaleOf(from));
  }

  /// Only a held To can become the From: the From list is what the wallet
  /// holds. The typed number carries over only when it can mean the same
  /// thing: the new From must take typed amounts.
  bool flip(SwapView view) {
    final from = view.from;
    final to = view.to;
    if (from == null || to == null || !to.held || from.key == to.key) {
      return false;
    }
    state = SwapFormState(
      fromKey: to.key,
      toKey: from.key,
      amountText: to.decimalsKnown ? view.amountText : '',
      amountScale: scaleOf(to),
      retryToken: state.retryToken,
      contract: state.contract,
      pool: state.pool,
    );
    return true;
  }

  /// Exact digits for any size: the field converts back with the same
  /// exponent, so Max signs the balance less the fee reserve and not a
  /// rounding.
  void applyMax(SwapView view) {
    final from = view.from;
    final spendable = view.spendable;
    if (from == null || spendable == null) return;
    setAmount(swapFieldText(spendable, from.identity), from);
  }

  /// Record a hand-typed channel for a hop. An empty value clears it.
  void setOverride(
    int hopIndex,
    String channelId, {
    String? fromChainId,
    String? toChainId,
  }) {
    final normalized = normalizeChannelId(channelId);
    final rest = [
      for (final m in state.manual)
        if (m.hopIndex != hopIndex) m,
    ];
    state = state.copyWith(
      manual: normalized.isEmpty
          ? rest
          : [
              ...rest,
              RouteHopOverride(
                hopIndex: hopIndex,
                channelId: normalized,
                fromChainId: fromChainId,
                toChainId: toChainId,
              ),
            ],
    );
  }

  String? overrideFor(int hopIndex) {
    for (final m in state.manual) {
      if (m.hopIndex == hopIndex) return m.channelId;
    }
    return null;
  }

  void retry() => state = state.copyWith(retryToken: state.retryToken + 1);

  /// Forget the amount after a swap went through.
  void clearAmount() => state = state.copyWith(amountText: '');

  /* ---------------------------------------------------------------- *
   * Planning
   * ---------------------------------------------------------------- */

  /// Plan and price [view]'s inputs. The answer lands only if it is still for
  /// the key the form shows.
  Future<void> plan(SwapView view) async {
    final key = view.planKey;
    if (key.isEmpty) return;
    if (view.path == SwapPath.contract) {
      final result = await _guard(key, () => _planContract(view, key));
      if (mounted) state = state.copyWith(contract: result);
    } else {
      final result = await _guardPool(key, () => _planPool(view, key));
      if (mounted) state = state.copyWith(pool: result);
    }
  }

  Future<ContractPlan> _guard(
    String key,
    Future<ContractPlan> Function() run,
  ) async {
    try {
      return await run();
    } on InterchainError catch (error) {
      return ContractPlan(key: key, at: _now(), error: _describe(error));
    } on Object catch (error) {
      return ContractPlan(key: key, at: _now(), error: '$error');
    }
  }

  Future<PoolPlan> _guardPool(
    String key,
    Future<PoolPlan> Function() run,
  ) async {
    try {
      return await run();
    } on Object catch (error) {
      return PoolPlan(
        key: key,
        at: _now(),
        venueInputDenom: '',
        venueOutputDenom: '',
        amountBaseUnits: '0',
        quote: PoolQuote(
          error: error is InterchainError ? _describe(error) : '$error',
        ),
      );
    }
  }

  String _describe(InterchainError error) => switch (error.code) {
    InterchainErrorCode.readsDisabled =>
      'Live reads are off, so nothing can be priced. Turn them on in Settings.',
    InterchainErrorCode.lcdUnreachable =>
      'Could not reach the network: ${error.message}',
    _ => error.message,
  };

  LcdClient? _venueLcd(String venueChainId) {
    final chain = _ref.read(interchainRegistryProvider).get(venueChainId);
    if (chain == null || lcdEndpointsFromChain(chain).isEmpty) return null;
    return _ref.read(lcdFactoryProvider)(chain);
  }

  /// Price a contract pair along the route its swaprouter will execute, or
  /// refuse: SQS prices pairs the contract cannot execute.
  Future<VenueQuote> quoteOnVenue(
    VenueQuoteInput input,
    String venueChainId,
  ) async {
    final lcd = _venueLcd(venueChainId);
    if (lcd == null) {
      return VenueQuote(
        error:
            'No REST endpoint for $venueChainId, so the swap cannot be priced.',
      );
    }
    XcsRouteRead read;
    try {
      read = await readXcsExecutableRoute(
        lcd,
        input.contract,
        input.venueInputDenom,
        input.venueOutputDenom,
      );
    } on InterchainError catch (error) {
      return VenueQuote(error: _describe(error));
    }
    switch (read) {
      case XcsRouteMissing():
        return const VenueQuote(
          error: _noContractRoute,
          code: 'no-contract-route',
        );
      case XcsRouteUnreadable():
        return const VenueQuote(
          error: _routeUnreadable,
          code: 'route-unreadable',
        );
      case XcsRouteReady(:final route):
        try {
          final quote = await quoteOsmosisSwap(
            OsmosisSwapQuoteParams(
              tokenInDenom: input.venueInputDenom,
              tokenInAmount: input.amountBaseUnits,
              tokenOutDenom: input.venueOutputDenom,
              slippagePercent: input.slippagePercent,
              router: _ref.read(swapRouterProvider),
              // The contract executes these pools and no others.
              route: route,
            ),
            lcd,
          );
          return VenueQuote(quote: quote);
        } on InterchainError catch (error) {
          return error.code == InterchainErrorCode.noRoute
              ? const VenueQuote(error: _routeUnpriced, code: 'route-unpriced')
              : VenueQuote(error: _describe(error));
        }
    }
  }

  Future<ContractPlan> _planContract(SwapView view, String key) async {
    final data = view.data!;
    final from = view.from!;
    final to = view.to!;
    final venue = view.venue!.venue!;
    final venueChainId = data.venueChainId;
    final net = view.fee!.net;
    final destAddress = view.destAddress!;
    final recovery = view.recoveryAddress!;
    final registry = _ref.read(interchainRegistryProvider);
    String name(String chainId) => registry.get(chainId)?.chainName ?? chainId;

    final venueOut = to.chainId == venueChainId
        ? to.denom
        : to.identity.osmosisDenom;
    final expectedIn = from.chainId == venueChainId
        ? from.denom
        : from.identity.osmosisDenom;
    if (venueOut == null) {
      return ContractPlan(
        key: key,
        at: _now(),
        error:
            'Zunia could not work out what ${to.ticker} is called on ${name(venueChainId)}, so it will not put a guessed denom in the swap.',
      );
    }

    RoutePlan plan;
    String receiver;
    String? venueIn;
    var links = const <ChannelLink>[];
    var hops = const <SwapHopChoice>[];
    var warnings = const <String>[];

    if (from.chainId == venueChainId) {
      // Venue-origin: the funds are on Osmosis, so the user calls the contract
      // there directly and it sends the output on.
      final out = data.book.canonicalChannel(venueChainId, to.chainId);
      if (out == null) {
        return ContractPlan(
          key: key,
          at: _now(),
          error:
              'No known channel from ${name(venueChainId)} to ${to.chainName}, so the swap contract has no way to deliver there.',
        );
      }
      final memo = jsonEncode(
        buildXcsSwapMemoJson(
          contract: venue.contractAddress,
          outputDenom: venueOut,
          receiver: destAddress,
          slippage: slippageToTwapParams(
            view.slippage,
            windowSeconds: kTwapWindowSeconds,
          ),
          onFailedDelivery: XcsLocalRecovery(recovery),
        ),
      );
      plan = RoutePlan(
        sourceChainId: venueChainId,
        destChainId: to.chainId,
        inputDenom: from.denom,
        outputDenom: to.denom,
        hops: [
          RouteHop(
            chainId: venueChainId,
            channelId: '',
            port: '',
            counterpartyChainId: venueChainId,
            kind: RouteHopKind.swap,
          ),
          RouteHop(
            chainId: venueChainId,
            channelId: out.channelId,
            port: transferPort,
            counterpartyChainId: to.chainId,
            kind: RouteHopKind.forward,
          ),
        ],
        memo: memo,
        warnings: const [],
        estimatedDurationSeconds: 60,
        requiresPfm: false,
        requiresIbcHooks: false,
      );
      receiver = venue.contractAddress;
      venueIn = from.denom;
    } else {
      final planned = await _planInbound(view, key, venueOut);
      if (planned.result != null) return planned.result!;
      plan = planned.plan!;
      receiver = planned.receiver!;
      venueIn = planned.venueIn;
      links = planned.links;
      hops = planned.hops;
      warnings = planned.warnings;
      if (planned.blocked != null) {
        return ContractPlan(
          key: key,
          at: _now(),
          plan: plan,
          receiver: receiver,
          links: links,
          hops: hops,
          warnings: warnings,
          blockedReason: planned.blocked,
          contract: venue.contractAddress,
        );
      }
    }

    if (venueIn == null) {
      return ContractPlan(
        key: key,
        at: _now(),
        plan: plan,
        receiver: receiver,
        links: links,
        hops: hops,
        warnings: warnings,
        contract: venue.contractAddress,
        quoteError:
            'Zunia could not work out what this token is called on ${name(venueChainId)}, so it will not price the swap.',
      );
    }
    // The tokens on screen name both sides on the venue. A route that names
    // either side differently would trade something else, so it stops here.
    if (expectedIn != null && expectedIn != venueIn) {
      return ContractPlan(
        key: key,
        at: _now(),
        plan: plan,
        receiver: receiver,
        links: links,
        hops: hops,
        warnings: warnings,
        contract: venue.contractAddress,
        blockedReason:
            'Zunia would trade a different variant of the token than the one you picked: on ${name(venueChainId)} this route sells $venueIn, not $expectedIn. The swap stays unsigned.',
        blockedCode: 'venue-denom-mismatch-in',
      );
    }
    if (venueIn == venueOut) {
      return ContractPlan(
        key: key,
        at: _now(),
        plan: plan,
        receiver: receiver,
        links: links,
        hops: hops,
        warnings: warnings,
        contract: venue.contractAddress,
        venueInputDenom: venueIn,
        venueOutputDenom: venueOut,
        quoteError:
            'Both sides of this swap are the same token on the venue chain. Use a plain transfer instead.',
        quoteCode: 'same-token',
      );
    }
    final price = await quoteOnVenue(
      VenueQuoteInput(
        contract: venue.contractAddress,
        venueInputDenom: venueIn,
        venueOutputDenom: venueOut,
        amountBaseUnits: net.toString(),
        slippagePercent: view.slippage,
      ),
      venueChainId,
    );
    return ContractPlan(
      key: key,
      at: _now(),
      plan: plan,
      receiver: receiver,
      links: links,
      hops: hops,
      warnings: warnings,
      contract: venue.contractAddress,
      venueInputDenom: venueIn,
      venueOutputDenom: venueOut,
      quote: price.quote,
      quoteError: price.error,
      quoteCode: price.code,
    );
  }

  /// Route an inbound swap: discover and verify channels, then plan with the
  /// engine, then plan again with a receiver on every chain the route lands
  /// on, so no packet is addressed to the `pfm` placeholder.
  Future<
    ({
      ContractPlan? result,
      RoutePlan? plan,
      String? receiver,
      String? venueIn,
      List<ChannelLink> links,
      List<SwapHopChoice> hops,
      List<String> warnings,
      String? blocked,
    })
  >
  _planInbound(SwapView view, String key, String venueOut) async {
    final data = view.data!;
    final from = view.from!;
    final to = view.to!;
    final venue = view.venue!.venue!;
    final venueChainId = data.venueChainId;
    final registry = _ref.read(interchainRegistryProvider);
    final channels = _ref.read(channelServiceProvider);
    final routes = _ref.read(routeRegistryProvider);
    final capabilities = _ref.read(chainCapabilityCacheProvider);
    final resolve = _ref.read(swapAddressResolverProvider);

    final discovered = <ChannelRoute>[];
    Future<List<IbcChannelOption>> discover(String a, String b) async {
      if (a == b) return const [];
      try {
        final options = await channels.findIbcChannels(a, b);
        for (final option in options) {
          discovered.add(
            ChannelRoute(
              sourceChainId: a,
              destChainId: b,
              channelId: option.channelId,
              counterpartyChannelId: option.counterpartyChannelId,
              verifiedAt: _now().millisecondsSinceEpoch,
              source: ChannelRouteSource.discovered,
            ),
          );
        }
        return options;
      } on InterchainError {
        // Discovery fails on chains with slow or partial LCDs; a seed row or a
        // channel the user types still feeds the same graph.
        return const [];
      }
    }

    final inbound = await discover(from.chainId, venueChainId);
    final outbound = await discover(venueChainId, to.chainId);
    await routes.remember(discovered);
    await capabilities.probe(venueChainId);
    await capabilities.probe(from.chainId);

    final deps = RoutePlannerDeps(
      registry: registry,
      channels: createChannelDirectory(routes.links()),
      capabilities: capabilities.lookup,
      venues: [venue],
      resolveDenom: (chain, denom) =>
          _ref.read(denomResolverProvider).resolve(chain.chainId, denom),
    );
    final request = RouteRequest(
      sourceChainId: from.chainId,
      destChainId: to.chainId,
      inputDenom: from.denom,
      outputDenom: venueOut,
      amount: view.fee!.net.toString(),
      sender: view.signer!,
      recipient: view.destAddress!,
      slippagePercent: view.slippage,
      allowSwap: true,
      maxHops: data.config.maxRouteHops,
      timeoutMinutes: data.config.packetTimeoutMinutes,
      recoveryAddress: view.recoveryAddress,
    );
    var result = await planRoute(
      request,
      deps,
      PlanRouteOptions(
        overrides: view.manual,
        twapWindowSeconds: kTwapWindowSeconds,
      ),
    );
    final wanted = <String>{};
    for (final candidate in result.candidates) {
      for (final hop in candidate.plan.hops) {
        final chainId = hop.counterpartyChainId;
        if (chainId != null &&
            chainId != from.chainId &&
            chainId != to.chainId) {
          wanted.add(chainId);
        }
      }
    }
    final intermediates = <String, String>{
      for (final chainId in wanted)
        if (resolve(chainId) case final String address) chainId: address,
    };
    if (intermediates.isNotEmpty) {
      result = await planRoute(
        request,
        deps,
        PlanRouteOptions(
          overrides: view.manual,
          twapWindowSeconds: kTwapWindowSeconds,
          intermediateReceivers: intermediates,
        ),
      );
    }

    final candidate = result.best;
    if (candidate == null) {
      return (
        result: ContractPlan(
          key: key,
          at: _now(),
          warnings: result.warnings,
          error: result.warnings.isEmpty
              ? 'No route from ${from.chainName} to ${to.chainName} could be planned.'
              : 'No route could be planned: ${result.warnings.first}',
        ),
        plan: null,
        receiver: null,
        venueIn: null,
        links: const <ChannelLink>[],
        hops: const <SwapHopChoice>[],
        warnings: const <String>[],
        blocked: null,
      );
    }

    final hops = <SwapHopChoice>[
      for (var i = 0; i < candidate.links.length; i++)
        SwapHopChoice(
          index: i,
          fromChainId: candidate.links[i].sourceChainId,
          toChainId: candidate.links[i].destChainId,
          channelId: candidate.links[i].channelId,
          options:
              (candidate.links[i].sourceChainId == from.chainId
                      ? inbound
                      : outbound)
                  .where(
                    (o) =>
                        o.counterpartyChainId == candidate.links[i].destChainId,
                  )
                  .toList(),
          manual: candidate.links[i].source == ChannelLinkSource.manual,
        ),
    ];
    final warnings = [...result.warnings, ...candidate.plan.warnings];
    String? blocked;
    // The ICS20 receiver must never be the middleware's placeholder: no key
    // controls it, so a packet addressed there is lost.
    if (candidate.receiver == pfmIntermediateReceiver) {
      blocked =
          'This route passes through a chain the wallet has no address for, so the first packet has nowhere safe to land. Pick a destination with a direct channel.';
    }
    final memo = validateMemo(
      candidate.plan.memo,
      receiver: candidate.receiver,
    );
    if (memo.kind != MemoKind.xcs && memo.kind != MemoKind.forward) {
      blocked ??=
          'Zunia could not account for every part of this route\'s memo, so it will not sign it.';
    }
    final preSwap = candidate.links
        .take(
          candidate.plan.hops
              .takeWhile((hop) => hop.kind != RouteHopKind.swap)
              .length,
        )
        .toList();
    final venueIn = denomAfterHops(from.denom, result.resolvedInput, preSwap);
    return (
      result: null,
      plan: candidate.plan,
      receiver: candidate.receiver,
      venueIn: venueIn,
      links: candidate.links,
      hops: hops,
      warnings: warnings,
      blocked: blocked,
    );
  }

  Future<PoolPlan> _planPool(SwapView view, String key) async {
    final data = view.data!;
    final from = view.from!;
    final to = view.to!;
    final venueChainId = data.venueChainId;
    final venueIn = from.chainId == venueChainId
        ? from.denom
        : from.identity.osmosisDenom ?? '';
    final venueOut = to.chainId == venueChainId
        ? to.denom
        : to.identity.osmosisDenom ?? '';
    // A move-first swap is priced for what it will sell once the tokens are
    // there, after the fee charged on Osmosis.
    final sells = view.path == SwapPath.moveFirst
        ? data.fees.feeFor(venueChainId, view.amountUnits!).net
        : view.fee!.net;
    final lcd = _venueLcd(venueChainId);
    final quote = lcd == null
        ? PoolQuote(
            error:
                'No REST endpoint for $venueChainId, so the swap cannot be priced.',
          )
        : await quotePoolSwap(
            venueInputDenom: venueIn,
            venueOutputDenom: venueOut,
            amountBaseUnits: sells.toString(),
            slippagePercent: view.slippage,
            venueLcd: lcd,
            router: _ref.read(swapRouterProvider),
            describe: _describe,
          );
    PoolDelivery? delivery;
    String? deliveryError;
    if (view.path == SwapPath.poolDeliver && quote.minOut != null) {
      final planned = await planPoolDelivery(view, venueOut);
      delivery = planned.delivery;
      deliveryError = planned.error;
    }
    return PoolPlan(
      key: key,
      at: _now(),
      venueInputDenom: venueIn,
      venueOutputDenom: venueOut,
      amountBaseUnits: sells.toString(),
      quote: quote,
      delivery: delivery,
      deliveryError: deliveryError,
    );
  }

  /// Plan the transfer that sends a pool swap's output from Osmosis to the
  /// To's chain: one direct hop, no memo, over the registry's canonical
  /// channel checked live on Osmosis, delivering exactly the To's denom.
  /// Anything else (a forward through another chain, another variant) is
  /// refused rather than signed behind a swap.
  Future<({PoolDelivery? delivery, String? error})> planPoolDelivery(
    SwapView view,
    String venueOut,
  ) async {
    final data = view.data!;
    final to = view.to!;
    final venueChainId = data.venueChainId;
    const throughAnother =
        'Delivering this token from Osmosis needs a route through another chain, which Zunia does not sign behind a swap. Swap to the token on Osmosis, then send it.';
    const otherVariant =
        'The transfer from Osmosis would deliver another variant of this token than the one you picked, so the swap stays unsigned.';
    String channel;
    String arrival;
    if (venueOut.startsWith('ibc/')) {
      // A voucher goes home by unwinding its one hop.
      final row = data.book.rowOf(venueChainId, venueOut);
      if (row == null ||
          row.channelId == null ||
          row.path.split('/').length != 2 ||
          row.counterpartyChainId != to.chainId) {
        return (delivery: null, error: throughAnother);
      }
      channel = row.channelId!;
      arrival = row.originDenom;
    } else {
      // Osmosis's own token travels out over the canonical channel and
      // arrives as that channel's voucher.
      final canonical = data.book.canonicalChannel(venueChainId, to.chainId);
      if (canonical == null) {
        return (
          delivery: null,
          error: 'Zunia found no channel from Osmosis to deliver this token.',
        );
      }
      channel = canonical.channelId;
      arrival = ibcDenomHash(
        '$transferPort/${canonical.counterpartyChannelId}',
        venueOut,
      );
    }
    String key(String denom) =>
        denom.startsWith('ibc/') ? denom.toUpperCase() : denom;
    if (key(arrival) != key(to.denom)) {
      return (delivery: null, error: otherVariant);
    }
    try {
      final check = await _ref
          .read(channelServiceProvider)
          .validateIbcChannel(venueChainId, channel, destChainId: to.chainId);
      if (!check.ok) return (delivery: null, error: check.message);
    } on InterchainError catch (error) {
      return (delivery: null, error: _describe(error));
    }
    return (
      delivery: PoolDelivery(
        sourceChannel: channel,
        destChainId: to.chainId,
        arrivalDenom: to.denom,
      ),
      error: null,
    );
  }

  /* ---------------------------------------------------------------- *
   * Prices
   * ---------------------------------------------------------------- */

  /// A new price for the plan on screen; the form keeps its price current on
  /// its own, the confirm screen asks for one.
  Future<void> refresh(SwapView view) async {
    final key = view.planKey;
    final data = view.data;
    if (key.isEmpty || data == null) return;
    state = state.copyWith(refreshingKey: key);
    try {
      if (view.path == SwapPath.contract) {
        final current = view.contract;
        final venueIn = current?.venueInputDenom;
        final venueOut = current?.venueOutputDenom;
        final contract = current?.contract;
        if (current == null ||
            venueIn == null ||
            venueOut == null ||
            contract == null) {
          return;
        }
        final price = await quoteOnVenue(
          VenueQuoteInput(
            contract: contract,
            venueInputDenom: venueIn,
            venueOutputDenom: venueOut,
            amountBaseUnits: view.fee!.net.toString(),
            slippagePercent: view.slippage,
          ),
          data.venueChainId,
        );
        if (mounted && state.contract?.key == key) {
          state = state.copyWith(contract: current.withPrice(price, _now()));
        }
      } else {
        final current = view.pool;
        final lcd = _venueLcd(data.venueChainId);
        if (current == null || lcd == null) return;
        final next = await quotePoolSwap(
          venueInputDenom: current.venueInputDenom,
          venueOutputDenom: current.venueOutputDenom,
          amountBaseUnits: current.amountBaseUnits,
          slippagePercent: view.slippage,
          venueLcd: lcd,
          router: _ref.read(swapRouterProvider),
          describe: _describe,
        );
        if (mounted && state.pool?.key == key) {
          state = state.copyWith(pool: current.withQuote(next, _now()));
        }
      }
    } finally {
      if (mounted && state.refreshingKey == key) {
        state = state.copyWith(clearRefreshing: true);
      }
    }
  }

  /* ---------------------------------------------------------------- *
   * Review
   * ---------------------------------------------------------------- */

  /// Price the swap again, build what gets signed against that price, and
  /// freeze it all as the review: the rows, the amount and its fee, the plan,
  /// the price and the addresses it was made for.
  Future<PreparedSwap> prepareReview(SwapView view, {DateTime? now}) async {
    final data = view.data;
    final from = view.from;
    final to = view.to;
    final signer = view.signer;
    final amountUnits = view.amountUnits;
    final fee = view.fee;
    final destAddress = view.destAddress;
    if (!view.ready ||
        data == null ||
        from == null ||
        to == null ||
        signer == null ||
        amountUnits == null ||
        fee == null ||
        destAddress == null) {
      throw SwapException(
        view.blockedReason ?? 'The swap is not ready to review.',
      );
    }
    final chain = ChainCatalog.isLoaded
        ? ChainCatalog.instance.find(from.chainId)
        : null;
    if (chain == null) {
      throw SwapException(
        '${from.chainId} is not in this wallet\'s chain list.',
      );
    }
    final at = now ?? _now();
    final config = data.config;
    _reviewCount += 1;

    // Pin the pair: an unpicked To is not picked again under the review.
    state = state.copyWith(fromKey: from.key, toKey: to.key);

    if (view.path == SwapPath.contract) {
      final contract = view.contract!;
      final plan = contract.plan!;
      final requote = VenueQuoteInput(
        contract: contract.contract!,
        venueInputDenom: contract.venueInputDenom!,
        venueOutputDenom: contract.venueOutputDenom!,
        amountBaseUnits: fee.net.toString(),
        slippagePercent: view.slippage,
      );
      final price = await quoteOnVenue(requote, data.venueChainId);
      final priced = _now();
      if (mounted && state.contract?.key == contract.key) {
        state = state.copyWith(contract: contract.withPrice(price, priced));
      }
      if (price.quote == null) {
        throw SwapException(
          quoteBlockText(price.code, price.error, from, to) ??
              'The price could not be refreshed, so the swap was not prepared.',
        );
      }
      final resolve = _ref.read(swapAddressResolverProvider);
      final own = <String, String>{
        for (final hop in plan.hops)
          for (final chainId in [hop.chainId, ?hop.counterpartyChainId])
            if (chainId != from.chainId &&
                chainId != to.chainId &&
                chainId != data.venueChainId)
              if (resolve(chainId) case final String address) chainId: address,
      };
      final review = ContractSwapReview(
        id: _reviewCount,
        from: from,
        to: to,
        amountUnits: amountUnits,
        fee: fee,
        planKey: view.planKey,
        signer: signer,
        recipient: destAddress,
        price: SwapPrice(quote: price.quote, at: priced),
        plan: plan,
        receiver: contract.receiver ?? '',
        requote: requote,
        recoveryAddress: view.recoveryAddress!,
        contract: contract.contract!,
        contractLabel: view.venue?.label,
        ownAddresses: own,
      );
      final msgs = swapTxMsgs(
        plan: plan,
        receiver: review.receiver,
        sender: signer,
        denom: from.denom,
        fee: fee,
        timeoutMinutes: config.packetTimeoutMinutes,
        now: at,
      );
      return PreparedSwap(
        review: review,
        msgs: msgs,
        memo: swapTxMemo(msgs, from.chainId, data.book),
        chain: chain,
      );
    }

    final pool = view.pool!;
    final lcd = _venueLcd(data.venueChainId);
    if (lcd == null) {
      throw SwapException('No REST endpoint for ${data.venueChainId}.');
    }
    final next = await quotePoolSwap(
      venueInputDenom: pool.venueInputDenom,
      venueOutputDenom: pool.venueOutputDenom,
      amountBaseUnits: pool.amountBaseUnits,
      slippagePercent: view.slippage,
      venueLcd: lcd,
      router: _ref.read(swapRouterProvider),
      describe: _describe,
    );
    final priced = _now();
    if (mounted && state.pool?.key == pool.key) {
      state = state.copyWith(pool: pool.withQuote(next, priced));
    }
    if (!next.ready) {
      throw SwapException(
        poolQuoteText(next.code, next.error, from, to) ??
            'The price could not be refreshed, so the swap was not prepared.',
      );
    }
    final delivery = view.path == SwapPath.poolDeliver ? pool.delivery : null;
    if (view.path == SwapPath.poolDeliver && delivery == null) {
      throw SwapException(
        pool.deliveryError ??
            'The transfer to ${to.chainName} is not planned yet.',
      );
    }
    final review = PoolSwapReview(
      id: _reviewCount,
      from: from,
      to: to,
      amountUnits: amountUnits,
      fee: fee,
      planKey: view.planKey,
      signer: signer,
      recipient: view.path == SwapPath.pool ? signer : destAddress,
      price: SwapPrice(quote: next.quote, at: priced),
      poolPath: view.path!,
      venueOutputDenom: pool.venueOutputDenom,
      slippagePercent: view.slippage,
      routes: next.routes!,
      minOut: next.minOut!,
      delivery: delivery,
    );
    final msgs = poolSwapTxMsgs(
      sender: signer,
      denom: from.denom,
      routes: review.routes,
      minOut: review.minOut,
      fee: fee,
      delivery: delivery,
      recipient: review.recipient,
      timeoutMinutes: config.packetTimeoutMinutes,
      now: at,
    );
    return PreparedSwap(
      review: review,
      msgs: msgs,
      memo: swapTxMemo(msgs, from.chainId, data.book),
      chain: chain,
    );
  }

  /// A new price for a reviewed swap, whatever the form now shows. A contract
  /// swap keeps its message (the memo carries a TWAP tolerance); a pool swap's
  /// floor is in the message, so its messages are built again.
  Future<({SwapReview review, List<TxMsg>? msgs, String? error})> refreshReview(
    SwapReview review, {
    DateTime? now,
  }) async {
    final data = await _ref.read(swapDataProvider.future);
    switch (review) {
      case ContractSwapReview():
        final price = await quoteOnVenue(review.requote, data.venueChainId);
        final next = review.withPrice(
          SwapPrice(
            quote: price.quote,
            error: quoteBlockText(
              price.code,
              price.error,
              review.from,
              review.to,
            ),
            code: price.code,
            at: _now(),
          ),
        );
        return (review: next, msgs: null, error: next.price.error);
      case PoolSwapReview():
        final lcd = _venueLcd(data.venueChainId);
        if (lcd == null) {
          return (
            review: review,
            msgs: null,
            error: 'No REST endpoint for ${data.venueChainId}.',
          );
        }
        final next = await quotePoolSwap(
          venueInputDenom: review.from.denom,
          venueOutputDenom: review.venueOutputDenom,
          amountBaseUnits: review.fee.net.toString(),
          slippagePercent: review.slippagePercent,
          venueLcd: lcd,
          router: _ref.read(swapRouterProvider),
          describe: _describe,
        );
        if (!next.ready) {
          return (
            review: review,
            msgs: null,
            error:
                poolQuoteText(next.code, next.error, review.from, review.to) ??
                'The price could not be refreshed. The one you reviewed has expired.',
          );
        }
        final updated = review.withPrice(
          price: SwapPrice(quote: next.quote, at: _now()),
          routes: next.routes!,
          minOut: next.minOut!,
        );
        final msgs = poolSwapTxMsgs(
          sender: review.signer,
          denom: review.from.denom,
          routes: updated.routes,
          minOut: updated.minOut,
          fee: review.fee,
          delivery: review.delivery,
          recipient: review.recipient,
          timeoutMinutes: data.config.packetTimeoutMinutes,
          now: now ?? _now(),
        );
        return (review: updated, msgs: msgs, error: null);
    }
  }

  /// The first step of a `move-first` swap: remember the pair so Swap opens
  /// on it again once the tokens arrive as their Osmosis voucher.
  Future<void> rememberMoveFirst(SwapView view) async {
    final from = view.from;
    final to = view.to;
    final arrives = from?.identity.osmosisDenom;
    if (from == null || to == null || arrives == null) return;
    await rememberSwapIntent(
      SwapIntent('${view.venueChainId}:$arrives', to.key),
    );
  }
}

final swapControllerProvider =
    StateNotifierProvider<SwapController, SwapFormState>(
      (ref) => SwapController(ref),
    );
