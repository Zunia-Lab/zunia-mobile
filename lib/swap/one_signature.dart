/// One signature for a swap whose tokens sit on another chain than Osmosis.
///
/// The crosschain-swaps contract swaps only the pairs its route table holds
/// (39 on 2026-10-05), so every other pair held off Osmosis used to take two
/// steps: move the tokens to Osmosis, then swap there, with OSMO for the fee.
/// Skip Go's entry point takes the pools to swap through in the message
/// itself, so any pair Osmosis's router prices goes in one transfer signed on
/// the chain holding the funds:
///
/// 1. an ICS20 transfer of the amount sold to Osmosis, addressed to the entry
///    point, whose memo is a `wasm` call (ibc-hooks runs it on arrival);
/// 2. on Osmosis the entry point swaps along the router's route
///    (`swap_exact_asset_in` through the poolmanager adapter) and refuses to
///    pay less than the minimum;
/// 3. it pays the output to the user's Osmosis address, or sends it on over
///    one direct channel to the user's address on the To's chain.
///
/// When the swap fails on Osmosis (the price moved past the minimum, the swap
/// window closed), the call errors, the packet is acknowledged with an error
/// and the source chain refunds the transfer. When the delivery after the
/// swap fails, the IBC adapter pays the output to `recover_address`, the
/// user's Osmosis address.
///
/// The contracts are immutable (no admin), from
/// skip-mev/skip-go-cosmwasm-contracts `deployed-contracts/osmosis/mainnet.toml`
/// at commit e2bffe67. The entry point is checked on chain (code id, label, no
/// admin) before this path is offered. Simulated against osmosis-1 on
/// 2026-11-06: SAF to allUSDC through pool 3600 paid on Osmosis, and allUSDC to
/// SAF sent back to Safrochain over channel-110497.
///
/// Pure: no network, no clock. Nothing here signs.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/swap/pool_swap.dart';
import 'package:zunia_mobile/swap/swap_assets.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';

/// Skip Go's entry point on osmosis-1: what the transfer is addressed to and
/// what its memo calls.
const String kSkipEntryPoint =
    'osmo10a3k4hvk37cc4hnxctw4p95fhscd2z6h2rmx0aukc6rm8u9qqx9smfsh7u';

/// The entry point's code and label on osmosis-1, checked before any swap is
/// offered through it.
const String kSkipEntryPointCodeId = '1241';
const String kSkipEntryPointLabel = 'Skip Swap Entry Point';

/// The adapters the entry point calls: the poolmanager swap adapter (code
/// 1240) and the IBC transfer adapter (code 1239), which sends the delivery.
const String kSkipPoolmanagerAdapter =
    'osmo1xzphwrc9aahmq7smwaggukwx5w2w8mmtqf5mk0ky0v6hh75paxsszfnlu5';
const String kSkipIbcTransferAdapter =
    'osmo1m8wg4vxkefhs374qxmmqpyusgz289wmulex5qdwpfx7jnrxzer5s9cv83q';

/// The swap venue the entry point routes `osmosis-poolmanager` operations to.
const String kSkipSwapVenue = 'osmosis-poolmanager';

/// How long the ICS20 packet may take to reach Osmosis.
const int entryPointPacketTimeoutMinutes = 10;

/// How long after signing the entry point still swaps: longer than the packet
/// timeout, so a packet that arrives is never refused for the clock alone.
const int entryPointSwapWindowMinutes = 15;

/* -------------------------------------------------------------------------- *
 * The entry point, checked on chain
 * -------------------------------------------------------------------------- */

/// What the chain says about the entry point.
@immutable
class EntryPointCheck {
  const EntryPointCheck._({required this.ready, required this.reason});

  const EntryPointCheck.ready() : this._(ready: true, reason: null);

  const EntryPointCheck.unavailable(String reason)
    : this._(ready: false, reason: reason);

  final bool ready;

  /// Why one-signature swaps are off. Null only when [ready].
  final String? reason;
}

/// Said when the entry point on chain is not the contract this release was
/// built against.
const String entryPointMismatch =
    "The swap contract on Osmosis is not the one this release checked (code, label or admin differ), so one-signature swaps stay off.";

