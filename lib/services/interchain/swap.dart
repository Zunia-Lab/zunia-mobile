/// Osmosis quoting and XCS slippage.
///
/// Dart mirror of `swap.ts`. Two venues, in this order: the Osmosis SQS router
/// (a graph search over every pool with live liquidity, which is what the web
/// app uses), and the chain's own poolmanager for a route the caller already
/// knows. Neither invents a number: a field the venue did not report is null
/// here and renders as "not reported", never as 0.
library;

import 'package:flutter/foundation.dart';

import 'lcd.dart';
import 'memo.dart';
import 'types.dart';

/// REST paths this module calls. `{pool_id}` is the only placeholder.
@immutable
class OsmosisSwapPaths {
  const OsmosisSwapPaths();

  /// Capitalised on purpose: the lowercase `/params` answers HTTP 501.
  String get params => '/osmosis/poolmanager/v1beta1/Params';
  String get pool => '/osmosis/poolmanager/v1beta1/pools/{pool_id}';

  /// The only pool query that answers the same shape for every pool type, so
  /// denom membership is read from here rather than from the pool document.
  String get totalPoolLiquidity =>
      '/osmosis/poolmanager/v1beta1/pools/{pool_id}/total_pool_liquidity';

  String get estimateSinglePoolSwapExactAmountIn =>
      '/osmosis/poolmanager/v1beta1/{pool_id}/estimate/single_pool_swap_exact_amount_in';

  /// v2, not v1beta1: the v1beta1 spelling answers HTTP 501.
  String get spotPrice => '/osmosis/poolmanager/v2/pools/{pool_id}/prices';

  String get tradingPairTakerFee =>
      '/osmosis/poolmanager/v1beta1/trading_pair_takerfee';

  /// SQS router paths. These are on the SQS host, not the chain LCD.
  String get routerQuote => '/router/quote';
  String get routerRoutes => '/router/routes';
  String get routerCustomDirectQuote => '/router/custom-direct-quote';
}

const OsmosisSwapPaths osmosisSwapPaths = OsmosisSwapPaths();

/// Public SQS router base URLs, highest priority first.
///
/// Data, not a baked-in client: a host builds its router [LcdClient] from these
/// or from its own deployment.
const List<String> osmosisRouterEndpoints = [
  'https://sqs.osmosis.zone',
  'https://sqsprod.osmosis.zone',
];

/// Chain-id prefixes accepted as "this is Osmosis".
///
/// Mainnet is `osmosis-1`; the public testnet is `osmo-test-5`, which does not
/// share a prefix with mainnet, hence two entries.
const List<String> osmosisChainIdPrefixes = ['osmosis-', 'osmo-test-'];

/// Slippage tolerance used when the caller does not state one, as a percentage.
const double kDefaultSlippagePercent = 1;

/// TWAP window in the crosschain-swaps README example, in seconds.
///
/// Not applied by default: the contract's own `Option<u64>` falls back to 3600,
/// and omitting the key takes that rather than guessing a window. A short window
/// on a thin pool reads a noisier price.
const int kDefaultTwapWindowSeconds = 10;

const int _defaultMaxRoutes = 4;

/// Fixed-point scale for percentage arithmetic.
///
/// Amounts are uint128 on the wire, so slippage is applied with [BigInt], and
/// BigInt needs the percentage as an integer. Six places is far finer than any
/// slippage a UI offers.
const int _percentDecimals = 6;
final BigInt _percentScale = BigInt.from(1000000);
final BigInt _fullPercentScaled = BigInt.from(100) * _percentScale;

InterchainError _invalidRequest(String message) =>
    InterchainError(InterchainErrorCode.invalidRequest, message);

InterchainError _malformed(String what) =>
    InterchainError(InterchainErrorCode.malformedResponse, 'Osmosis: $what');

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

String? _asNonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A uint field as the LCD spells it: usually a string, sometimes a number.
String? _asUintString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return RegExp(r'^\d+$').hasMatch(trimmed) ? trimmed : null;
  }
  if (value is int && value >= 0) return '$value';
  if (value is double && value >= 0 && value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return null;
}

/// A decimal fraction as the venue spells it. Null when absent or unparseable.
String? _asDecimalString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return RegExp(r'^-?\d+(\.\d+)?$').hasMatch(trimmed) ? trimmed : null;
  }
  if (value is num && value.isFinite) return formatPlainDecimal(value.toDouble());
  return null;
}

