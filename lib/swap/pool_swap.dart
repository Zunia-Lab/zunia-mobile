/// Swaps on Osmosis's own pools, with no contract in between.
///
/// Port of zunia-extension 0.1.5 `lib/pool-swap.ts`. The crosschain-swaps
/// contract executes only the pairs in its swaprouter's table. Osmosis's
/// poolmanager module swaps any pair its pools connect, and the Osmosis router
/// (SQS) finds the best route, split across several when that pays more. So
/// when the funds are already on Osmosis, Zunia signs poolmanager's own
/// message for the router's route:
///
/// - `MsgSwapExactAmountIn` for one route;
/// - `MsgSplitRouteSwapExactAmountIn` when the router splits the order.
///
/// Both carry `token_out_min_amount`. The chain refuses the whole transaction
/// when the swap would pay less, so the floor is a number in the signed
/// message (the quote's output less the slippage), and a new price is a new
/// message, built and previewed again.
///
/// poolmanager pays the output to the signer. A token wanted on another chain
/// is sent on in the same transaction: an ICS20 transfer of exactly the
/// floor. The swap pays at least the floor, so the transfer always has it to
/// send; whatever the swap pays above it stays in the signer's Osmosis
/// account. If the swap pays less, the chain refuses everything, the fee and
/// the transfer included. Nothing here signs.
library;

import 'package:flutter/foundation.dart';

import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/swap.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

const String poolSwapTypeUrl =
    '/osmosis.poolmanager.v1beta1.MsgSwapExactAmountIn';
const String poolSplitSwapTypeUrl =
    '/osmosis.poolmanager.v1beta1.MsgSplitRouteSwapExactAmountIn';
const String transferTypeUrl = '/ibc.applications.transfer.v1.MsgTransfer';

/// Pools one route may pass through. The router's longest routes are three or
/// four pools; a route this long is not one it returns.
const int maxPoolHops = 8;

/// Routes one order may be split across. The router splits into two to four.
const int maxPoolSplits = 16;

final RegExp _positive = RegExp(r'^[1-9]\d*$');

/// The Cosmos SDK's own denom rule.
final RegExp _denomRule = RegExp(r'^[a-zA-Z][a-zA-Z0-9/:._-]{2,127}$');

bool isPoolDenom(String denom) => _denomRule.hasMatch(denom);

/* -------------------------------------------------------------------------- *
 * Routes
 * -------------------------------------------------------------------------- */

/// One pool on a route, and the denom it pays out.
@immutable
class PoolHop {
  const PoolHop(this.poolId, this.tokenOutDenom);

  final String poolId;
  final String tokenOutDenom;

  @override
  bool operator ==(Object other) =>
      other is PoolHop &&
      other.poolId == poolId &&
      other.tokenOutDenom == tokenOutDenom;

  @override
  int get hashCode => Object.hash(poolId, tokenOutDenom);

  @override
  String toString() => 'PoolHop($poolId -> $tokenOutDenom)';
}

/// One route of an order: its pools in order, and the input it takes.
@immutable
class PoolRoute {
  const PoolRoute(this.hops, this.inAmount);

  final List<PoolHop> hops;

  /// Base units of the input this route swaps. All routes add up to the whole.
  final String inAmount;

  @override
  bool operator ==(Object other) =>
      other is PoolRoute &&
      other.inAmount == inAmount &&
      listEquals(other.hops, hops);

  @override
  int get hashCode => Object.hash(Object.hashAll(hops), inAmount);

  @override
  String toString() => 'PoolRoute($hops, $inAmount)';
}

