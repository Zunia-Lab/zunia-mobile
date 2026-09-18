/// PFM, ibc-hooks and crosschain-swap memos.
///
/// Dart mirror of `memo.ts`. The wire shapes come from INTERCHAIN-SPEC.md §1-3
/// and are not negotiable: ibc-hooks errors a packet whose `wasm` object has
/// anything other than exactly `contract` and `msg`, and a forward memo the
/// middleware cannot parse is delivered to the literal receiver `pfm` on an
/// intermediate chain, where no key controls the funds.
///
/// One deliberate divergence from `memo.ts`, marked FIX below: the TS
/// `readSlippage` requires `window_seconds`, so `validateMemo` cannot read a
/// memo `buildXcsSwapMemo` itself produced when the window is omitted — which
/// is the recommended default, since the contract's own `Option<u64>` falls
/// back to 3600. The approval screen must be able to describe the memo it is
/// about to sign, so this port treats the window as optional on the way in as
/// well as on the way out.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'types.dart';

/* -------------------------------------------------------------------------- *
 * Constants
 * -------------------------------------------------------------------------- */

/// Receiver on every packet-forward hop but the last. An invalid bech32 string
/// on purpose: no key controls it, so funds cannot stop there.
const String pfmIntermediateReceiver = 'pfm';

/// Default Go duration for a forward hop.
const String defaultPfmTimeout = '10m';

/// Default retries for a forward hop, from the middleware README.
const int defaultPfmRetries = 2;

/// The Cosmos SDK's default transaction memo limit, in bytes.
const int txMemoMaxBytes = 256;

/// Ceiling for an ICS20 packet memo.
const int packetMemoMaxBytes = 32768;

/// Hop-count ceiling for a forward memo.
const int maxForwardHops = 8;

const int _maxInspectDepth = 16;
const int _maxJsonDepth = 32;
const int _maxAddressLength = 512;

/// Go `time.ParseDuration` grammar, restricted to non-negative values. Both
/// spellings of the micro sign, because Go accepts `us`, `µs` and `μs`.
final RegExp _goDuration =
    RegExp(r'^(?:\d+(?:\.\d+)?(?:ns|us|µs|μs|ms|s|m|h))+$');

/// ICS-24 identifier charset, for channel and port ids.
final RegExp _ibcIdentifier = RegExp(r'^[a-zA-Z0-9._+#\[\]<>-]{2,128}$');

final RegExp _uintDecimal = RegExp(r'^\d+$');
final RegExp _decimal = RegExp(r'^\d+(?:\.\d+)?$');

const Set<String> _forwardKeys = {
  'receiver',
  'port',
  'channel',
  'timeout',
  'retries',
  'next',
};

/* -------------------------------------------------------------------------- *
 * Helpers
 * -------------------------------------------------------------------------- */

InterchainError _fail(String message) =>
    InterchainError(InterchainErrorCode.invalidMemo, message);

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// Whether a string holds whitespace, a control character, or an invisible
/// character that would make two different addresses look identical.
bool _hasWhitespaceOrControl(String value) {
  for (final code in value.codeUnits) {
    if (code <= 0x20) return true; // C0 controls and the space
    if (code == 0x7f) return true; // DEL
    if (code >= 0x80 && code <= 0xa0) return true; // C1 controls and NBSP
    if (code == 0x2028 || code == 0x2029) return true; // line/paragraph sep
    if (code == 0xfeff) return true; // byte-order mark
  }
  return false;
}

/// Reject anything `jsonEncode` would refuse or quietly rewrite, naming the
/// path that produced it. A caller's bug must not become a memo the middleware
/// accepts and misreads.
void _assertJsonValue(Object? value, String path, List<Object> seen, int depth) {
  if (depth > _maxJsonDepth) {
    throw _fail('$path nests deeper than $_maxJsonDepth levels');
  }
  if (value == null || value is String || value is bool) return;
  if (value is num) {
    if (value.isNaN || value.isInfinite) {
      throw _fail('$path is $value, which has no JSON encoding');
    }
    return;
  }
  if (value is! List && value is! Map) {
    throw _fail('$path is a ${value.runtimeType}, which has no JSON encoding');
  }
  for (final node in seen) {
    if (identical(node, value)) throw _fail('$path is part of a reference cycle');
  }
  seen.add(value);
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _assertJsonValue(value[i], '$path[$i]', seen, depth + 1);
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) throw _fail('$path has a non-string key');
      _assertJsonValue(entry.value, '$path.$key', seen, depth + 1);
    }
  }
  seen.removeLast();
}

Map<String, Object?> _assertJsonObject(Object? value, String label) {
  final row = value is Map<String, Object?>
      ? value
      : value is Map
          ? value.map((k, v) => MapEntry('$k', v))
          : null;
  if (row == null) throw _fail('$label must be a JSON object');
  _assertJsonValue(row, label, <Object>[], 0);
  return row;
}

/// Validate an address-like string.
///
/// Deliberately not trimmed: silently accepting a pasted address with a
/// trailing newline turns what the user reviewed into something else. Also
/// deliberately not bech32-checked — a receiver may be a contract, and prefixes
/// in this registry are not all `[a-z]+` (Safrochain uses `addr_safro`).
String _assertAddress(Object? value, String label) {
  if (value is! String) throw _fail('$label must be a string');
  if (value.isEmpty) throw _fail('$label must not be empty');
  if (value.length > _maxAddressLength) {
    throw _fail('$label is longer than $_maxAddressLength characters');
  }
  if (_hasWhitespaceOrControl(value)) {
    throw _fail('$label contains whitespace or a control character');
  }
  return value;
}