BigInt _parseAmount(String value, String label) {
  final trimmed = value.trim();
  if (!RegExp(r'^\d+$').hasMatch(trimmed)) {
    throw _invalidRequest('$label must be an integer string in base units, '
        'got "$value"');
  }
  return BigInt.parse(trimmed);
}

BigInt _scalePercent(double percent, String label) {
  if (!percent.isFinite || percent < 0 || percent > 100) {
    throw _invalidRequest('$label must be between 0 and 100, got $percent');
  }
  return BigInt.from((percent * _percentScale.toInt()).round());
}

/// Render a double without exponent notation.
///
/// The contract parses `slippage_percentage` as a Decimal and rejects `1e-7`,
/// so a percentage must never reach it in scientific form.
String formatPlainDecimal(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toStringAsFixed(0);
  }
  var text = value.toStringAsFixed(_percentDecimals + 6);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

/// Reduce an amount by a slippage tolerance, rounding down.
///
/// Rounding down is deliberate: the result becomes a floor the chain enforces,
/// and rounding up would put the floor above what the quote promised.
String applySlippage(String amount, double slippagePercent) {
  final value = _parseAmount(amount, 'amount');
  final scaled = _scalePercent(slippagePercent, 'slippagePercent');
  final kept = _fullPercentScaled - scaled;
  return ((value * kept) ~/ _fullPercentScaled).toString();
}

/// `numerator / denominator` as a double, via BigInt.
///
/// Amounts can exceed the safe integer range, so the division happens in
/// integers and only the ratio — a display value bounded by the price — is
/// converted. Null on a zero denominator.
double? _ratioOf(BigInt numerator, BigInt denominator) {
  if (denominator == BigInt.zero) return null;
  final scale = BigInt.from(10).pow(18);
  return (numerator * scale ~/ denominator).toDouble() / 1e18;
}

/* -------------------------------------------------------------------------- *
 * XCS slippage forms
 * -------------------------------------------------------------------------- */

/// Build the `twap` form of the XCS `slippage` field.
///
/// The contract compares the swap against a time-weighted average price over
/// `window_seconds` and aborts if the result is worse than
/// `slippage_percentage`. Prefer this over [minOutputFromQuote] when the packet
/// may sit in a relayer queue: an absolute minimum computed now goes stale, a
/// TWAP tolerance does not.
///
/// [windowSeconds] null omits the key entirely, so the contract's own default
/// applies rather than a guess.
XcsTwapSlippage slippageToTwapParams(double percent, {int? windowSeconds}) {
  // Validate through the same path as everything else, then render the
  // percentage as a plain decimal: the contract parses it as a Decimal and
  // rejects exponent notation.
  _scalePercent(percent, 'percent');
  if (windowSeconds != null && windowSeconds <= 0) {
    throw _invalidRequest(
        'windowSeconds must be a positive integer, got $windowSeconds');
  }
  return XcsTwapSlippage(
    slippagePercentage: formatPlainDecimal(percent),
    windowSeconds: windowSeconds,
  );
}

/// Build the `min_output_amount` form of the XCS `slippage` field from a quote.
///
/// Omit [slippagePercent] to use [SwapQuote.minReceived], which the quote
/// already derived.
XcsMinOutputSlippage minOutputFromQuote(SwapQuote quote, {double? slippagePercent}) {
  if (slippagePercent == null) {
    // Re-parse rather than trust: `minReceived` may have come from a caller's
    // own SwapQuote, not from this module.
    _parseAmount(quote.minReceived, 'quote.minReceived');
    return XcsMinOutputSlippage(quote.minReceived);
  }
  return XcsMinOutputSlippage(applySlippage(quote.outputAmount, slippagePercent));
}

/* -------------------------------------------------------------------------- *
 * Quote types
 * -------------------------------------------------------------------------- */

/// Which venue produced a quote.
enum OsmosisQuoteSource { router, poolmanager }

/// One pool leg of a route, with the venue's fee data attached.
@immutable
class OsmosisPoolLeg {
  const OsmosisPoolLeg({
    required this.poolId,
    required this.tokenOutDenom,
    this.spreadFactor,
    this.takerFee,
    this.poolType,
  });

  final String poolId;
  final String tokenOutDenom;

  /// Pool spread factor (the LP fee) as a decimal fraction string. Null when
  /// the venue did not say.
  final String? spreadFactor;

  /// Protocol taker fee as a decimal fraction string. Charged by poolmanager on
  /// top of the spread factor. Null when the venue did not say.
  final String? takerFee;

  /// Raw poolmanager pool-type discriminant. Kept as a number on purpose: the
  /// enum is Osmosis-internal and gains members, and naming them here would turn
  /// a new pool type into a parse failure.
  final int? poolType;
}