/// The verdict on a `/cosmwasm/wasm/v1/contract/{address}` body: the entry
/// point is the one named here only with its code id, its label and no admin
/// (an admin could replace its code).
EntryPointCheck readEntryPointInfo(Object? body) {
  final info = body is Map ? body['contract_info'] : null;
  if (info is! Map) return const EntryPointCheck.unavailable(entryPointMismatch);
  final codeId = info['code_id'];
  final label = info['label'];
  final admin = info['admin'];
  final codeOk = '$codeId' == kSkipEntryPointCodeId;
  final labelOk = label is String && label.trim() == kSkipEntryPointLabel;
  final adminOk = admin == null || (admin is String && admin.trim().isEmpty);
  return codeOk && labelOk && adminOk
      ? const EntryPointCheck.ready()
      : const EntryPointCheck.unavailable(entryPointMismatch);
}

/* -------------------------------------------------------------------------- *
 * Reaching Osmosis, and leaving it
 * -------------------------------------------------------------------------- */

String _key(String denom) =>
    denom.startsWith('ibc/') ? denom.toUpperCase() : denom;

bool _oneHop(String path) => path.split('/').length == 2;

/// The transfer that brings the From to Osmosis as the denom the pools trade:
/// the channel on the From's chain, and what arrives.
@immutable
class VenueInbound {
  const VenueInbound({
    required this.channelId,
    required this.arrivalDenom,
    this.port = transferPort,
  });

  /// The channel on the From's chain.
  final String channelId;
  final String port;

  /// What lands on Osmosis: the From's `osmosisDenom`.
  final String arrivalDenom;

  @override
  bool operator ==(Object other) =>
      other is VenueInbound &&
      other.channelId == channelId &&
      other.port == port &&
      other.arrivalDenom == arrivalDenom;

  @override
  int get hashCode => Object.hash(channelId, port, arrivalDenom);
}

/// The one canonical hop from [from]'s chain to Osmosis that lands as its
/// Osmosis denom, from the hash-verified table; null when there is none (a
/// voucher that would arrive as a voucher of a voucher, a token Osmosis does
/// not list). Two shapes:
/// - a token Osmosis lists as its one-hop voucher from [from]'s chain (SAF on
///   Safrochain arrives as `transfer/channel-110497/usaf`): it leaves over the
///   counterparty of Osmosis's channel (Safrochain channel-1);
/// - a voucher on [from]'s chain whose one hop back is Osmosis (OSMO held on
///   another chain): unwinding it delivers its origin denom.
VenueInbound? venueInboundOf(
  SwapAsset from,
  SwapTokenBook book, {
  String venueChainId = kOsmosisChainId,
}) {
  if (from.chainId == venueChainId) return null;
  final arrival = from.identity.osmosisDenom;
  if (arrival == null || arrival.isEmpty) return null;
  final held = book.rowOf(from.chainId, from.denom);
  if (held != null &&
      held.path.isNotEmpty &&
      _oneHop(held.path) &&
      held.counterpartyChainId == venueChainId &&
      held.channelId != null &&
      _key(held.originDenom) == _key(arrival)) {
    return VenueInbound(channelId: held.channelId!, arrivalDenom: arrival);
  }
  final listing = book.rowOf(venueChainId, arrival);
  if (listing != null &&
      listing.path.isNotEmpty &&
      _oneHop(listing.path) &&
      listing.counterpartyChainId == from.chainId &&
      listing.channelId != null &&
      listing.originDenom == from.denom) {
    // The table names the channel on the From's side when Osmosis lists it;
    // otherwise the registry's canonical channel from the From's chain, and
    // only when it lands on the very channel the voucher's hashed trace names.
    var channel = listing.counterpartyChannelId;
    if (channel == null) {
      final canonical = book.canonicalChannel(from.chainId, venueChainId);
      if (canonical != null &&
          canonical.counterpartyChannelId == listing.channelId) {
        channel = canonical.channelId;
      }
    }
    if (channel != null) {
      return VenueInbound(channelId: channel, arrivalDenom: arrival);
    }
  }
  return null;
}

/// Why the output cannot go from Osmosis to the To's chain in one direct hop.
enum VenueDeliveryRefusal { throughAnother, noChannel, otherVariant }