/// Validate an ICS-24 identifier. Not normalised: normalising here would hide a
/// caller passing the wrong thing entirely.
String _assertIdentifier(Object? value, String label) {
  if (value is! String) throw _fail('$label must be a string');
  if (!_ibcIdentifier.hasMatch(value)) {
    throw _fail('$label is not a valid IBC identifier: ${jsonEncode(value)}');
  }
  return value;
}

String _assertTimeout(Object? value, String label) {
  if (value is! String) throw _fail('$label must be a duration string');
  if (!_goDuration.hasMatch(value) || !RegExp(r'[1-9]').hasMatch(value)) {
    throw _fail('$label is not a positive Go duration, e.g. "10m": '
        '${jsonEncode(value)}');
  }
  return value;
}

/// PFM decodes `retries` into a uint8, so anything outside 0-255 is rejected by
/// the middleware rather than clamped.
int _assertRetries(Object? value, String label) {
  if (value is! int) throw _fail('$label must be an integer');
  if (value < 0 || value > 255) throw _fail('$label must be between 0 and 255');
  return value;
}

/// Abbreviate an address for a one-line summary. Full values stay in the model.
String _short(String address) => address.length > 22
    ? '${address.substring(0, 10)}…${address.substring(address.length - 6)}'
    : address;

/* -------------------------------------------------------------------------- *
 * Byte length
 * -------------------------------------------------------------------------- */

/// UTF-8 byte length. Chains count bytes; `String.length` counts UTF-16 units.
int memoByteLength(String memo) => utf8.encode(memo).length;

/// Outcome of measuring a memo against its limits.
@immutable
class MemoLengthReport {
  const MemoLengthReport({
    required this.byteLength,
    required this.maxBytes,
    required this.warnBytes,
    required this.exceedsMax,
    required this.exceedsWarn,
    required this.warning,
  });

  final int byteLength;
  final int maxBytes;
  final int warnBytes;
  final bool exceedsMax;
  final bool exceedsWarn;

  /// Human-readable note when a threshold is crossed, else null.
  final String? warning;
}

/// Measure a memo without throwing. Use this before showing a signing screen;
/// builders take the throwing path instead.
MemoLengthReport checkMemoBytes(
  String memo, {
  int? maxBytes,
  int? warnBytes,
}) {
  final max = maxBytes ?? packetMemoMaxBytes;
  final warn = warnBytes ?? max;
  final length = memoByteLength(memo);
  final exceedsMax = length > max;
  final exceedsWarn = length > warn;

  String? warning;
  if (exceedsMax) {
    warning = 'Memo is $length bytes, over the $max-byte limit. It will be '
        'rejected, not shortened.';
  } else if (exceedsWarn) {
    warning = 'Memo is $length bytes, over the $warn-byte advisory threshold. '
        'It is within the $max-byte limit, but a chain applying a tighter '
        'transaction memo limit would reject it.';
  }

  return MemoLengthReport(
    byteLength: length,
    maxBytes: max,
    warnBytes: warn,
    exceedsMax: exceedsMax,
    exceedsWarn: exceedsWarn,
    warning: warning,
  );
}

String _assertWithinLimit(String memo, int? maxBytes, int? warnBytes) {
  final report = checkMemoBytes(memo, maxBytes: maxBytes, warnBytes: warnBytes);
  if (report.exceedsMax) {
    throw _fail(
      'Memo is ${report.byteLength} bytes, over the ${report.maxBytes}-byte '
      'limit. Shorten the route, not the memo: a truncated forward memo still '
      'parses as text and sends the funds nowhere.',
    );
  }
  return memo;
}

/* -------------------------------------------------------------------------- *
 * Packet-forward-middleware
 * -------------------------------------------------------------------------- */

/// One packet-forward-middleware hop, in execution order.
@immutable
class ForwardHop {
  const ForwardHop({
    required this.channelId,
    this.port,
    this.timeout,
    this.retries,
  });

  /// Channel on the chain this hop leaves from, e.g. `channel-42`.
  final String channelId;
  final String? port;
  final String? timeout;
  final int? retries;
}