/// One split of an order. The router may divide an order across several routes.
@immutable
class OsmosisRouteSplit {
  const OsmosisRouteSplit({
    required this.pools,
    required this.inAmount,
    required this.outAmount,
  });

  final List<OsmosisPoolLeg> pools;
  final String inAmount;
  final String outAmount;
}

/// A priced Osmosis swap.
@immutable
class OsmosisSwapQuote extends SwapQuote {
  const OsmosisSwapQuote({
    required super.inputDenom,
    required super.inputAmount,
    required super.outputDenom,
    required super.outputAmount,
    required super.priceImpact,
    required super.poolFee,
    required super.minReceived,
    required super.slippagePercent,
    required super.route,
    required this.source,
    required this.splits,
    required this.spotPrice,
    required this.effectiveFeeFraction,
    required this.warnings,
    required this.fetchedAt,
  });

  final OsmosisQuoteSource source;

  /// Every split, in the venue's order. [SwapQuote.route] mirrors the largest.
  final List<OsmosisRouteSplit> splits;

  /// Spot price at quote time, output units per input unit. Null when neither
  /// venue reported one.
  final String? spotPrice;

  /// Total fee as a decimal fraction (`"0.008"` = 0.8%), the raw form
  /// [SwapQuote.poolFee] is derived from.
  final String? effectiveFeeFraction;

  /// Non-fatal notes: split orders, missing fee data, forced routes.
  final List<String> warnings;

  /// When the quote was assembled. Quotes go stale in seconds.
  final DateTime fetchedAt;
}

/// A route between two denoms, as pool legs.
@immutable
class OsmosisRouteLeg {
  const OsmosisRouteLeg({
    required this.poolId,
    required this.tokenInDenom,
    required this.tokenOutDenom,
  });

  final String poolId;
  final String tokenInDenom;
  final String tokenOutDenom;
}

/// Normalised shape of an SQS `/router/quote` response.
@immutable
class OsmosisRouterQuote {
  const OsmosisRouterQuote({
    required this.inDenom,
    required this.inAmount,
    required this.outAmount,
    required this.splits,
    required this.effectiveFeeFraction,
    required this.priceImpactFraction,
    required this.spotPrice,
  });

  final String inDenom;
  final String inAmount;
  final String outAmount;
  final List<OsmosisRouteSplit> splits;

  /// Total fee as a decimal fraction, `"0.008"` = 0.8%. Null when absent.
  final String? effectiveFeeFraction;

  /// Price impact as the router reports it: a decimal fraction that is
  /// **negative** when the trade moves the price against the user. Fees are not
  /// included — SQS reports them separately in `effective_fee`.
  final String? priceImpactFraction;

  /// `in_base_out_quote_spot_price`: output units per input unit.
  final String? spotPrice;
}

OsmosisPoolLeg? _parsePoolLeg(Object? value) {
  final row = _asRecord(value);
  if (row == null) return null;
  final poolId = _asUintString(row['id']) ?? _asUintString(row['pool_id']);
  final tokenOutDenom = _asNonEmptyString(row['token_out_denom']);
  if (poolId == null || tokenOutDenom == null) return null;
  return OsmosisPoolLeg(
    poolId: poolId,
    tokenOutDenom: tokenOutDenom,
    spreadFactor: _asDecimalString(row['spread_factor']),
    takerFee: _asDecimalString(row['taker_fee']),
    poolType: row['type'] is int ? row['type'] as int : null,
  );
}