/// The problems with a set of routes for selling [amountIn] into
/// [outputDenom], in the chain's own terms; null when they are a valid order.
String? _routeProblem(
  List<PoolRoute> routes,
  String amountIn,
  String outputDenom,
) {
  if (!_positive.hasMatch(amountIn)) {
    return 'the amount is not a positive integer';
  }
  if (routes.isEmpty) return 'there is no route';
  if (routes.length > maxPoolSplits) {
    return 'the order is split ${routes.length} ways';
  }
  var total = BigInt.zero;
  final seen = <String>{};
  for (final route in routes) {
    if (route.hops.isEmpty) return 'a route has no pool';
    if (route.hops.length > maxPoolHops) {
      return 'a route passes ${route.hops.length} pools';
    }
    for (final hop in route.hops) {
      if (!_positive.hasMatch(hop.poolId)) {
        return 'pool id ${hop.poolId} is not a pool id';
      }
      if (!_denomRule.hasMatch(hop.tokenOutDenom)) {
        return '${hop.tokenOutDenom} is not a denom';
      }
    }
    if (route.hops.last.tokenOutDenom != outputDenom) {
      return 'a route ends in another token than $outputDenom';
    }
    if (!_positive.hasMatch(route.inAmount)) return 'a route takes no input';
    total += BigInt.parse(route.inAmount);
    final key = route.hops.map((hop) => hop.poolId).join('>');
    if (!seen.add(key)) return 'two routes pass the same pools';
  }
  if (total != BigInt.parse(amountIn)) {
    return 'the routes do not add up to the amount';
  }
  return null;
}

/// The router's routes for [quote], as poolmanager takes them. Null when they
/// are not a valid order for exactly [amountIn] of the quote's input: a split
/// that does not add up would sell another amount than the one reviewed.
List<PoolRoute>? poolRoutesOf(OsmosisSwapQuote quote, String amountIn) {
  final routes = [
    for (final split in quote.splits)
      PoolRoute([
        for (final pool in split.pools)
          PoolHop(pool.poolId, pool.tokenOutDenom),
      ], split.inAmount),
  ];
  return _routeProblem(routes, amountIn, quote.outputDenom) == null
      ? routes
      : null;
}

/// The least the swap may pay out: the quote's output less [slippagePercent],
/// rounded down. Null when that is nothing: a floor of 0 is no floor.
String? poolMinOut(String outputAmount, double slippagePercent) {
  try {
    final floor = applySlippage(outputAmount, slippagePercent);
    return _positive.hasMatch(floor) ? floor : null;
  } on Object {
    return null;
  }
}