/// Build the PFM memo as a JSON object.
///
/// [hops] are the hops *after* the transfer the user signs, in execution order.
/// Only the last carries [finalReceiver]; every earlier one gets
/// [pfmIntermediateReceiver].
///
/// Throws [InterchainError] `invalidMemo` on an empty hop list, a bad
/// identifier, a timeout that is not a Go duration, retries outside 0-255, or a
/// [finalReceiver] equal to the intermediate sentinel.
Map<String, Object?> buildForwardMemoJson(
  List<ForwardHop> hops,
  String finalReceiver, {
  String? timeout,
  int? retries,
  Map<String, Object?>? next,
  int? maxHops,
}) {
  if (hops.isEmpty) throw _fail('A forward memo needs at least one hop');
  final hopCeiling = maxHops ?? maxForwardHops;
  if (hops.length > hopCeiling) {
    throw _fail('A forward memo may not have more than $hopCeiling hops, '
        'got ${hops.length}');
  }

  final receiver = _assertAddress(finalReceiver, 'finalReceiver');
  if (receiver == pfmIntermediateReceiver) {
    throw _fail('finalReceiver must not be "$pfmIntermediateReceiver": that is '
        'the intermediate sentinel and no key controls it');
  }

  final defaultTimeout =
      _assertTimeout(timeout ?? defaultPfmTimeout, 'options.timeout');
  final defaultRetries =
      _assertRetries(retries ?? defaultPfmRetries, 'options.retries');
  final tail = next == null ? null : _assertJsonObject(next, 'options.next');

  // Built inside out: the innermost `forward` is the last hop, so each earlier
  // hop wraps what has been built so far in its own `next`.
  Map<String, Object?>? tip = tail;
  for (var i = hops.length - 1; i >= 0; i--) {
    final hop = hops[i];
    final forward = <String, Object?>{
      // Key order follows the middleware README so a diff against it is trivial.
      'receiver': i == hops.length - 1 ? receiver : pfmIntermediateReceiver,
      'port': _assertIdentifier(hop.port ?? transferPort, 'hops[$i].port'),
      'channel': _assertIdentifier(hop.channelId, 'hops[$i].channelId'),
      'timeout': hop.timeout == null
          ? defaultTimeout
          : _assertTimeout(hop.timeout, 'hops[$i].timeout'),
      'retries': hop.retries == null
          ? defaultRetries
          : _assertRetries(hop.retries, 'hops[$i].retries'),
      // Omitted entirely rather than emitted as null: PFM reads the presence of
      // `next`, and a null tail on the last hop is not the same as no tail.
      'next': ?tip,
    };
    tip = <String, Object?>{'forward': forward};
  }

  return tip!;
}

/// Build the PFM memo.
///
/// `next` is emitted as a nested JSON object, not as the escaped JSON string
/// PFM also accepts: in the string form each extra hop doubles the backslashes
/// ahead of it, so a three-hop memo is unreadable on a signing screen, and a
/// single escaping mistake produces a memo PFM treats as opaque text — the
/// packet is then delivered to the literal receiver `pfm` and the funds are
/// gone.
String buildForwardMemo(
  List<ForwardHop> hops,
  String finalReceiver, {
  String? timeout,
  int? retries,
  Map<String, Object?>? next,
  int? maxHops,
  int? maxBytes,
  int? warnBytes,
}) {
  return _assertWithinLimit(
    jsonEncode(buildForwardMemoJson(
      hops,
      finalReceiver,
      timeout: timeout,
      retries: retries,
      next: next,
      maxHops: maxHops,
    )),
    maxBytes,
    warnBytes,
  );
}

/* -------------------------------------------------------------------------- *
 * ibc-hooks
 * -------------------------------------------------------------------------- */

/// The ICS20 receiver an ibc-hooks transfer must carry.
///
/// ibc-hooks accepts `""` or the contract address (INTERCHAIN-SPEC.md §2). This
/// returns the contract address, the only one of the two that is reliably
/// sendable: ibc-go's `MsgTransfer.ValidateBasic` rejects a blank receiver
/// before the packet is built. It is also what explorers display, so the packet
/// reads as "sent to the contract", which is what happens.
///
/// Call this rather than passing an address by hand. The receiver of the
/// *transfer* and the `receiver` inside a swap message are different fields
/// holding different values, and confusing them is the easiest way to lose a
/// swap.
String wasmHookReceiver(String contract) => _assertAddress(contract, 'contract');

/// Whether an ICS20 receiver satisfies the ibc-hooks rule for a contract.
bool isWasmHookReceiverValid(String receiver, String contract) =>
    receiver.isEmpty || receiver == contract;

/// Build the ibc-hooks memo as a JSON object.
///
/// Every rule the middleware checks is enforced here, because the middleware
/// enforces them by erroring the packet: a `wasm` key, exactly the two entries
/// `contract` and `msg`, and an object `msg`. The remaining rule — that the
/// ICS20 receiver is `""` or the contract address — is not visible from here;
/// use [wasmHookReceiver] to satisfy it.
Map<String, Object?> buildWasmHookMemoJson(
  String contract,
  Map<String, Object?> msg,
) {
  final address = _assertAddress(contract, 'contract');
  final body = _assertJsonObject(msg, 'msg');

  // A CosmWasm ExecuteMsg is a serde enum: it names exactly one variant, so an
  // empty object can never execute. Rejecting it here saves a packet that would
  // error on arrival.
  if (body.isEmpty) {
    throw _fail('msg is empty; a CosmWasm ExecuteMsg must name a variant');
  }

  final memo = <String, Object?>{
    'wasm': <String, Object?>{'contract': address, 'msg': body},
  };

  // Re-read what was just built through the same parser validateMemo uses, so
  // the "exactly two keys" rule is checked against the emitted object rather
  // than against the intent.
  if (_readWasmHook(memo['wasm']) == null) {
    throw _fail('Constructed wasm memo failed its own validation');
  }
  return memo;
}

/// Build the ibc-hooks memo.
///
/// Sender derivation on the destination chain is
/// `Bech32(Hash("ibc-wasm-hook-intermediary" || channelID || sender))`, so the
/// user needs no account there, and the contract's execution gas is paid by the
/// relayer as part of packet processing rather than by the user.
String buildWasmHookMemo(
  String contract,
  Map<String, Object?> msg, {
  int? maxBytes,
  int? warnBytes,
}) =>
    _assertWithinLimit(
      jsonEncode(buildWasmHookMemoJson(contract, msg)),
      maxBytes,
      warnBytes,
    );