/// Parse an SQS `/router/quote` or `/router/custom-direct-quote` body.
///
/// Throws `malformedResponse` when the amounts or the route array are missing,
/// and `noRoute` when the router answered with an empty route — which is how it
/// reports "priceable pair, but not at this size".
OsmosisRouterQuote parseRouterQuote(Object? body) {
  final row = _asRecord(body);
  if (row == null) throw _malformed('router quote is not an object');

  final amountIn = _asRecord(row['amount_in']);
  final inDenom = amountIn == null ? null : _asNonEmptyString(amountIn['denom']);
  final inAmount = amountIn == null ? null : _asUintString(amountIn['amount']);
  final outAmount = _asUintString(row['amount_out']);
  if (inDenom == null || inAmount == null || outAmount == null) {
    throw _malformed('router quote is missing amount_in or amount_out');
  }

  final routes = row['route'];
  if (routes is! List) throw _malformed('router quote has no route array');

  final splits = <OsmosisRouteSplit>[];
  for (final entry in routes) {
    final split = _asRecord(entry);
    if (split == null) continue;
    final pools = split['pools'];
    if (pools is! List) continue;
    final legs = <OsmosisPoolLeg>[];
    var broken = false;
    for (final pool in pools) {
      final leg = _parsePoolLeg(pool);
      // A leg we cannot read makes the whole split unusable: a route with a hole
      // in it would misreport which pools the funds pass through.
      if (leg == null) {
        broken = true;
        break;
      }
      legs.add(leg);
    }
    if (broken || legs.isEmpty) continue;
    splits.add(OsmosisRouteSplit(
      pools: legs,
      inAmount: _asUintString(split['in_amount']) ?? inAmount,
      outAmount: _asUintString(split['out_amount']) ?? outAmount,
    ));
  }

  if (splits.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.noRoute,
      'Osmosis router returned no usable route for $inDenom',
    );
  }

  return OsmosisRouterQuote(
    inDenom: inDenom,
    inAmount: inAmount,
    outAmount: outAmount,
    splits: splits,
    effectiveFeeFraction: _asDecimalString(row['effective_fee']),
    priceImpactFraction: _asDecimalString(row['price_impact']),
    spotPrice: _asDecimalString(row['in_base_out_quote_spot_price']),
  );
}

/// Parse `{"token_out_amount":"22411"}` from a single-pool estimate.
String parseSinglePoolEstimate(Object? body) {
  final row = _asRecord(body);
  final amount = row == null ? null : _asUintString(row['token_out_amount']);
  if (amount == null) {
    throw _malformed('single-pool estimate has no token_out_amount');
  }
  return amount;
}

/// Parse `{"liquidity":[{"denom":…}]}` into its denoms.
List<String> parsePoolDenoms(Object? body) {
  final row = _asRecord(body);
  final list = row?['liquidity'];
  if (list is! List) throw _malformed('total_pool_liquidity has no liquidity array');
  final denoms = <String>[];
  for (final entry in list) {
    final denom = _asNonEmptyString(_asRecord(entry)?['denom']);
    if (denom != null) denoms.add(denom);
  }
  return denoms;
}

/// Parse `{"spot_price":"0.0226…"}`. Null when absent: a missing spot price
/// only costs the price-impact figure, which is not worth failing a quote over.
String? parseSpotPrice(Object? body) => _asDecimalString(_asRecord(body)?['spot_price']);

/// Parse `{"taker_fee":"0.008…"}`. Null when absent, for the same reason.
String? parseTakerFee(Object? body) => _asDecimalString(_asRecord(body)?['taker_fee']);

/// Pull a pool's spread factor out of a pool document.
///
/// Every pool type spells it differently and new types keep appearing, so this
/// probes the known spellings and returns null rather than failing.
String? parsePoolSpreadFactor(Object? body) {
  final envelope = _asRecord(body);
  final pool = _asRecord(envelope?['pool']) ?? envelope;
  if (pool == null) return null;
  final params = _asRecord(pool['pool_params']);
  if (params != null) {
    final fee = _asDecimalString(params['swap_fee']);
    if (fee != null) return fee;
  }
  return _asDecimalString(pool['spread_factor']);
}

String _fillPoolPath(String path, String poolId) =>
    path.replaceAll('{pool_id}', Uri.encodeComponent(poolId));

/* -------------------------------------------------------------------------- *
 * Quoting
 * -------------------------------------------------------------------------- */

/// What [quoteOsmosisSwap] needs.
@immutable
class OsmosisSwapQuoteParams {
  const OsmosisSwapQuoteParams({
    required this.tokenInDenom,
    required this.tokenInAmount,
    required this.tokenOutDenom,
    this.slippagePercent,
    this.router,
    this.route,
    this.candidatePoolIds,
    this.maxRoutes,
    this.singleRoute = false,
    this.minOutputAmount,
    this.allowAnyChainId = false,
  });

  final String tokenInDenom;

  /// Base units as a decimal string. Never a number.
  final String tokenInAmount;

  final String tokenOutDenom;

  /// Tolerance as a percentage, e.g. `1` for 1%.
  final double? slippagePercent;

  /// The SQS router, as its own client. Absent means LCD-only quoting, which
  /// needs [route] or [candidatePoolIds] because the chain has no pool-by-denom
  /// index.
  final LcdClient? router;

  /// Quote exactly this route instead of searching.
  final List<SwapPoolHop>? route;

  /// Pools to consider when there is no router. Only direct (single-leg) pairs
  /// are found from these.
  final List<String>? candidatePoolIds;