/// The channel from Osmosis that delivers [venueOut] as exactly [toDenom] on
/// [toChainId], from the table alone (the channel is checked live before a
/// swap is offered): a voucher unwinds its one hop home; Osmosis's own token
/// leaves over the canonical channel.
({String? channel, VenueDeliveryRefusal? refusal}) venueDeliveryOf({
  required String toChainId,
  required String toDenom,
  required String venueOut,
  required SwapTokenBook book,
  String venueChainId = kOsmosisChainId,
}) {
  String channel;
  String arrival;
  if (venueOut.startsWith('ibc/')) {
    final row = book.rowOf(venueChainId, venueOut);
    if (row == null ||
        row.channelId == null ||
        !_oneHop(row.path) ||
        row.counterpartyChainId != toChainId) {
      return (channel: null, refusal: VenueDeliveryRefusal.throughAnother);
    }
    channel = row.channelId!;
    arrival = row.originDenom;
  } else {
    final canonical = book.canonicalChannel(venueChainId, toChainId);
    if (canonical == null) {
      return (channel: null, refusal: VenueDeliveryRefusal.noChannel);
    }
    channel = canonical.channelId;
    arrival = ibcDenomHash(
      '$transferPort/${canonical.counterpartyChannelId}',
      venueOut,
    );
  }
  if (_key(arrival) != _key(toDenom)) {
    return (channel: null, refusal: VenueDeliveryRefusal.otherVariant);
  }
  return (channel: channel, refusal: null);
}

/// Whether selling [from] for [to] can be one signature: [from] reaches
/// Osmosis in one canonical hop, and [to] is on Osmosis or one direct hop
/// from it. Table data only; the channels are checked live when planned.
bool oneSignatureReaches(
  SwapAsset from,
  SwapAsset to,
  SwapTokenBook book, {
  String venueChainId = kOsmosisChainId,
}) {
  if (from.chainId == venueChainId) return false;
  final inbound = venueInboundOf(from, book, venueChainId: venueChainId);
  if (inbound == null) return false;
  if (to.chainId == venueChainId) return true;
  final venueOut = to.identity.osmosisDenom;
  if (venueOut == null || venueOut.isEmpty) return false;
  return venueDeliveryOf(
        toChainId: to.chainId,
        toDenom: to.denom,
        venueOut: venueOut,
        book: book,
        venueChainId: venueChainId,
      ).channel !=
      null;
}

/* -------------------------------------------------------------------------- *
 * The memo
 * -------------------------------------------------------------------------- */

/// What the entry point does with the output.
@immutable
sealed class EntryPointPost {
  const EntryPointPost();
  Map<String, Object?> toJson();
}

/// Pay the output on Osmosis.
final class EntryPointPayOnVenue extends EntryPointPost {
  const EntryPointPayOnVenue(this.toAddress);
  final String toAddress;

  @override
  Map<String, Object?> toJson() => {
    'transfer': {'to_address': toAddress},
  };

  @override
  bool operator ==(Object other) =>
      other is EntryPointPayOnVenue && other.toAddress == toAddress;

  @override
  int get hashCode => toAddress.hashCode;
}

/// Send the output on over [sourceChannel] to [receiver]; a failed delivery
/// pays [recoverAddress] on Osmosis.
final class EntryPointDeliver extends EntryPointPost {
  const EntryPointDeliver({
    required this.sourceChannel,
    required this.receiver,
    required this.recoverAddress,
  });

  final String sourceChannel;
  final String receiver;
  final String recoverAddress;

  @override
  Map<String, Object?> toJson() => {
    'ibc_transfer': {
      'ibc_info': {
        'source_channel': sourceChannel,
        'receiver': receiver,
        'memo': '',
        'recover_address': recoverAddress,
      },
    },
  };

  @override
  bool operator ==(Object other) =>
      other is EntryPointDeliver &&
      other.sourceChannel == sourceChannel &&
      other.receiver == receiver &&
      other.recoverAddress == recoverAddress;

  @override
  int get hashCode => Object.hash(sourceChannel, receiver, recoverAddress);
}

/// One pool on the swap, as the entry point names it.
@immutable
class EntryPointOperation {
  const EntryPointOperation(this.pool, this.denomIn, this.denomOut);
  final String pool;
  final String denomIn;
  final String denomOut;

  Map<String, Object?> toJson() => {
    'pool': pool,
    'denom_in': denomIn,
    'denom_out': denomOut,
  };

  @override
  bool operator ==(Object other) =>
      other is EntryPointOperation &&
      other.pool == pool &&
      other.denomIn == denomIn &&
      other.denomOut == denomOut;

  @override
  int get hashCode => Object.hash(pool, denomIn, denomOut);

  @override
  String toString() => 'EntryPointOperation($pool: $denomIn -> $denomOut)';
}