/* -------------------------------------------------------------------------- *
 * Osmosis crosschain-swaps
 * -------------------------------------------------------------------------- */

/// Slippage protection for an `osmosis_swap`.
@immutable
sealed class XcsSlippage {
  const XcsSlippage();
}

/// `{"twap":{"slippage_percentage":"20","window_seconds":10}}`.
@immutable
class XcsTwapSlippage extends XcsSlippage {
  const XcsTwapSlippage({required this.slippagePercentage, this.windowSeconds});

  /// Percent as a decimal string, `"20"` meaning 20%. Range 0-100.
  ///
  /// Confirmed against swaprouter's `calculate_min_output_from_twap`, which
  /// does `percentage_impact.div(Uint128::new(100))` before applying it, so the
  /// wire value is a percentage and not a 0-1 fraction. Sending `"0.05"`
  /// intending 5% would set a 0.05% tolerance and fail on any real move.
  final String slippagePercentage;

  /// TWAP window in seconds.
  ///
  /// Optional on the contract (`window: Option<u64>`), which falls back to
  /// `unwrap_or(3600)`. Omit to take that default rather than guessing a
  /// window: a short window on a thin pool reads a noisier price.
  final int? windowSeconds;
}

/// `{"min_output_amount":"100"}`, base units as a string.
@immutable
class XcsMinOutputSlippage extends XcsSlippage {
  const XcsMinOutputSlippage(this.minOutputAmount);

  final String minOutputAmount;
}

/// What the contract does when the swap succeeds but delivery fails.
@immutable
sealed class XcsFailedDelivery {
  const XcsFailedDelivery();
}

/// `{"local_recovery_addr":"osmo1…"}`. Always prefer this.
@immutable
class XcsLocalRecovery extends XcsFailedDelivery {
  const XcsLocalRecovery(this.address);

  final String address;
}

/// `"do_nothing"`.
///
/// With this, swapped funds sit in the crosschain-swaps contract with no
/// recorded owner, so there is nobody for `{"recover":{}}` to pay them to and
/// they are stranded permanently. The difference costs one field.
@immutable
class XcsDoNothing extends XcsFailedDelivery {
  const XcsDoNothing();
}

Map<String, Object?> _slippageJson(XcsSlippage slippage) {
  switch (slippage) {
    case XcsTwapSlippage(:final slippagePercentage, :final windowSeconds):
      if (!_decimal.hasMatch(slippagePercentage)) {
        throw _fail('slippage.slippagePercentage must be a decimal string, '
            'e.g. "20"');
      }
      // A percentage on a 0-100 scale: swaprouter divides by 100 before use.
      if ((double.tryParse(slippagePercentage) ?? 0) > 100) {
        throw _fail('slippage.slippagePercentage must be between 0 and 100');
      }
      if (windowSeconds == null) {
        // Omitting the key is meaningfully different from sending one: the
        // contract's own default (3600) applies. Only emit a window the caller
        // actually chose.
        return <String, Object?>{
          'twap': <String, Object?>{'slippage_percentage': slippagePercentage},
        };
      }
      if (windowSeconds <= 0) {
        throw _fail('slippage.windowSeconds must be a positive integer when '
            'given');
      }
      return <String, Object?>{
        'twap': <String, Object?>{
          'slippage_percentage': slippagePercentage,
          'window_seconds': windowSeconds,
        },
      };
    case XcsMinOutputSlippage(:final minOutputAmount):
      if (!_uintDecimal.hasMatch(minOutputAmount)) {
        throw _fail('slippage.minOutputAmount must be an integer string in '
            'base units');
      }
      return <String, Object?>{'min_output_amount': minOutputAmount};
  }
}

Object _failedDeliveryJson(XcsFailedDelivery action) {
  switch (action) {
    case XcsDoNothing():
      return 'do_nothing';
    case XcsLocalRecovery(:final address):
      return <String, Object?>{
        'local_recovery_addr':
            _assertAddress(address, 'onFailedDelivery.address'),
      };
  }
}

/// Build the Osmosis crosschain-swaps memo as a JSON object.
///
/// It is an ibc-hooks memo whose `msg` is `{"osmosis_swap":{…}}`, so it
/// inherits every rule [buildWasmHookMemoJson] enforces.
///
/// [receiver] is where the swap *output* goes. It is NOT the ICS20 receiver of
/// the transfer, which must be [wasmHookReceiver] of [contract].
Map<String, Object?> buildXcsSwapMemoJson({
  required String contract,
  required String outputDenom,
  required String receiver,
  required XcsSlippage slippage,
  required XcsFailedDelivery onFailedDelivery,
  Map<String, Object?>? nextMemo,
}) {
  final address = _assertAddress(contract, 'contract');
  if (outputDenom.isEmpty) {
    throw _fail('outputDenom must be a non-empty string');
  }
  if (_hasWhitespaceOrControl(outputDenom)) {
    throw _fail('outputDenom contains whitespace or a control character');
  }
  final swapReceiver = _assertAddress(receiver, 'receiver');
  final tail = nextMemo == null ? null : _assertJsonObject(nextMemo, 'nextMemo');

  final swap = <String, Object?>{
    // Key order follows the crosschain-swaps README example.
    'output_denom': outputDenom,
    'slippage': _slippageJson(slippage),
    'receiver': swapReceiver,
    'on_failed_delivery': _failedDeliveryJson(onFailedDelivery),
    // Emitted even when absent: the README example spells it `null`, and we
    // have not verified that the contract's field carries a serde default, so
    // omitting the key risks a deserialisation error on arrival.
    'next_memo': tail,
  };

  return buildWasmHookMemoJson(address, <String, Object?>{'osmosis_swap': swap});
}