  final int? maxRoutes;

  /// Ask the router for one path rather than a split order.
  final bool singleRoute;

  /// Reject the quote when the output falls below this, base units.
  final String? minOutputAmount;

  /// Skip the "is this Osmosis?" check on the LCD's chain id.
  final bool allowAnyChainId;
}

void _assertOsmosisChain(LcdClient lcd, OsmosisSwapQuoteParams params) {
  if (params.allowAnyChainId) return;
  final known = osmosisChainIdPrefixes.any(lcd.chainId.startsWith);
  if (!known) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      '${lcd.chainId} is not an Osmosis chain; poolmanager swaps are '
      'Osmosis-only',
      chainId: lcd.chainId,
    );
  }
}

/// Find pool routes between two denoms.
///
/// **Prefer the router.** Osmosis's own router does a graph search over every
/// pool with live liquidity. Without one this only tests the caller's
/// [OsmosisSwapQuoteParams.candidatePoolIds] for a pool holding both denoms:
/// there is no multi-hop search and no liquidity ranking, because the chain
/// exposes no pool-by-denom index and enumerating every pool is not something a
/// phone should do on a quote.
Future<List<OsmosisRouteLeg>> _findDirectRoute(
  OsmosisSwapQuoteParams params,
  LcdClient lcd,
) async {
  final candidates = params.candidatePoolIds ?? const <String>[];
  if (candidates.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.noRoute,
      'Osmosis pool search needs either a router client or candidate pool ids: '
      'the chain LCD has no pool-by-denom index',
      chainId: lcd.chainId,
    );
  }
  for (final poolId in candidates) {
    List<String> denoms;
    try {
      denoms = parsePoolDenoms(await lcd.getJson(
        _fillPoolPath(osmosisSwapPaths.totalPoolLiquidity, poolId),
      ));
    } on Object {
      // One unreadable or missing pool must not sink the search; the caller's
      // candidate list is a guess by construction.
      continue;
    }
    if (denoms.contains(params.tokenInDenom) &&
        denoms.contains(params.tokenOutDenom)) {
      return [
        OsmosisRouteLeg(
          poolId: poolId,
          tokenInDenom: params.tokenInDenom,
          tokenOutDenom: params.tokenOutDenom,
        ),
      ];
    }
  }
  return const [];
}

OsmosisRouteSplit? _largestSplit(List<OsmosisRouteSplit> splits) {
  OsmosisRouteSplit? best;
  var bestAmount = BigInt.from(-1);
  for (final split in splits) {
    final value = RegExp(r'^\d+$').hasMatch(split.inAmount)
        ? BigInt.parse(split.inAmount)
        : BigInt.zero;
    if (value > bestAmount) {
      bestAmount = value;
      best = split;
    }
  }
  return best;
}

List<SwapPoolHop> _toSwapPoolHops(List<OsmosisPoolLeg> legs) => [
      for (final leg in legs)
        SwapPoolHop(poolId: leg.poolId, tokenOutDenom: leg.tokenOutDenom),
    ];

/// Ask the SQS router for a quote.
///
/// [OsmosisSwapQuoteParams.route] forces a path through
/// `/router/custom-direct-quote`, whose `poolID` and `tokenOutDenom` are
/// positional comma-separated lists.
Future<OsmosisRouterQuote> _quoteViaRouter(
  OsmosisSwapQuoteParams params,
  LcdClient router,
) async {
  final forced = params.route;
  final path = forced != null
      ? osmosisSwapPaths.routerCustomDirectQuote
      : osmosisSwapPaths.routerQuote;
  final query = <String, Object?>{
    'tokenIn': '${params.tokenInAmount}${params.tokenInDenom}',
    'tokenOutDenom': forced != null
        ? forced.map((hop) => hop.tokenOutDenom).join(',')
        : params.tokenOutDenom,
    if (forced != null) 'poolID': forced.map((hop) => hop.poolId).join(','),
    if (forced == null && params.singleRoute) 'singleRoute': true,
  };

  try {
    return parseRouterQuote(
        await router.getJson(path, LcdRequestOptions(query: query)));
  } on InterchainError catch (error) {
    if (error.code == InterchainErrorCode.noRoute ||
        error.code == InterchainErrorCode.aborted ||
        error.code == InterchainErrorCode.readsDisabled) {
      rethrow;
    }
    throw InterchainError(
      InterchainErrorCode.noRoute,
      'Osmosis router cannot price ${params.tokenInDenom} -> '
      '${params.tokenOutDenom}',
      chainId: router.chainId,
      cause: error,
    );
  }
}