/// The routes in words: `pool 3586`, `pools 3497 → 1464`, or
/// `2 routes: pool 3498 (60%) and pool 3586 (40%)`.
String poolRouteText(List<PoolRoute> routes) {
  String one(PoolRoute route) => route.hops.length == 1
      ? 'pool ${route.hops.first.poolId}'
      : 'pools ${route.hops.map((hop) => hop.poolId).join(' → ')}';
  if (routes.length == 1) return one(routes.first);
  final total = routes.fold<BigInt>(
    BigInt.zero,
    (sum, r) => sum + BigInt.parse(r.inAmount),
  );
  String share(PoolRoute route) {
    if (total <= BigInt.zero) return '';
    final permille = (BigInt.parse(route.inAmount) * BigInt.from(1000) ~/ total)
        .toInt();
    final whole = permille % 10 == 0;
    return ' (${whole ? '${permille ~/ 10}' : (permille / 10).toStringAsFixed(1)}%)';
  }

  final parts = [for (final route in routes) '${one(route)}${share(route)}'];
  return '${routes.length} routes: ${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

/* -------------------------------------------------------------------------- *
 * The message
 * -------------------------------------------------------------------------- */

/// The poolmanager message selling [denom] along [routes] for at least
/// [minOut]: `MsgSwapExactAmountIn` for one route, which takes the whole input
/// as `token_in`; `MsgSplitRouteSwapExactAmountIn` for several, each with its
/// share as `token_in_amount`. Throws on routes that are not a valid order.
TxMsg buildPoolSwapMsg({
  required String sender,
  required String denom,
  required List<PoolRoute> routes,
  required String minOut,
}) {
  final amount = routes
      .fold<BigInt>(
        BigInt.zero,
        (sum, route) => sum + (BigInt.tryParse(route.inAmount) ?? BigInt.zero),
      )
      .toString();
  final outputDenom = routes.isEmpty || routes.first.hops.isEmpty
      ? ''
      : routes.first.hops.last.tokenOutDenom;
  final problem = _routeProblem(routes, amount, outputDenom);
  if (problem != null) {
    throw ArgumentError('Zunia will not build this swap: $problem.');
  }
  if (!_denomRule.hasMatch(denom)) {
    throw ArgumentError(
      'Zunia will not build this swap: $denom is not a denom.',
    );
  }
  if (!_positive.hasMatch(minOut)) {
    throw ArgumentError(
      'Zunia will not build a swap without a minimum output.',
    );
  }
  List<Map<String, String>> pools(PoolRoute route) => [
    for (final hop in route.hops)
      {'pool_id': hop.poolId, 'token_out_denom': hop.tokenOutDenom},
  ];
  if (routes.length == 1) {
    final only = routes.first;
    return TxMsg(poolSwapTypeUrl, {
      'sender': sender,
      'routes': pools(only),
      'token_in': {'denom': denom, 'amount': only.inAmount},
      'token_out_min_amount': minOut,
    });
  }
  return TxMsg(poolSplitSwapTypeUrl, {
    'sender': sender,
    'routes': [
      for (final route in routes)
        {'pools': pools(route), 'token_in_amount': route.inAmount},
    ],
    'token_in_denom': denom,
    'token_out_min_amount': minOut,
  });
}

/// A coin exactly as a message carries it.
@immutable
class PoolCoin {
  const PoolCoin(this.denom, this.amount);
  final String denom;
  final String amount;

  @override
  bool operator ==(Object other) =>
      other is PoolCoin && other.denom == denom && other.amount == amount;

  @override
  int get hashCode => Object.hash(denom, amount);
}

/// A poolmanager swap, read from the message that is signed.
@immutable
class PoolSwapFacts {
  const PoolSwapFacts({
    required this.split,
    required this.sender,
    required this.sold,
    required this.outputDenom,
    required this.minOut,
    required this.routes,
  });

  final bool split;
  final String sender;

  /// The input denom, and every route's input added up.
  final PoolCoin sold;
  final String outputDenom;

  /// `token_out_min_amount`: below it the chain refuses the transaction.
  final String minOut;
  final List<PoolRoute> routes;
}

bool _hasKeys(Map<dynamic, dynamic> value, List<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);

List<PoolHop>? _readHops(Object? raw) {
  if (raw is! List) return null;
  final hops = <PoolHop>[];
  for (final entry in raw) {
    if (entry is! Map ||
        !_hasKeys(entry, const ['pool_id', 'token_out_denom'])) {
      return null;
    }
    final poolId = entry['pool_id'];
    final out = entry['token_out_denom'];
    if (poolId is! String || out is! String) return null;
    hops.add(PoolHop(poolId, out));
  }
  return hops;
}

/// Read a poolmanager swap from the message that is signed. Null for any
/// other message, and for one with a field this reader does not know, a
/// number that is not canonical, or routes that are not a valid order: what
/// cannot be read whole is never described, and never signed.
PoolSwapFacts? readPoolSwapMsg(TxMsg? msg) {
  if (msg == null) return null;
  final value = msg.value;
  final sender = value['sender'];
  final minOut = value['token_out_min_amount'];
  if (sender is! String || sender.isEmpty) return null;
  if (minOut is! String || !_positive.hasMatch(minOut)) return null;

  final List<PoolRoute> routes;
  final Object? denom;
  if (msg.typeUrl == poolSwapTypeUrl) {
    if (!_hasKeys(value, const [
      'sender',
      'routes',
      'token_in',
      'token_out_min_amount',
    ])) {
      return null;
    }
    final tokenIn = value['token_in'];
    if (tokenIn is! Map || !_hasKeys(tokenIn, const ['denom', 'amount'])) {
      return null;
    }
    final hops = _readHops(value['routes']);
    final amount = tokenIn['amount'];
    if (hops == null || amount is! String) return null;
    denom = tokenIn['denom'];
    routes = [PoolRoute(hops, amount)];
  } else if (msg.typeUrl == poolSplitSwapTypeUrl) {
    if (!_hasKeys(value, const [
      'sender',
      'routes',
      'token_in_denom',
      'token_out_min_amount',
    ])) {
      return null;
    }
    final raw = value['routes'];
    if (raw is! List) return null;
    final read = <PoolRoute>[];
    for (final entry in raw) {
      if (entry is! Map ||
          !_hasKeys(entry, const ['pools', 'token_in_amount'])) {
        return null;
      }
      final hops = _readHops(entry['pools']);
      final amount = entry['token_in_amount'];
      if (hops == null || amount is! String) return null;
      read.add(PoolRoute(hops, amount));
    }
    routes = read;
    denom = value['token_in_denom'];
  } else {
    return null;
  }
  if (denom is! String || !_denomRule.hasMatch(denom)) return null;
  final outputDenom = routes.isEmpty || routes.first.hops.isEmpty
      ? ''
      : routes.first.hops.last.tokenOutDenom;
  final amount = routes.fold<BigInt>(
    BigInt.zero,
    (sum, route) => _positive.hasMatch(route.inAmount)
        ? sum + BigInt.parse(route.inAmount)
        : sum,
  );
  if (_routeProblem(routes, amount.toString(), outputDenom) != null) {
    return null;
  }
  return PoolSwapFacts(
    split: msg.typeUrl == poolSplitSwapTypeUrl,
    sender: sender,
    sold: PoolCoin(denom, amount.toString()),
    outputDenom: outputDenom,
    minOut: minOut,
    routes: routes,
  );
}

/// Whether two sets of routes are the same order, pool for pool and amount
/// for amount.
bool sameRoutes(List<PoolRoute> a, List<PoolRoute> b) => listEquals(a, b);

/// An ICS20 transfer that sends a swap's output on, read from the message.
@immutable
class DeliveryTransferFacts {
  const DeliveryTransferFacts({
    required this.sourcePort,
    required this.sourceChannel,
    required this.token,
    required this.sender,
    required this.receiver,
    required this.memo,
    required this.timeoutTimestamp,
  });

  final String sourcePort;
  final String sourceChannel;
  final PoolCoin token;
  final String sender;
  final String receiver;
  final String memo;

  /// Nanoseconds since the epoch, digits; `0` when the transfer sets none.
  final String timeoutTimestamp;
}

const Set<String> _transferKeys = {
  'source_port',
  'source_channel',
  'token',
  'sender',
  'receiver',
  'timeout_height',
  'timeout_timestamp',
  'memo',
};

/// Read the transfer a `pool-deliver` swap signs after the swap; null for
/// anything else.
DeliveryTransferFacts? readDeliveryTransfer(TxMsg? msg) {
  if (msg == null || msg.typeUrl != transferTypeUrl) return null;
  final value = msg.value;
  if (!value.keys.every(_transferKeys.contains)) return null;
  final port = value['source_port'];
  final channel = value['source_channel'];
  final sender = value['sender'];
  final receiver = value['receiver'];
  final memo = value['memo'] ?? '';
  if (port is! String ||
      channel is! String ||
      sender is! String ||
      receiver is! String ||
      memo is! String) {
    return null;
  }
  final token = value['token'];
  if (token is! Map || !_hasKeys(token, const ['denom', 'amount'])) return null;
  final denom = token['denom'];
  final amount = token['amount'];
  if (denom is! String || amount is! String || !_positive.hasMatch(amount)) {
    return null;
  }
  // A height timeout, when present, is the two counters and nothing else.
  final height = value['timeout_height'];
  if (height != null) {
    if (height is! Map ||
        !height.keys.every(
          (k) => k == 'revision_number' || k == 'revision_height',
        )) {
      return null;
    }
    if (!height.values.every(
      (part) => part is String && RegExp(r'^\d+$').hasMatch(part),
    )) {
      return null;
    }
  }
  final raw = value['timeout_timestamp'];
  final timeout = raw ?? '0';
  if (timeout is! String || !RegExp(r'^\d+$').hasMatch(timeout)) return null;
  return DeliveryTransferFacts(
    sourcePort: port,
    sourceChannel: channel,
    token: PoolCoin(denom, amount),
    sender: sender,
    receiver: receiver,
    memo: memo,
    timeoutTimestamp: timeout,
  );
}

/* -------------------------------------------------------------------------- *
 * Pricing
 * -------------------------------------------------------------------------- */

/// Why a pool swap has no price, so a screen can word it with the tickers.
enum PoolQuoteBlockedCode { sameToken, noPoolRoute, routesInvalid, noFloor }

/// A price in Osmosis's pools and the order it makes, or why there is none.
@immutable
class PoolQuote {
  const PoolQuote({
    this.quote,
    this.routes,
    this.minOut,
    this.error,
    this.code,
  });

  final OsmosisSwapQuote? quote;

  /// The router's routes for exactly the amount sold.
  final List<PoolRoute>? routes;

  /// The floor at the slippage asked: what the message will say.
  final String? minOut;
  final String? error;
  final PoolQuoteBlockedCode? code;

  bool get ready => quote != null && routes != null && minOut != null;
}

const String _noPoolRoute =
    'Osmosis has no pool route for this pair at this amount, so there is nothing to sign.';
const String _routesInvalid =
    "The Osmosis router's routes for this swap do not add up to the amount you sell, so Zunia will not sign them.";
const String _noFloor =
    'At this amount the swap would pay out so little that its minimum rounds to nothing, so Zunia will not sign it.';

/// Price selling [amountBaseUnits] of [venueInputDenom] for
/// [venueOutputDenom] in Osmosis's pools, along the router's best route, and
/// work out the order and the floor the message will carry.
Future<PoolQuote> quotePoolSwap({
  required String venueInputDenom,
  required String venueOutputDenom,
  required String amountBaseUnits,
  required double slippagePercent,
  required LcdClient venueLcd,
  required LcdClient router,
  String Function(InterchainError error)? describe,
}) async {
  if (venueInputDenom == venueOutputDenom) {
    return const PoolQuote(
      error:
          'Both sides are the same token on Osmosis, so there is nothing to swap.',
      code: PoolQuoteBlockedCode.sameToken,
    );
  }
  if (!_denomRule.hasMatch(venueInputDenom) ||
      !_denomRule.hasMatch(venueOutputDenom)) {
    return const PoolQuote(
      error:
          'Zunia could not name both tokens on Osmosis, so it will not put a guessed denom in the swap.',
    );
  }
  OsmosisSwapQuote quote;
  try {
    quote = await quoteOsmosisSwap(
      OsmosisSwapQuoteParams(
        tokenInDenom: venueInputDenom,
        tokenInAmount: amountBaseUnits,
        tokenOutDenom: venueOutputDenom,
        slippagePercent: slippagePercent,
        router: router,
      ),
      venueLcd,
    );
  } on InterchainError catch (error) {
    if (error.code == InterchainErrorCode.noRoute) {
      return const PoolQuote(
        error: _noPoolRoute,
        code: PoolQuoteBlockedCode.noPoolRoute,
      );
    }
    return PoolQuote(error: describe?.call(error) ?? error.message);
  }
  final routes = poolRoutesOf(quote, amountBaseUnits);
  if (routes == null) {
    return PoolQuote(
      quote: quote,
      error: _routesInvalid,
      code: PoolQuoteBlockedCode.routesInvalid,
    );
  }
  final minOut = poolMinOut(quote.outputAmount, slippagePercent);
  if (minOut == null) {
    return PoolQuote(
      quote: quote,
      error: _noFloor,
      code: PoolQuoteBlockedCode.noFloor,
    );
  }
  return PoolQuote(quote: quote, routes: routes, minOut: minOut);
}