/// Build the Osmosis crosschain-swaps memo.
String buildXcsSwapMemo({
  required String contract,
  required String outputDenom,
  required String receiver,
  required XcsSlippage slippage,
  required XcsFailedDelivery onFailedDelivery,
  Map<String, Object?>? nextMemo,
  int? maxBytes,
  int? warnBytes,
}) =>
    _assertWithinLimit(
      jsonEncode(buildXcsSwapMemoJson(
        contract: contract,
        outputDenom: outputDenom,
        receiver: receiver,
        slippage: slippage,
        onFailedDelivery: onFailedDelivery,
        nextMemo: nextMemo,
      )),
      maxBytes,
      warnBytes,
    );

/* -------------------------------------------------------------------------- *
 * Inspection
 * -------------------------------------------------------------------------- */

/// What a memo will do, as far as we can prove.
///
/// - `empty` — no memo.
/// - `plainText` — not a JSON object. Inert: PFM and ibc-hooks both unmarshal
///   the memo into a map and look for a key, so text, numbers and arrays reach
///   neither. Exchange deposit memos land here.
/// - `forward` — packet-forward-middleware will move the funds on.
/// - `wasm` — ibc-hooks will call a contract on arrival.
/// - `xcs` — that contract call is an Osmosis crosschain swap.
/// - `unknown` — a JSON object we could not fully account for. Never treat this
///   as safe.
enum MemoKind { empty, plainText, forward, wasm, xcs, unknown }

/// One hop read out of a forward memo.
@immutable
class ForwardHopInfo {
  const ForwardHopInfo({
    required this.receiver,
    required this.port,
    required this.channelId,
    required this.timeout,
    required this.retries,
  });

  final String receiver;
  final String port;
  final String channelId;

  /// Null when the hop omits it and PFM's own default applies.
  final String? timeout;
  final int? retries;
}

/// The forward chain read out of a memo.
@immutable
class ForwardMemoInfo {
  const ForwardMemoInfo({
    required this.hops,
    required this.finalReceiver,
    required this.hasNextMemo,
  });

  final List<ForwardHopInfo> hops;

  /// Receiver on the last hop: where the funds actually end up.
  final String finalReceiver;
  final bool hasNextMemo;
}

/// The ibc-hooks call read out of a memo.
@immutable
class WasmHookInfo {
  const WasmHookInfo({
    required this.contract,
    required this.msg,
    required this.msgKeys,
  });

  final String contract;
  final Map<String, Object?> msg;

  /// Top-level keys of [msg]. A CosmWasm ExecuteMsg names exactly one.
  final List<String> msgKeys;
}

/// The crosschain swap read out of a memo.
@immutable
class XcsSwapInfo {
  const XcsSwapInfo({
    required this.contract,
    required this.outputDenom,
    required this.receiver,
    required this.slippage,
    required this.onFailedDelivery,
    required this.hasNextMemo,
  });

  final String contract;
  final String outputDenom;
  final String receiver;
  final XcsSlippage slippage;
  final XcsFailedDelivery onFailedDelivery;
  final bool hasNextMemo;
}

/// A classified memo.
///
/// [forward], [wasm] and [xcs] report what could be read, not a verdict — they
/// may be populated while [kind] is `unknown`, when part of the memo parsed and
/// part did not. Branch on [kind].
@immutable
class MemoInspection {
  const MemoInspection({
    required this.kind,
    required this.summary,
    required this.byteLength,
    required this.warnings,
    required this.requiresPfm,
    required this.requiresIbcHooks,
    this.forward,
    this.wasm,
    this.xcs,
  });

  final MemoKind kind;

  /// One line for a signing screen. Plain, factual, safe to render verbatim.
  final String summary;

  final int byteLength;

  /// Things worth showing before the user approves. Not errors.
  final List<String> warnings;

  final bool requiresPfm;
  final bool requiresIbcHooks;
  final ForwardMemoInfo? forward;
  final WasmHookInfo? wasm;
  final XcsSwapInfo? xcs;
}

WasmHookInfo? _readWasmHook(Object? value) {
  final row = _asRecord(value);
  if (row == null) return null;
  final keys = row.keys.toList();
  // The middleware's own rule: exactly two entries, `contract` and `msg`.
  if (keys.length != 2) return null;
  if (!keys.contains('contract') || !keys.contains('msg')) return null;
  final contract = row['contract'];
  final msg = _asRecord(row['msg']);
  if (contract is! String || contract.isEmpty) return null;
  if (msg == null) return null;
  return WasmHookInfo(
    contract: contract,
    msg: msg,
    msgKeys: msg.keys.toList(),
  );
}