@immutable
class _LegFacts {
  const _LegFacts(this.spreadFactor, this.takerFee, this.spotPrice);

  final String? spreadFactor;
  final String? takerFee;
  final String? spotPrice;
}

/// Read a leg's fees and spot price.
///
/// Every field is optional: a quote is still useful without them, so each query
/// failure degrades one number rather than the whole call.
Future<_LegFacts> _readLegFacts(
  String poolId,
  String tokenInDenom,
  String tokenOutDenom,
  LcdClient lcd,
) async {
  Future<T?> attempt<T>(Future<T?> Function() run) async {
    try {
      return await run();
    } on Object {
      return null;
    }
  }

  final results = await Future.wait<String?>([
    attempt(() async => parsePoolSpreadFactor(
        await lcd.getJson(_fillPoolPath(osmosisSwapPaths.pool, poolId)))),
    attempt(() async => parseTakerFee(await lcd.getJson(
          osmosisSwapPaths.tradingPairTakerFee,
          LcdRequestOptions(
            query: {'denom_0': tokenInDenom, 'denom_1': tokenOutDenom},
          ),
        ))),
    attempt(() async => parseSpotPrice(await lcd.getJson(
          _fillPoolPath(osmosisSwapPaths.spotPrice, poolId),
          LcdRequestOptions(query: {
            'base_asset_denom': tokenInDenom,
            'quote_asset_denom': tokenOutDenom,
          }),
        ))),
  ]);
  return _LegFacts(results[0], results[1], results[2]);
}

@immutable
class _PoolmanagerQuote {
  const _PoolmanagerQuote({
    required this.outAmount,
    required this.legs,
    required this.spotPrice,
    required this.feeFraction,
    required this.priceImpactPercent,
    required this.warnings,
  });

  final String outAmount;
  final List<OsmosisPoolLeg> legs;
  final String? spotPrice;
  final String? feeFraction;
  final double? priceImpactPercent;
  final List<String> warnings;
}

/// Quote a known route by chaining single-pool estimates.
///
/// One `single_pool_swap_exact_amount_in` per leg, feeding each leg's output
/// into the next. `EstimateSwapExactAmountIn` would do this in one call but is
/// unreachable over REST.
Future<_PoolmanagerQuote> _quoteViaPoolmanager(
  List<OsmosisRouteLeg> route,
  OsmosisSwapQuoteParams params,
  LcdClient lcd,
) async {
  final warnings = <String>[];
  final legs = <OsmosisPoolLeg>[];
  var amount = params.tokenInAmount;

  // Fees and spot prices are per-leg and independent of the running amount, so
  // they are gathered in parallel while the estimates run in sequence.
  final factsFuture = Future.wait([
    for (final leg in route)
      _readLegFacts(leg.poolId, leg.tokenInDenom, leg.tokenOutDenom, lcd),
  ]);

  for (final leg in route) {
    Object? body;
    try {
      body = await lcd.getJson(
        _fillPoolPath(
          osmosisSwapPaths.estimateSinglePoolSwapExactAmountIn,
          leg.poolId,
        ),
        LcdRequestOptions(query: {
          'token_in': '$amount${leg.tokenInDenom}',
          'token_out_denom': leg.tokenOutDenom,
        }),
      );
    } on InterchainError catch (error) {
      if (error.code == InterchainErrorCode.aborted ||
          error.code == InterchainErrorCode.readsDisabled) {
        rethrow;
      }
      throw InterchainError(
        InterchainErrorCode.noRoute,
        'Osmosis pool ${leg.poolId} cannot swap ${leg.tokenInDenom} -> '
        '${leg.tokenOutDenom} (the pool may not hold both denoms, or every '
        'REST endpoint failed)',
        chainId: lcd.chainId,
        cause: error,
      );
    }
    amount = parseSinglePoolEstimate(body);
    legs.add(OsmosisPoolLeg(
      poolId: leg.poolId,
      tokenOutDenom: leg.tokenOutDenom,
    ));
  }

  final facts = await factsFuture;

  // Compose the legs' fees. Poolmanager takes the taker fee off the input and
  // the pool then takes its spread factor off what is left, so within a leg the
  // two surviving fractions multiply, and so do the legs. A null is skipped,
  // which understates the fee — hence the warning.
  var survivingValue = 1.0;
  var anyFee = false;
  var missingFee = false;
  var spotProduct = 1.0;
  var anySpot = false;
  var missingSpot = false;

  for (var i = 0; i < legs.length; i++) {
    final fact = facts[i];
    legs[i] = OsmosisPoolLeg(
      poolId: legs[i].poolId,
      tokenOutDenom: legs[i].tokenOutDenom,
      spreadFactor: fact.spreadFactor,
      takerFee: fact.takerFee,
    );

    final spread =
        fact.spreadFactor == null ? null : double.tryParse(fact.spreadFactor!);
    final taker = fact.takerFee == null ? null : double.tryParse(fact.takerFee!);
    if (spread == null && taker == null) {
      missingFee = true;
    } else {
      anyFee = true;
      survivingValue *= (1 - (spread ?? 0)) * (1 - (taker ?? 0));
      if (spread == null || taker == null) missingFee = true;
    }

    final spot = fact.spotPrice == null ? null : double.tryParse(fact.spotPrice!);
    if (spot == null || !spot.isFinite || spot <= 0) {
      missingSpot = true;
    } else {
      anySpot = true;
      spotProduct *= spot;
    }
  }

  if (missingFee) {
    warnings.add('Some pool fees could not be read; the reported fee is a '
        'lower bound.');
  }

  final feeFraction = anyFee ? formatPlainDecimal(1 - survivingValue) : null;
  final spotPrice =
      anySpot && !missingSpot ? formatPlainDecimal(spotProduct) : null;

  // Price impact is what is left after fees: the venue's effective rate divided
  // by the fee-adjusted spot rate. This mirrors how SQS reports the two.
  double? priceImpactPercent;
  final effective = _ratioOf(
    BigInt.parse(amount),
    _parseAmount(params.tokenInAmount, 'tokenInAmount'),
  );
  if (spotPrice != null && effective != null && spotProduct > 0) {
    final expected = spotProduct * (anyFee ? survivingValue : 1);
    if (expected > 0) priceImpactPercent = (1 - effective / expected) * 100;
  } else {
    // Null, not 0: "no impact" and "impact unknown" are different claims and
    // only one of them is true here.
    warnings.add('Spot price unavailable, so price impact is not reported.');
  }

  return _PoolmanagerQuote(
    outAmount: amount,
    legs: legs,
    spotPrice: spotPrice,
    feeFraction: feeFraction,
    priceImpactPercent: priceImpactPercent,
    warnings: warnings,
  );
}

