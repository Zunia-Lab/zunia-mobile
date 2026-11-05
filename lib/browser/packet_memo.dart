/// Where a transfer's packet memo sends the tokens, read the way the receiving
/// chain reads it (zunia-extension/lib/packet-memo.ts, same rules and words).
///
/// An ICS20 memo is not for the receiver: middleware on the receiving chain
/// acts on the tokens before the receiver holds them.
/// - packet-forward-middleware's `{"forward":{"receiver","port","channel","next"}}`
///   sends them on over `channel` to `receiver`, and from there wherever `next` says;
/// - ibc-hooks' `{"wasm":{"contract","msg"}}` hands them to `contract` with `msg`.
///
/// Both read the memo with Go's encoding/json, which matches a field name
/// case-insensitively and folds U+017F, U+212A, U+0131 and U+0130 to `s`, `k`,
/// `i`, `i`, where a JSON parser matches exactly. A memo that spells a field it
/// acts on two ways, or names a channel, receiver or contract the prompt
/// cannot show as it is, is not named: the user is told to read it instead.
library;

import 'dart:convert';

sealed class PacketMemoStep {
  const PacketMemoStep();
}

final class ForwardStep extends PacketMemoStep {
  const ForwardStep(this.channel, this.receiver);
  final String channel;
  final String receiver;
}

final class WasmStep extends PacketMemoStep {
  const WasmStep(this.contract);
  final String contract;
}

class PacketMemoReading {
  const PacketMemoReading(this.steps, {required this.readable, required this.more});

  /// The steps in the order they happen. Empty for a memo no middleware acts on.
  final List<PacketMemoStep> steps;

  /// False when the memo holds instructions that could not be read the way
  /// the chain reads them.
  final bool readable;

  /// True when the route goes on past the last step named.
  final bool more;
}

/// The most steps named in one sentence; a longer route ends in "and on from there".
const _maxSteps = 4;

const _levelFields = ['forward', 'wasm'];
const _forwardFields = ['receiver', 'port', 'channel', 'timeout', 'retries', 'next'];
const _wasmFields = ['contract', 'msg'];

final _channel = RegExp(r'^channel-\d{1,20}$');
final _shownAddress = RegExp(r'^[\x21-\x7e]{1,128}$');

/// A JSON key as Go's encoding/json compares it with a field name.
String _goFold(String key) => key
    .replaceAll(RegExp('[\u0130\u0131]'), 'i')
    .replaceAll('\u017f', 's')
    .replaceAll('\u212a', 'k')
    .toLowerCase();

/// Whether every key Go would read as one of [names] is spelled exactly as that name.
bool _spelledOnce(Map<String, dynamic> object, List<String> names) =>
    object.keys.every((key) {
      final folded = _goFold(key);
      return folded == key || !names.contains(folded);
    });

({bool readable, bool more}) _readLevel(Object? value, List<PacketMemoStep> steps) {
  const unreadable = (readable: false, more: false);
  var level = value;
  if (level is String) {
    try {
      level = jsonDecode(level);
    } on FormatException {
      return unreadable;
    }
  }
  if (level is! Map<String, dynamic> || !_spelledOnce(level, _levelFields)) {
    return unreadable;
  }
  final forward = level['forward'];
  // ibc-hooks acts on a memo that has the key at all; packet-forward-middleware
  // on one whose value is not null.
  final hooked = level.containsKey('wasm');
  final forwarded = forward != null;
  // Both at one level: what happens depends on the order of the chain's middleware.
  if (forwarded && hooked) return unreadable;

  if (hooked) {
    final hook = level['wasm'];
    if (hook is! Map<String, dynamic> || !_spelledOnce(hook, _wasmFields)) {
      return unreadable;
    }
    final contract = hook['contract'];
    if (contract is! String || !_shownAddress.hasMatch(contract)) return unreadable;
    steps.add(WasmStep(contract));
    return (readable: true, more: false);
  }
  if (!forwarded) return (readable: true, more: false);

  if (forward is! Map<String, dynamic> || !_spelledOnce(forward, _forwardFields)) {
    return unreadable;
  }
  final channel = forward['channel'];
  final receiver = forward['receiver'];
  if (channel is! String ||
      !_channel.hasMatch(channel) ||
      receiver is! String ||
      !_shownAddress.hasMatch(receiver)) {
    return unreadable;
  }
  steps.add(ForwardStep(channel, receiver));
  final next = forward['next'];
  if (next == null) return (readable: true, more: false);
  if (steps.length == _maxSteps) return (readable: true, more: true);
  return _readLevel(next, steps);
}

/// What a packet memo has the receiving chain do with the tokens. A memo that
/// is not a JSON object is one no middleware acts on.
PacketMemoReading readPacketMemo(String memo) {
  final Object? parsed;
  try {
    parsed = jsonDecode(memo);
  } on FormatException {
    return const PacketMemoReading([], readable: true, more: false);
  }
  if (parsed is! Map<String, dynamic>) {
    return const PacketMemoReading([], readable: true, more: false);
  }
  final steps = <PacketMemoStep>[];
  final result = _readLevel(parsed, steps);
  return result.readable
      ? PacketMemoReading(steps, readable: true, more: result.more)
      : const PacketMemoReading([], readable: false, more: false);
}

/// Told when a memo holds instructions [readPacketMemo] could not read the way
/// the chain does.
const kPacketMemoUnreadable =
    'Zunia cannot tell where this packet memo sends the tokens. Read it under Raw transaction before you approve.';

/// Where a packet memo sends the tokens, in one sentence:
/// `The packet memo forwards the tokens from the receiving chain over channel-5 to stride1…`.
/// [kPacketMemoUnreadable] for a memo that cannot be read as the chain reads
/// it, and null for one that sends them nowhere.
String? packetMemoNote(String memo) {
  final reading = readPacketMemo(memo);
  if (!reading.readable) return kPacketMemoUnreadable;
  if (reading.steps.isEmpty) return null;
  final said = <String>[];
  for (var i = 0; i < reading.steps.length; i++) {
    final first = i == 0;
    switch (reading.steps[i]) {
      case ForwardStep(:final channel, :final receiver):
        said.add(
          '${first ? 'forwards the tokens from the receiving chain ' : ''}over $channel to $receiver',
        );
      case WasmStep(:final contract):
        said.add(
          first
              ? 'hands the tokens to contract $contract on the receiving chain'
              : 'hands them to contract $contract there',
        );
    }
  }
  return 'The packet memo ${said.join(', then ')}${reading.more ? ', and on from there' : ''}.';
}