XcsSlippage? _readSlippage(Object? value) {
  final row = _asRecord(value);
  if (row == null) return null;
  final keys = row.keys.toList();
  if (keys.length != 1) return null;
  if (keys.first == 'twap') {
    final twap = _asRecord(row['twap']);
    if (twap == null) return null;
    final percentage = twap['slippage_percentage'];
    if (percentage is! String || !_decimal.hasMatch(percentage)) return null;
    final window = twap['window_seconds'];
    // FIX vs memo.ts: the window is optional on the contract, and this package
    // omits it by default, so requiring it here would make validateMemo report
    // our own memo as unreadable — and the signing screen would show
    // "Unrecognised memo" for the swap it is about to sign.
    if (window == null) {
      return XcsTwapSlippage(slippagePercentage: percentage);
    }
    if (window is! int || window <= 0) return null;
    return XcsTwapSlippage(
      slippagePercentage: percentage,
      windowSeconds: window,
    );
  }
  if (keys.first == 'min_output_amount') {
    final amount = row['min_output_amount'];
    if (amount is! String || !_uintDecimal.hasMatch(amount)) return null;
    return XcsMinOutputSlippage(amount);
  }
  return null;
}

XcsFailedDelivery? _readFailedDelivery(Object? value) {
  if (value == 'do_nothing') return const XcsDoNothing();
  final row = _asRecord(value);
  if (row != null && row.length == 1 && row.containsKey('local_recovery_addr')) {
    final address = row['local_recovery_addr'];
    if (address is String && address.isNotEmpty) return XcsLocalRecovery(address);
  }
  return null;
}

XcsSwapInfo? _readXcsSwap(WasmHookInfo hook) {
  if (hook.msgKeys.length != 1 || hook.msgKeys.first != 'osmosis_swap') {
    return null;
  }
  final swap = _asRecord(hook.msg['osmosis_swap']);
  if (swap == null) return null;
  final outputDenom = swap['output_denom'];
  final receiver = swap['receiver'];
  if (outputDenom is! String || outputDenom.isEmpty) return null;
  if (receiver is! String || receiver.isEmpty) return null;
  final slippage = _readSlippage(swap['slippage']);
  if (slippage == null) return null;
  final onFailedDelivery = _readFailedDelivery(swap['on_failed_delivery']);
  if (onFailedDelivery == null) return null;
  return XcsSwapInfo(
    contract: hook.contract,
    outputDenom: outputDenom,
    receiver: receiver,
    slippage: slippage,
    onFailedDelivery: onFailedDelivery,
    hasNextMemo: swap['next_memo'] != null,
  );
}

class _ForwardWalk {
  const _ForwardWalk({this.info, this.tail, this.problem, this.hasTail = false});

  final ForwardMemoInfo? info;
  final Object? tail;
  final bool hasTail;
  final String? problem;
}

_ForwardWalk _stopped(String problem) => _ForwardWalk(problem: problem);

_ForwardWalk _walkForward(Map<String, Object?> root, List<String> warnings) {
  final hops = <ForwardHopInfo>[];
  Object? node = root;
  Object? tail;
  var hasTail = false;

  for (var depth = 0; depth <= _maxInspectDepth; depth++) {
    // PFM also accepts `next` as an escaped JSON string. We never emit that
    // form, but a memo built elsewhere may use it.
    if (node is String) {
      try {
        node = jsonDecode(node);
      } on FormatException {
        return _stopped('a nested memo is a string that is not JSON');
      }
      warnings.add('Memo uses the escaped-string form for a nested hop.');
    }
    final row = _asRecord(node);
    if (row == null) return _stopped('a nested memo is not a JSON object');

    if (!row.containsKey('forward')) {
      // Not a hop: this is the memo delivered with the final packet.
      tail = row;
      hasTail = true;
      break;
    }
    if (row.length != 1) {
      return _stopped(
          'a forward memo carries other top-level keys alongside `forward`');
    }
    final forward = _asRecord(row['forward']);
    if (forward == null) return _stopped('`forward` is not a JSON object');

    final receiver = forward['receiver'];
    final port = forward['port'];
    final channel = forward['channel'];
    if (receiver is! String || receiver.isEmpty) {
      return _stopped('a hop has no `receiver`');
    }
    if (port is! String || !_ibcIdentifier.hasMatch(port)) {
      return _stopped('a hop has no valid `port`');
    }
    if (channel is! String || !_ibcIdentifier.hasMatch(channel)) {
      return _stopped('a hop has no valid `channel`');
    }

    String? timeout;
    final rawTimeout = forward['timeout'];
    if (rawTimeout != null) {
      if (rawTimeout is String) {
        if (!_goDuration.hasMatch(rawTimeout)) {
          return _stopped('a hop `timeout` is not a Go duration');
        }
        timeout = rawTimeout;
      } else if (rawTimeout is int && rawTimeout >= 0) {
        // Defensive, not in the spec: older PFM builders encoded the timeout as
        // an integer count of nanoseconds, and some still do.
        timeout = '${rawTimeout}ns';
        warnings.add('A hop timeout uses the legacy integer-nanoseconds form.');
      } else {
        return _stopped('a hop `timeout` is neither a duration nor an integer');
      }
    }

    int? retries;
    final rawRetries = forward['retries'];
    if (rawRetries != null) {
      if (rawRetries is! int || rawRetries < 0 || rawRetries > 255) {
        return _stopped('a hop `retries` is not an integer in 0-255');
      }
      retries = rawRetries;
    }

    for (final key in forward.keys) {
      if (!_forwardKeys.contains(key)) {
        warnings.add('Forward hop carries an unrecognised field `$key`.');
      }
    }

    hops.add(ForwardHopInfo(
      receiver: receiver,
      port: port,
      channelId: channel,
      timeout: timeout,
      retries: retries,
    ));

    final next = forward['next'];
    if (next == null) {
      tail = null;
      hasTail = false;
      break;
    }
    if (depth == _maxInspectDepth) {
      return _stopped('memo nests more than $_maxInspectDepth levels');
    }
    node = next;
  }

  if (hops.isEmpty) return _stopped('no forward hop could be read');

  return _ForwardWalk(
    info: ForwardMemoInfo(
      hops: hops,
      finalReceiver: hops.last.receiver,
      hasNextMemo: hasTail,
    ),
    tail: tail,
    hasTail: hasTail,
  );
}