/// Price a swap on Osmosis.
///
/// Venue selection, in order:
/// 1. [OsmosisSwapQuoteParams.router] present — ask the SQS router.
/// 2. No router but a [OsmosisSwapQuoteParams.route] — chain single-pool
///    poolmanager estimates along it.
/// 3. Neither — search [OsmosisSwapQuoteParams.candidatePoolIds] for a direct
///    pool. Fails with `noRoute` if none were supplied, because the chain
///    cannot search for pools by denom.
///
/// `minReceived` is always derived here from the tolerance; neither venue
/// applies one for us. It is a floor for the caller to enforce — this package
/// does not sign, so nothing here can bind the chain to it.
Future<OsmosisSwapQuote> quoteOsmosisSwap(
  OsmosisSwapQuoteParams params,
  LcdClient lcd,
) async {
  _assertOsmosisChain(lcd, params);

  if (params.tokenInDenom.isEmpty) {
    throw _invalidRequest('tokenInDenom is required');
  }
  if (params.tokenOutDenom.isEmpty) {
    throw _invalidRequest('tokenOutDenom is required');
  }
  if (params.tokenInDenom == params.tokenOutDenom) {
    throw _invalidRequest('tokenInDenom and tokenOutDenom are both '
        '${params.tokenInDenom}; there is nothing to swap');
  }
  final amount = _parseAmount(params.tokenInAmount, 'tokenInAmount');
  if (amount == BigInt.zero) {
    throw _invalidRequest('tokenInAmount must be greater than zero');
  }
  final slippagePercent = params.slippagePercent ?? kDefaultSlippagePercent;
  _scalePercent(slippagePercent, 'slippagePercent');

  final route = params.route;
  if (route != null) {
    if (route.isEmpty) throw _invalidRequest('route was supplied but is empty');
    if (route.last.tokenOutDenom != params.tokenOutDenom) {
      throw _invalidRequest('route ends in ${route.last.tokenOutDenom}, not '
          '${params.tokenOutDenom}');
    }
  }

  final warnings = <String>[];
  OsmosisSwapQuote quote;

  final router = params.router;
  if (router != null) {
    final result = await _quoteViaRouter(params, router);
    final best = _largestSplit(result.splits);
    if (result.splits.length > 1) {
      warnings.add('Router split this order across ${result.splits.length} '
          'routes; the route shown is the largest one.');
    }
    // SQS signs price impact so that a trade moving the price against the user
    // is negative. Ours is a cost, so it is positive here; flip the sign rather
    // than take an absolute value, so a rare favourable quote still reads as
    // favourable.
    final impactFraction = result.priceImpactFraction == null
        ? null
        : double.tryParse(result.priceImpactFraction!);
    final feeFraction = result.effectiveFeeFraction == null
        ? null
        : double.tryParse(result.effectiveFeeFraction!);
    if (result.effectiveFeeFraction == null) {
      warnings.add('The router did not report a fee, so it is not shown.');
    }
    quote = OsmosisSwapQuote(
      inputDenom: params.tokenInDenom,
      inputAmount: params.tokenInAmount,
      outputDenom: params.tokenOutDenom,
      outputAmount: result.outAmount,
      priceImpact: impactFraction == null || !impactFraction.isFinite
          ? null
          : -impactFraction * 100,
      poolFee: feeFraction == null || !feeFraction.isFinite
          ? null
          : feeFraction * 100,
      minReceived: applySlippage(result.outAmount, slippagePercent),
      slippagePercent: slippagePercent,
      route: best == null ? const [] : _toSwapPoolHops(best.pools),
      source: OsmosisQuoteSource.router,
      splits: result.splits,
      spotPrice: result.spotPrice,
      effectiveFeeFraction: result.effectiveFeeFraction,
      warnings: warnings,
      fetchedAt: DateTime.now(),
    );
  } else {
    final legs = route != null
        ? _routeFromHops(params.tokenInDenom, route)
        : await _findDirectRoute(params, lcd);
    if (legs.isEmpty) {
      throw InterchainError(
        InterchainErrorCode.noRoute,
        'No Osmosis pool found for ${params.tokenInDenom} -> '
        '${params.tokenOutDenom} among the supplied candidates',
        chainId: lcd.chainId,
      );
    }
    final priced = await _quoteViaPoolmanager(legs, params, lcd);
    final feeFraction = priced.feeFraction == null
        ? null
        : double.tryParse(priced.feeFraction!);
    quote = OsmosisSwapQuote(
      inputDenom: params.tokenInDenom,
      inputAmount: params.tokenInAmount,
      outputDenom: params.tokenOutDenom,
      outputAmount: priced.outAmount,
      priceImpact: priced.priceImpactPercent,
      poolFee: feeFraction == null || !feeFraction.isFinite
          ? null
          : feeFraction * 100,
      minReceived: applySlippage(priced.outAmount, slippagePercent),
      slippagePercent: slippagePercent,
      route: _toSwapPoolHops(priced.legs),
      source: OsmosisQuoteSource.poolmanager,
      splits: [
        OsmosisRouteSplit(
          pools: priced.legs,
          inAmount: params.tokenInAmount,
          outAmount: priced.outAmount,
        ),
      ],
      spotPrice: priced.spotPrice,
      effectiveFeeFraction: priced.feeFraction,
      warnings: [...warnings, ...priced.warnings],
      fetchedAt: DateTime.now(),
    );
  }

  final floor = params.minOutputAmount;
  if (floor != null) {
    final minimum = _parseAmount(floor, 'minOutputAmount');
    if (BigInt.parse(quote.outputAmount) < minimum) {
      throw InterchainError(
        InterchainErrorCode.slippageExceeded,
        'Osmosis quoted ${quote.outputAmount} ${params.tokenOutDenom}, below '
        'the requested minimum of $floor',
        chainId: lcd.chainId,
      );
    }
  }

  return quote;
}

/// Turn a caller's hop list into a route with per-leg input denoms.
///
/// A [SwapPoolHop] only names the denom leaving each pool, so each leg's input
/// is the previous leg's output.
List<OsmosisRouteLeg> _routeFromHops(
  String tokenInDenom,
  List<SwapPoolHop> hops,
) {
  final legs = <OsmosisRouteLeg>[];
  var inDenom = tokenInDenom;
  for (final hop in hops) {
    legs.add(OsmosisRouteLeg(
      poolId: hop.poolId,
      tokenInDenom: inDenom,
      tokenOutDenom: hop.tokenOutDenom,
    ));
    inDenom = hop.tokenOutDenom;
  }
  return legs;
}

/// Cap on candidate routes evaluated by the LCD-only search.
const int kOsmosisMaxRoutes = _defaultMaxRoutes;