/// [route]'s pools as entry point operations, each taking what the previous
/// one paid, the first taking [inputDenom].
List<EntryPointOperation> entryPointOperations(
  String inputDenom,
  PoolRoute route,
) {
  final out = <EntryPointOperation>[];
  var denomIn = inputDenom;
  for (final hop in route.hops) {
    out.add(EntryPointOperation(hop.poolId, denomIn, hop.tokenOutDenom));
    denomIn = hop.tokenOutDenom;
  }
  return out;
}

/// Nanoseconds since the epoch, [minutes] after [now], as an exact integer.
BigInt entryPointTimeoutNanos(DateTime now, int minutes) =>
    (BigInt.from(now.microsecondsSinceEpoch) +
        BigInt.from(minutes) * BigInt.from(60000000)) *
    BigInt.from(1000);

const String _timeoutMark = '__zunia_entry_point_timeout__';
final RegExp _digits = RegExp(r'^[1-9]\d*$');

/// The ICS20 memo that has the entry point swap and deliver. The swap's
/// `timeout_timestamp` is a `u64` the contract reads only as a bare JSON
/// number: it is written from the integer's own digits, never through a
/// double (19 digits do not fit one) and never as a string, which the contract
/// refuses ("Invalid type").
String buildEntryPointMemo({
  required String inputDenom,
  required PoolRoute route,
  required String outputDenom,
  required String minOut,
  required BigInt timeoutNanos,
  required EntryPointPost post,
  String entryPoint = kSkipEntryPoint,
}) {
  if (route.hops.isEmpty) {
    throw ArgumentError('The entry point needs at least one pool.');
  }
  if (route.hops.last.tokenOutDenom != outputDenom) {
    throw ArgumentError('The route does not end in the token bought.');
  }
  if (!_digits.hasMatch(minOut)) {
    throw ArgumentError('The minimum must be a positive integer.');
  }
  if (timeoutNanos <= BigInt.zero) {
    throw ArgumentError('The swap window must end after the epoch.');
  }
  final body = {
    'wasm': {
      'contract': entryPoint,
      'msg': {
        'swap_and_action': {
          'user_swap': {
            'swap_exact_asset_in': {
              'swap_venue_name': kSkipSwapVenue,
              'operations': [
                for (final op in entryPointOperations(inputDenom, route))
                  op.toJson(),
              ],
            },
          },
          'min_asset': {
            'native': {'denom': outputDenom, 'amount': minOut},
          },
          'timeout_timestamp': _timeoutMark,
          'post_swap_action': post.toJson(),
          'affiliates': const <Object?>[],
        },
      },
    },
  };
  return jsonEncode(
    body,
  ).replaceFirst('"$_timeoutMark"', timeoutNanos.toString());
}

/// What an entry point memo asks for, read back from the memo that is signed.
@immutable
class EntryPointMemoFacts {
  const EntryPointMemoFacts({
    required this.contract,
    required this.venue,
    required this.operations,
    required this.minDenom,
    required this.minAmount,
    required this.timeoutNanos,
    required this.post,
  });

  final String contract;
  final String venue;
  final List<EntryPointOperation> operations;
  final String minDenom;
  final String minAmount;
  final BigInt timeoutNanos;
  final EntryPointPost post;
}

bool _exactKeys(Map<Object?, Object?> map, Set<String> keys) =>
    map.length == keys.length && map.keys.every(keys.contains);