String _describeSlippage(XcsSlippage slippage) {
  switch (slippage) {
    case XcsTwapSlippage(:final slippagePercentage, :final windowSeconds):
      // The window is optional; say which average is meant rather than printing
      // a null, and name the contract's own default when none was chosen.
      return windowSeconds == null
          ? 'up to $slippagePercentage% off the average price over the '
              "contract's default window"
          : 'up to $slippagePercentage% off the ${windowSeconds}s average price';
    case XcsMinOutputSlippage(:final minOutputAmount):
      return 'at least $minOutputAmount base units out';
  }
}

String _describeForward(ForwardMemoInfo info) {
  final channels = info.hops.map((hop) => hop.channelId).join(', then ');
  final count =
      info.hops.length == 1 ? 'one more hop' : '${info.hops.length} more hops';
  return 'On arrival, forwards $count ($channels) and pays '
      '${_short(info.finalReceiver)}.';
}

const String _unknownSummary =
    'Unrecognised memo. Zunia cannot tell what this will do on arrival; '
    'approve only if you trust the source.';

const String _doNothingWarning =
    'The swap sets on_failed_delivery to do_nothing: if the swap succeeds but '
    'delivery fails, the funds cannot be recovered.';

/// Classify a memo string.
///
/// This is a security control for the signing screen: before a user approves a
/// transfer they must be told what its memo will actually do. It is therefore
/// conservative — anything that cannot be fully accounted for comes back as
/// `unknown`, never as safe — and it never throws, so a hostile memo cannot
/// break the screen that is supposed to describe it.
///
/// [receiver], when given, is the ICS20 receiver the transfer will carry: a
/// `wasm` memo is cross-checked against it, because ibc-hooks only runs when
/// the receiver is `""` or the contract address.
MemoInspection validateMemo(
  String memo, {
  String? receiver,
  int? maxBytes,
  int? warnBytes,
}) {
  final warnings = <String>[];
  final report = checkMemoBytes(memo, maxBytes: maxBytes, warnBytes: warnBytes);
  if (report.warning != null) warnings.add(report.warning!);

  MemoInspection base(
    MemoKind kind,
    String summary, {
    bool requiresPfm = false,
    bool requiresIbcHooks = false,
    ForwardMemoInfo? forward,
    WasmHookInfo? wasm,
    XcsSwapInfo? xcs,
  }) =>
      MemoInspection(
        kind: kind,
        summary: summary,
        byteLength: report.byteLength,
        warnings: warnings,
        requiresPfm: requiresPfm,
        requiresIbcHooks: requiresIbcHooks,
        forward: forward,
        wasm: wasm,
        xcs: xcs,
      );

  if (memo.trim().isEmpty) return base(MemoKind.empty, 'No memo.');

  Object? parsed;
  try {
    parsed = jsonDecode(memo);
  } on FormatException {
    // PFM and ibc-hooks both unmarshal the memo into a JSON object and look for
    // a key; anything that is not valid JSON reaches neither.
    return base(
      MemoKind.plainText,
      'Plain text memo. No IBC middleware reads it.',
    );
  }

  final row = _asRecord(parsed);
  if (row == null) {
    // A JSON scalar or array does not unmarshal into the map the middlewares
    // read, so it is as inert as free text. Exchange deposit memos land here.
    return base(
      MemoKind.plainText,
      'Memo is JSON but not an object, so no IBC middleware reads it.',
    );
  }

  final hasForward = row.containsKey('forward');
  final hasWasm = row.containsKey('wasm');

  if (hasForward && hasWasm) {
    // Both middlewares would claim this packet and we cannot say which wins on
    // a given chain's stack, so we refuse to describe it.
    warnings.add('Memo carries both `forward` and `wasm` at the top level.');
    return base(
      MemoKind.unknown,
      _unknownSummary,
      requiresPfm: true,
      requiresIbcHooks: true,
    );
  }

  if (hasForward) return _inspectForward(row, base, warnings);
  if (hasWasm) return _inspectWasm(row, base, warnings, receiver);

  // A JSON object with no key we model. Other middleware exists (IBC callbacks,
  // async-icq, chain-specific hooks) and we cannot enumerate it, so this is
  // reported as unknown rather than as inert.
  warnings.add('Memo is a JSON object with unrecognised keys: '
      '${row.keys.join(', ')}.');
  return base(MemoKind.unknown, _unknownSummary);
}

typedef _Base = MemoInspection Function(
  MemoKind kind,
  String summary, {
  bool requiresPfm,
  bool requiresIbcHooks,
  ForwardMemoInfo? forward,
  WasmHookInfo? wasm,
  XcsSwapInfo? xcs,
});

