/// The route the deployed crosschain-swaps contract will actually execute.
///
/// Dart mirror of `xcs-route.ts` in `@zunialab/interchain`. Osmosis SQS can
/// price a path the swaprouter contract has never been told about; the
/// contract then rejects the packet (`No route found`) and the escrow sends
/// the funds back. A quote that ignores the contract's table shows a price for
/// a swap that cannot happen.
///
/// Crosschain-swaps v1.2 stores the swaprouter address under the raw key
/// `config` and executes `swap_contract.get_route`. It does not accept a route
/// in the memo, so a path SQS invented cannot be injected at sign time. The
/// only honest quote is the one `get_route` returns.
library;

import 'dart:convert';

import 'lcd.dart';
import 'types.dart';

/// What [readXcsExecutableRoute] found.
sealed class XcsRouteRead {
  const XcsRouteRead();
}

/// The router has the pair, along [route].
final class XcsRouteReady extends XcsRouteRead {
  const XcsRouteReady({required this.swapContract, required this.route});
  final String swapContract;
  final List<SwapPoolHop> route;
}

/// The router's table has no entry for the pair.
final class XcsRouteMissing extends XcsRouteRead {
  const XcsRouteMissing({this.swapContract});
  final String? swapContract;
}

/// The check itself failed: nobody knows.
final class XcsRouteUnreadable extends XcsRouteRead {
  const XcsRouteUnreadable();
}

Map<String, Object?>? _record(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// Bech32-ish, without the checksum: the engine's own pre-query check.
bool looksLikeContractAddress(String value) =>
    RegExp(r'^[a-z0-9]+1[a-z0-9]{20,}$').hasMatch(value);

/// `swap_contract` from a crosschain-swaps `config` value, or null when the
/// body is not that config.
String? parseXcsSwapContract(Object? data) {
  final row = _record(data);
  final address = row?['swap_contract'];
  if (address is! String || !looksLikeContractAddress(address)) return null;
  return address;
}

/// `pool_route` from a swaprouter `get_route` reply, or null when the reply is
/// not a non-empty route whose last hop pays [outputDenom].
List<SwapPoolHop>? parseXcsPoolRoute(Object? data, String outputDenom) {
  final rows = _record(data)?['pool_route'];
  if (rows is! List || rows.isEmpty) return null;
  final hops = <SwapPoolHop>[];
  for (final row in rows) {
    final hop = _record(row);
    if (hop == null) return null;
    final raw = hop['pool_id'];
    final id = raw is int ? '$raw' : raw;
    final out = hop['token_out_denom'];
    if (id is! String || !RegExp(r'^[1-9]\d*$').hasMatch(id)) return null;
    if (out is! String || out.isEmpty) return null;
    hops.add(SwapPoolHop(poolId: id, tokenOutDenom: out));
  }
  if (hops.last.tokenOutDenom != outputDenom) return null;
  return hops;
}

/// A raw or smart query's `data`: base64 JSON on the wire, already parsed on
/// some gateways.
Object? contractQueryData(Object? body, String chainId) {
  final row = _record(body);
  if (row == null || !row.containsKey('data')) {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      '$chainId: contract query has no data',
      chainId: chainId,
    );
  }
  final data = row['data'];
  if (data is String) {
    try {
      return jsonDecode(utf8.decode(base64.decode(data)));
    } on FormatException catch (error) {
      throw InterchainError(
        InterchainErrorCode.malformedResponse,
        '$chainId: contract query data is not base64 JSON',
        chainId: chainId,
        cause: error,
      );
    }
  }
  if (data == null) {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      '$chainId: contract query returned empty data',
      chainId: chainId,
    );
  }
  return data;
}

/// `/cosmwasm/wasm/v1/contract/{addr}/raw/{base64("config")}`: the key is the
/// raw bytes of the word `config`, not a JSON string.
String xcsConfigPath(String contract) =>
    '/cosmwasm/wasm/v1/contract/${Uri.encodeComponent(contract)}/raw/'
    '${Uri.encodeComponent(base64.encode(utf8.encode('config')))}';

String xcsRouteQueryPath(String router, String input, String output) {
  final query = jsonEncode({
    'get_route': {'input_denom': input, 'output_denom': output},
  });
  final encoded = base64Url.encode(utf8.encode(query)).replaceAll('=', '');
  return '/cosmwasm/wasm/v1/contract/${Uri.encodeComponent(router)}/smart/$encoded';
}

/// Read the route the crosschain-swaps contract will execute for this pair.
///
/// Never invents a path. [XcsRouteMissing] means the swaprouter answered for
/// the pair and has no entry; [XcsRouteUnreadable] means the check itself
/// failed. Rethrows `aborted` and `readsDisabled` so a reads-off setting keeps
/// its own copy.
///
/// wasmd answers a missing entry with an HTTP error (500,
/// `Vec<SwapAmountInRoute> not found`); this client keeps the status, not the
/// body, so any HTTP answer from the router after its config was read counts
/// as missing, and only a transport failure as unreadable. Both refuse the
/// swap; they differ only in the sentence shown.
Future<XcsRouteRead> readXcsExecutableRoute(
  LcdClient lcd,
  String xcsContract,
  String inputDenom,
  String outputDenom,
) async {
  final contract = xcsContract.trim();
  if (!looksLikeContractAddress(contract) ||
      inputDenom.isEmpty ||
      outputDenom.isEmpty) {
    return const XcsRouteUnreadable();
  }
  const options = LcdRequestOptions(
    timeout: Duration(seconds: 8),
    cacheTtl: Duration(seconds: 60),
  );

  String? router;
  try {
    router = parseXcsSwapContract(
      contractQueryData(
        await lcd.getJson(xcsConfigPath(contract), options),
        lcd.chainId,
      ),
    );
  } on InterchainError catch (error) {
    if (error.code == InterchainErrorCode.aborted ||
        error.code == InterchainErrorCode.readsDisabled) {
      rethrow;
    }
    return const XcsRouteUnreadable();
  }
  if (router == null) return const XcsRouteUnreadable();

  try {
    final body = await lcd.getJson(
      xcsRouteQueryPath(router, inputDenom, outputDenom),
      options,
    );
    final route = parseXcsPoolRoute(
      contractQueryData(body, lcd.chainId),
      outputDenom,
    );
    if (route == null) return XcsRouteMissing(swapContract: router);
    return XcsRouteReady(swapContract: router, route: route);
  } on InterchainError catch (error) {
    if (error.code == InterchainErrorCode.aborted ||
        error.code == InterchainErrorCode.readsDisabled) {
      rethrow;
    }
    final text = error.message.toLowerCase();
    if (error.httpStatus != null ||
        text.contains('not found') ||
        text.contains('no route')) {
      return XcsRouteMissing(swapContract: router);
    }
    return const XcsRouteUnreadable();
  }
}