String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// [memo] read whole, or null when any part of it is not exactly the shape
/// [buildEntryPointMemo] writes: an unknown key, an affiliate, a timeout
/// written as a string, a second swap. A memo Zunia cannot account for is
/// never signed.
EntryPointMemoFacts? readEntryPointMemo(String memo) {
  Object? parsed;
  try {
    parsed = jsonDecode(memo);
  } on FormatException {
    return null;
  }
  if (parsed is! Map || !_exactKeys(parsed, const {'wasm'})) return null;
  final wasm = parsed['wasm'];
  if (wasm is! Map || !_exactKeys(wasm, const {'contract', 'msg'})) {
    return null;
  }
  final contract = _text(wasm['contract']);
  final msg = wasm['msg'];
  if (contract == null ||
      msg is! Map ||
      !_exactKeys(msg, const {'swap_and_action'})) {
    return null;
  }
  final call = msg['swap_and_action'];
  if (call is! Map ||
      !_exactKeys(call, const {
        'user_swap',
        'min_asset',
        'timeout_timestamp',
        'post_swap_action',
        'affiliates',
      })) {
    return null;
  }
  final userSwap = call['user_swap'];
  if (userSwap is! Map ||
      !_exactKeys(userSwap, const {'swap_exact_asset_in'})) {
    return null;
  }
  final exactIn = userSwap['swap_exact_asset_in'];
  if (exactIn is! Map ||
      !_exactKeys(exactIn, const {'swap_venue_name', 'operations'})) {
    return null;
  }
  final venue = _text(exactIn['swap_venue_name']);
  final rawOps = exactIn['operations'];
  if (venue == null || rawOps is! List || rawOps.isEmpty) return null;
  final operations = <EntryPointOperation>[];
  for (final op in rawOps) {
    if (op is! Map ||
        !_exactKeys(op, const {'pool', 'denom_in', 'denom_out'})) {
      return null;
    }
    final pool = _text(op['pool']);
    final denomIn = _text(op['denom_in']);
    final denomOut = _text(op['denom_out']);
    if (pool == null || denomIn == null || denomOut == null) return null;
    operations.add(EntryPointOperation(pool, denomIn, denomOut));
  }
  final minAsset = call['min_asset'];
  if (minAsset is! Map || !_exactKeys(minAsset, const {'native'})) return null;
  final native = minAsset['native'];
  if (native is! Map || !_exactKeys(native, const {'denom', 'amount'})) {
    return null;
  }
  final minDenom = _text(native['denom']);
  final minAmount = _text(native['amount']);
  if (minDenom == null || minAmount == null || !_digits.hasMatch(minAmount)) {
    return null;
  }
  final timeout = call['timeout_timestamp'];
  if (timeout is! int || timeout <= 0) return null;
  final affiliates = call['affiliates'];
  if (affiliates is! List || affiliates.isNotEmpty) return null;
  final postRaw = call['post_swap_action'];
  if (postRaw is! Map || postRaw.length != 1) return null;
  EntryPointPost? post;
  final transfer = postRaw['transfer'];
  final ibc = postRaw['ibc_transfer'];
  if (transfer is Map && _exactKeys(transfer, const {'to_address'})) {
    final to = _text(transfer['to_address']);
    if (to != null) post = EntryPointPayOnVenue(to);
  } else if (ibc is Map && _exactKeys(ibc, const {'ibc_info'})) {
    final info = ibc['ibc_info'];
    if (info is Map &&
        _exactKeys(info, const {
          'source_channel',
          'receiver',
          'memo',
          'recover_address',
        }) &&
        info['memo'] == '') {
      final channel = _text(info['source_channel']);
      final receiver = _text(info['receiver']);
      final recover = _text(info['recover_address']);
      if (channel != null && receiver != null && recover != null) {
        post = EntryPointDeliver(
          sourceChannel: channel,
          receiver: receiver,
          recoverAddress: recover,
        );
      }
    }
  }
  if (post == null) return null;
  return EntryPointMemoFacts(
    contract: contract,
    venue: venue,
    operations: List.unmodifiable(operations),
    minDenom: minDenom,
    minAmount: minAmount,
    timeoutNanos: BigInt.from(timeout),
    post: post,
  );
}

/// The plan the packet tracker follows for a one-signature swap: the transfer
/// to Osmosis, the swap there, and the delivery when there is one.
RoutePlan entryPointRoutePlan({
  required SwapAsset from,
  required SwapAsset to,
  required VenueInbound inbound,
  required String? deliveryChannel,
  required String memo,
  String venueChainId = kOsmosisChainId,
}) => RoutePlan(
  sourceChainId: from.chainId,
  destChainId: to.chainId,
  inputDenom: from.denom,
  outputDenom: to.denom,
  hops: [
    RouteHop(
      chainId: from.chainId,
      channelId: inbound.channelId,
      port: inbound.port,
      counterpartyChainId: venueChainId,
      kind: RouteHopKind.transfer,
    ),
    RouteHop(
      chainId: venueChainId,
      channelId: '',
      port: '',
      counterpartyChainId: venueChainId,
      kind: RouteHopKind.swap,
    ),
    if (deliveryChannel != null)
      RouteHop(
        chainId: venueChainId,
        channelId: deliveryChannel,
        port: transferPort,
        counterpartyChainId: to.chainId,
        kind: RouteHopKind.forward,
      ),
  ],
  memo: memo,
  warnings: const [],
  estimatedDurationSeconds: 90,
  requiresPfm: false,
  requiresIbcHooks: true,
);