MemoInspection _inspectForward(
  Map<String, Object?> parsed,
  _Base base,
  List<String> warnings,
) {
  final walk = _walkForward(parsed, warnings);
  final info = walk.info;
  if (info == null) {
    warnings.add('Forward memo could not be read: '
        '${walk.problem ?? 'unknown reason'}.');
    return base(MemoKind.unknown, _unknownSummary, requiresPfm: true);
  }

  for (var i = 0; i < info.hops.length - 1; i++) {
    final hop = info.hops[i];
    if (hop.receiver != pfmIntermediateReceiver) {
      warnings.add('Hop ${i + 1} names a real receiver '
          '(${_short(hop.receiver)}) instead of "$pfmIntermediateReceiver".');
    }
  }
  if (info.finalReceiver == pfmIntermediateReceiver) {
    warnings.add('The final receiver is "$pfmIntermediateReceiver", which is '
        'not a real address. The funds would be unrecoverable.');
  }

  var summary = _describeForward(info);

  if (!walk.hasTail) {
    return base(MemoKind.forward, summary, requiresPfm: true, forward: info);
  }

  // The last hop carries a further memo. Only a wasm hook is modelled; a tail we
  // cannot read makes the whole memo unclassifiable, because it decides what
  // happens to the funds at the end of the path.
  final tail = _asRecord(walk.tail);
  if (tail == null || !tail.containsKey('wasm')) {
    warnings.add(
        'The memo delivered after the last hop is not one Zunia recognises.');
    return base(MemoKind.unknown, _unknownSummary,
        requiresPfm: true, forward: info);
  }

  final hook = _readWasmHook(tail['wasm']);
  if (hook == null) {
    warnings.add('The contract call after the last hop does not follow the '
        'ibc-hooks rules.');
    return base(
      MemoKind.unknown,
      _unknownSummary,
      requiresPfm: true,
      requiresIbcHooks: true,
      forward: info,
    );
  }

  final swap = _readXcsSwap(hook);
  if (swap == null &&
      hook.msgKeys.length == 1 &&
      hook.msgKeys.first == 'osmosis_swap') {
    warnings.add('The swap after the last hop could not be read.');
    return base(
      MemoKind.unknown,
      _unknownSummary,
      requiresPfm: true,
      requiresIbcHooks: true,
      forward: info,
      wasm: hook,
    );
  }

  if (swap == null) {
    summary += ' Then calls contract ${_short(hook.contract)} with '
        '${hook.msgKeys.join(', ')}.';
  } else {
    summary += ' Then swaps to ${swap.outputDenom} '
        '(${_describeSlippage(swap.slippage)}) and pays '
        '${_short(swap.receiver)}.';
    if (swap.onFailedDelivery is XcsDoNothing) warnings.add(_doNothingWarning);
  }

  return base(
    swap == null ? MemoKind.forward : MemoKind.xcs,
    summary,
    requiresPfm: true,
    requiresIbcHooks: true,
    forward: info,
    wasm: hook,
    xcs: swap,
  );
}

MemoInspection _inspectWasm(
  Map<String, Object?> parsed,
  _Base base,
  List<String> warnings,
  String? receiver,
) {
  if (parsed.length != 1) {
    warnings.add('Memo carries other top-level keys alongside `wasm`.');
    return base(MemoKind.unknown, _unknownSummary, requiresIbcHooks: true);
  }

  final hook = _readWasmHook(parsed['wasm']);
  if (hook == null) {
    warnings.add('The `wasm` object does not have exactly the two fields '
        '`contract` and `msg` with an object `msg`, so ibc-hooks will error '
        'the packet.');
    return base(MemoKind.unknown, _unknownSummary, requiresIbcHooks: true);
  }

  if (receiver != null && !isWasmHookReceiverValid(receiver, hook.contract)) {
    warnings.add('The transfer receiver is neither empty nor the contract '
        'address, so ibc-hooks will not run this call.');
  }
  if (hook.msgKeys.length != 1) {
    warnings.add(
        'The contract message does not name exactly one ExecuteMsg variant.');
  }

  final swap = _readXcsSwap(hook);
  if (swap == null) {
    if (hook.msgKeys.length == 1 && hook.msgKeys.first == 'osmosis_swap') {
      warnings.add('The memo claims to be a crosschain swap but its fields '
          'could not be read.');
      return base(MemoKind.unknown, _unknownSummary,
          requiresIbcHooks: true, wasm: hook);
    }
    return base(
      MemoKind.wasm,
      'On arrival, calls contract ${_short(hook.contract)} with '
      '${hook.msgKeys.join(', ')}.',
      requiresIbcHooks: true,
      wasm: hook,
    );
  }

  var summary = 'On arrival, swaps to ${swap.outputDenom} '
      '(${_describeSlippage(swap.slippage)}) and pays '
      '${_short(swap.receiver)}.';
  final failure = swap.onFailedDelivery;
  if (failure is XcsLocalRecovery) {
    summary += ' Recovery address ${_short(failure.address)}.';
  } else {
    summary += ' Recovery is off.';
    warnings.add(_doNothingWarning);
  }
  final slippage = swap.slippage;
  if (slippage is XcsMinOutputSlippage && slippage.minOutputAmount == '0') {
    warnings.add('Minimum output is 0, which accepts any price.');
  }
  if (swap.hasNextMemo) summary += ' The output is then forwarded on.';

  return base(
    MemoKind.xcs,
    summary,
    requiresIbcHooks: true,
    wasm: hook,
    xcs: swap,
  );
}
