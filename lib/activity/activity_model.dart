/// Reading transactions into history rows and a detail.
///
/// Port of the history half of `zunia-extension/lib/chain-queries.ts` (0.1.5):
/// one message per transaction is what the row is about (the delivery to this
/// account in a relayer's batch, else the first message that is not relayer
/// upkeep), and every coin is named by its [TokenIdentity] on the chain, so
/// the title (`Send USDC.n`), the amount and the detail always agree. A coin
/// nothing names keeps its short denom and its amount in base units.
///
/// Inside a swap transaction a bank send to the Zunia treasury configured for
/// that chain (`assets/data/swap-fee.json`) is Zunia's fee and reads so.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';

enum ActivityKind { sent, received, ibc, swap, staking, claim, governance, other }

/// One row of history.
@immutable
class ActivityItem {
  const ActivityItem({
    required this.chainId,
    required this.hash,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    required this.success,
    this.amount,
    this.denom,
    this.decimals = 0,
    this.decimalsKnown = false,
    this.symbol = '',
    this.unknownCoin = false,
    this.from,
    this.to,
    this.channel,
    this.messageType,
    this.zuniaFee = false,
    this.swap = false,
  });

  final String chainId;
  final String hash;
  final ActivityKind kind;

  /// `Send USDC.n`, `Receive USDC.n over IBC`: named by the coin's identity.
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final bool success;

  /// Signed base-unit delta for the account, when it can be worked out.
  final String? amount;

  /// The exact bank denom on [chainId] that moved; absent when it cannot be
  /// worked out (an IBC receipt whose credited denom is unknown).
  final String? denom;

  /// For [denom]; 0 when [decimalsKnown] is false, and [amount] is base units.
  final int decimals;
  final bool decimalsKnown;

  /// The identity's ticker, the same word the title uses.
  final String symbol;

  /// Nothing names the coin: its unit is the short denom.
  final bool unknownCoin;
  final String? from;
  final String? to;
  final String? channel;

  /// Short protobuf name, e.g. `MsgSend`.
  final String? messageType;

  /// The row is Zunia's swap fee.
  final bool zuniaFee;

  /// The transaction swaps (contract call, hooks memo, or pool message).
  final bool swap;

  AmountScale get scale => AmountScale(
        decimals: decimalsKnown ? decimals : 0,
        decimalsKnown: decimalsKnown,
        ticker: symbol,
        denom: denom ?? '',
        unknown: unknownCoin,
      );

  bool get outgoing => amount?.startsWith('-') ?? false;
}

/// One message as the history row and the detail list describe it.
@immutable
class DescribedMessage {
  const DescribedMessage({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.summary,
    this.amount,
    this.denom,
    this.decimals = 0,
    this.decimalsKnown = false,
    this.symbol = '',
    this.unknownCoin = false,
    this.from,
    this.to,
    this.channel,
    this.contract,
    this.proposalId,
    this.vote,
    this.zuniaFee = false,
  });

  final ActivityKind kind;
  final String title;
  final String subtitle;

  /// One sentence for the transaction detail.
  final String summary;
  final String? amount;
  final String? denom;
  final int decimals;
  final bool decimalsKnown;
  final String symbol;
  final bool unknownCoin;
  final String? from;
  final String? to;
  final String? channel;
  final String? contract;
  final String? proposalId;
  final String? vote;
  final bool zuniaFee;
}

/* -------------------------------------------------------------------------- *
 * Helpers
 * -------------------------------------------------------------------------- */

Map<String, Object?>? _record(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', item)) : null;

String _text(Object? value) =>
    value is String ? value : value is num ? '$value' : '';

final RegExp _digits = RegExp(r'^\d+$');

({String denom, String amount})? _firstCoin(Object? value) {
  final rows = value is List ? value : [value];
  for (final row in rows) {
    final coin = _record(row);
    final denom = _text(coin?['denom']);
    final amount = _text(coin?['amount']).split('.').first;
    if (denom.isNotEmpty && _digits.hasMatch(amount)) return (denom: denom, amount: amount);
  }
  return null;
}

String _typeUrlOf(Map<String, Object?> message) => _text(message['@type']);

/// `MsgSend` from `/cosmos.bank.v1beta1.MsgSend`.
String shortTypeName(String typeUrl) {
  final last = typeUrl.split('.').last;
  return last.isEmpty ? (typeUrl.isEmpty ? 'Unknown message' : typeUrl) : last;
}

/// `Swap Exact Amount In` from `MsgSwapExactAmountIn`.
String humanType(String typeUrl) => shortTypeName(typeUrl)
    .replaceFirst(RegExp('^Msg'), '')
    .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
    .trim();

/// `cosmos1qy35…hx9f2k` for a long address.
String shortAddress(String address) =>
    address.length > 22 ? '${address.substring(0, 12)}…${address.substring(address.length - 6)}' : address;

String _decodeBase64Utf8(String raw) => utf8.decode(base64.decode(raw));

typedef _ReceivedPacket = ({
  Ics20PacketData data,
  bool tracedDenom,
  String channel,
  String sourcePort,
  String sourceChannel,
  String destinationPort,
  String destinationChannel,
});

_ReceivedPacket? _receivedPacket(Map<String, Object?> message) {
  final packet = _record(message['packet']);
  final raw = _text(packet?['data']);
  if (packet == null || raw.isEmpty) return null;
  Ics20PacketData? data;
  var traced = false;
  try {
    final json = _decodeBase64Utf8(raw);
    data = parseIcs20PacketData(json);
    // ICS20 v1 writes the whole trace into `denom`; v2 nests it.
    final decoded = jsonDecode(json);
    traced = decoded is Map && decoded['denom'] is String;
  } on Object {
    return null;
  }
  if (data == null) return null;
  return (
    data: data,
    tracedDenom: traced,
    channel: _text(packet['destination_channel']),
    sourcePort: _text(packet['source_port']),
    sourceChannel: _text(packet['source_channel']),
    destinationPort: _text(packet['destination_port']),
    destinationChannel: _text(packet['destination_channel']),
  );
}

/// A hop's identifier: a channel id, or an IBC v2 client id (`08-wasm-1369`).
final RegExp _hopId = RegExp(r'^(?:channel-\d+|\w+(?:[\w-]+\w)?-\d{1,20})$');

bool _isTracedDenom(String denom) {
  final parts = denom.split('/');
  return parts.length > 2 && _hopId.hasMatch(parts[1]);
}

final RegExp _channelIdPattern = RegExp(r'^channel-\d+$');

/// The bank denom a received ICS20 packet credits on [chainId], by ibc-go's
/// receive rule: a denom starting with the packet's own source `port/channel/`
/// is going home and loses that prefix; anything else becomes the voucher of
/// `destPort/destChannel/denom`. Null when the source end is unknown.
String? receivedDenomOf(
  String chainId,
  String packetDenom, {
  String? sourcePort,
  String? sourceChannel,
  String? destinationPort,
  String? destinationChannel,
}) {
  final destChannel = destinationChannel ?? '';
  if (packetDenom.isEmpty || !_channelIdPattern.hasMatch(destChannel)) return null;
  final destPort = (destinationPort ?? '').isEmpty ? 'transfer' : destinationPort!;
  final srcPort = (sourcePort ?? '').isEmpty ? 'transfer' : sourcePort!;
  final srcChannel = (sourceChannel ?? '').isNotEmpty
      ? sourceChannel
      : destPort == 'transfer'
          ? TokenRegistry.instance?.canonicalCounterpartyChannel(chainId, destChannel)
          : null;
  if (srcChannel == null) return null;
  final prefix = '$srcPort/$srcChannel/';
  if (packetDenom.startsWith(prefix)) {
    final home = packetDenom.substring(prefix.length);
    if (home.isEmpty) return null;
    return _isTracedDenom(home) ? ibcDenomFor('', home) : home;
  }
  return ibcDenomFor('$destPort/$destChannel', packetDenom);
}

/// A relayer delivers a packet with client updates around it.
final RegExp _relayerUpkeep =
    RegExp(r'\.(MsgUpdateClient|MsgAcknowledgement|MsgTimeout|MsgTimeoutOnClose)$');

/// The message a transaction is about, for this account.
Map<String, Object?>? pickMessage(List<Map<String, Object?>> messages, String address) {
  for (final message in messages) {
    if (_typeUrlOf(message).endsWith('.MsgRecvPacket') &&
        _receivedPacket(message)?.data.receiver == address) {
      return message;
    }
  }
  for (final message in messages) {
    final type = _typeUrlOf(message);
    if (!_relayerUpkeep.hasMatch(type) && !type.endsWith('.MsgRecvPacket')) return message;
  }
  return messages.isEmpty ? null : messages.first;
}

const int _maxForwardDepth = 4;

bool _memoCallsSwap(Object? memo, [int depth = 0]) {
  if (depth > _maxForwardDepth) return false;
  Map<String, Object?>? parsed;
  if (memo is String) {
    try {
      parsed = _record(jsonDecode(memo));
    } on FormatException {
      return false;
    }
  } else {
    parsed = _record(memo);
  }
  if (parsed == null) return false;
  final call = _record(_record(parsed['wasm'])?['msg']);
  if (call != null && call.containsKey('osmosis_swap')) return true;
  return _memoCallsSwap(_record(parsed['forward'])?['next'], depth + 1);
}

Map<String, Object?>? _executeMsgOf(Object? raw) {
  final json = _record(raw);
  if (json != null) return json;
  if (raw is! String || raw.isEmpty) return null;
  try {
    return _record(jsonDecode(_decodeBase64Utf8(raw)));
  } on Object {
    return null;
  }
}

const List<String> _poolSwapTypes = ['.MsgSwapExactAmountIn', '.MsgSplitRouteSwapExactAmountIn'];

/// Whether a transaction swaps the way Swap signs one.
bool isSwapTx(List<Map<String, Object?>> messages) {
  for (final message in messages) {
    final type = _typeUrlOf(message);
    if (type.contains('poolmanager') && _poolSwapTypes.any(type.endsWith)) return true;
    if (type.endsWith('.MsgExecuteContract')) {
      final call = _executeMsgOf(message['msg']);
      if (call != null && call.containsKey('osmosis_swap')) return true;
    }
    if (type.endsWith('.MsgTransfer') && _memoCallsSwap(message['memo'])) return true;
  }
  return false;
}

/* -------------------------------------------------------------------------- *
 * describeMessage
 * -------------------------------------------------------------------------- */

typedef _CoinFacts = ({int decimals, bool decimalsKnown, String ticker, bool unknown});

_CoinFacts _factsOf(TokenIdentity identity) => (
      decimals: identity.decimals,
      decimalsKnown: identity.decimalsKnown,
      ticker: identity.ticker,
      unknown: identity.provenance == TokenProvenance.unknown,
    );

_CoinFacts _unknownCoin(String spelling) =>
    (decimals: 0, decimalsKnown: false, ticker: shortDenom(spelling), unknown: true);

String _coinWords(String amount, _CoinFacts facts, String denom) {
  final scale = AmountScale(
    decimals: facts.decimals,
    decimalsKnown: facts.decimalsKnown,
    ticker: facts.ticker,
    denom: denom,
    unknown: facts.unknown && denom.isNotEmpty,
  );
  return formatTokenAmount(amount, scale, TokenAmountVariant.confirm, unit: true);
}

/// Read one message into words. Unknown messages keep their type name.
DescribedMessage describeMessage(
  Map<String, Object?> message,
  String address,
  String chainId, {
  bool swapTx = false,
  Map<String, String> feeRecipients = const {},
}) {
  final type = _typeUrlOf(message);
  final entry = ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;
  final nativeDenom = entry?.coinMinimalDenom ?? '';
  final native = identityOf(chainId, nativeDenom);
  final plainSymbol = nativeDenom.isEmpty ? '' : native.ticker;

  DescribedMessage build({
    required ActivityKind kind,
    required String title,
    required String subtitle,
    required String summary,
    ({String amount, String denom})? coin,
    _CoinFacts? facts,
    String sign = '',
    String? from,
    String? to,
    String? channel,
    String? contract,
    String? proposalId,
    String? vote,
    bool zuniaFee = false,
    bool denomKnown = true,
  }) {
    final hasCoin = coin != null && facts != null;
    return DescribedMessage(
      kind: kind,
      title: title,
      subtitle: subtitle,
      summary: summary,
      amount: hasCoin ? '$sign${coin.amount}' : null,
      denom: hasCoin && denomKnown ? coin.denom : null,
      decimals: hasCoin ? facts.decimals : native.decimals,
      decimalsKnown: hasCoin ? facts.decimalsKnown : native.decimalsKnown,
      symbol: hasCoin ? facts.ticker : plainSymbol,
      unknownCoin: hasCoin && facts.unknown,
      from: from,
      to: to,
      channel: channel,
      contract: contract,
      proposalId: proposalId,
      vote: vote,
      zuniaFee: zuniaFee,
    );
  }

  ({({String amount, String denom})? coin, _CoinFacts? facts, String words}) withCoin(
    ({String denom, String amount})? coin,
  ) {
    if (coin == null) return (coin: null, facts: null, words: '');
    final facts = _factsOf(identityOf(chainId, coin.denom));
    return (
      coin: (amount: coin.amount, denom: coin.denom),
      facts: facts,
      words: _coinWords(coin.amount, facts, coin.denom),
    );
  }

  if (type.endsWith('.MsgSend')) {
    final from = _text(message['from_address']);
    final to = _text(message['to_address']);
    final outgoing = from == address;
    final c = withCoin(_firstCoin(message['amount']));
    final symbol = c.facts?.ticker ?? plainSymbol;
    final treasury = feeRecipients[chainId];
    if (swapTx && to.isNotEmpty && treasury != null && to == treasury) {
      return build(
        kind: outgoing ? ActivityKind.sent : ActivityKind.received,
        title: 'Zunia fee',
        subtitle: outgoing ? 'to $to' : 'from $from',
        summary: outgoing
            ? 'Zunia fee: ${c.words} to ${shortAddress(to)}'
            : 'Zunia fee: ${c.words} from ${shortAddress(from)}',
        coin: c.coin,
        facts: c.facts,
        sign: outgoing ? '-' : '',
        from: from,
        to: to,
        zuniaFee: true,
      );
    }
    return build(
      kind: outgoing ? ActivityKind.sent : ActivityKind.received,
      title: '${outgoing ? 'Send' : 'Receive'} $symbol'.trim(),
      subtitle: outgoing ? 'to $to' : 'from $from',
      summary: outgoing
          ? 'Send ${c.words} to ${shortAddress(to)}'
          : 'Receive ${c.words} from ${shortAddress(from)}',
      coin: c.coin,
      facts: c.facts,
      sign: outgoing ? '-' : '',
      from: from,
      to: to,
    );
  }

  if (type.endsWith('.MsgMultiSend')) {
    final inputs = message['inputs'] is List ? message['inputs'] as List : const [];
    final outgoing = inputs.any((input) => _text(_record(input)?['address']) == address);
    return build(
      kind: outgoing ? ActivityKind.sent : ActivityKind.received,
      title: outgoing ? 'Send to several' : 'Receive',
      subtitle: 'multi-send',
      summary: outgoing ? 'Send to several addresses at once' : 'Receive in a multi-send',
    );
  }

  if (type.endsWith('.MsgTransfer')) {
    final receiver = _text(message['receiver']);
    final channel = _text(message['source_channel']);
    final c = withCoin(_firstCoin(message['token']));
    final symbol = c.facts?.ticker ?? plainSymbol;
    final sender = _text(message['sender']);
    return build(
      kind: ActivityKind.ibc,
      title: 'Send $symbol over IBC'.replaceAll('  ', ' '),
      subtitle: 'to $receiver',
      summary: 'Send ${c.words} over IBC to ${shortAddress(receiver)} on $channel',
      coin: c.coin,
      facts: c.facts,
      sign: '-',
      from: sender.isEmpty ? address : sender,
      to: receiver,
      channel: channel,
    );
  }

  if (type.endsWith('.MsgRecvPacket')) {
    final packet = _receivedPacket(message);
    final data = packet?.data;
    final amount = data?.amount ?? '';
    final packetDenom = data?.denom;
    if (packet != null &&
        data!.receiver == address &&
        packetDenom != null &&
        packetDenom.isNotEmpty &&
        _digits.hasMatch(amount)) {
      final local = packet.tracedDenom
          ? receivedDenomOf(
              chainId,
              packetDenom,
              sourcePort: packet.sourcePort,
              sourceChannel: packet.sourceChannel,
              destinationPort: packet.destinationPort,
              destinationChannel: packet.destinationChannel,
            )
          : null;
      final facts = local != null ? _factsOf(identityOf(chainId, local)) : _unknownCoin(packetDenom);
      final words = _coinWords(amount, facts, local ?? '');
      final sender = data.sender ?? '';
      return build(
        kind: ActivityKind.ibc,
        title: 'Receive ${facts.ticker} over IBC',
        subtitle: 'from $sender',
        summary: 'Receive $words over IBC from ${shortAddress(sender)} on ${packet.channel}',
        coin: (amount: amount, denom: local ?? packetDenom),
        facts: facts,
        denomKnown: local != null,
        from: sender,
        to: data.receiver,
        channel: packet.channel,
      );
    }
    return build(
      kind: ActivityKind.other,
      title: 'Deliver IBC packet',
      subtitle: packet?.channel ?? '',
      summary: 'Deliver an IBC packet${packet != null && packet.channel.isNotEmpty ? ' on ${packet.channel}' : ''}',
    );
  }

  if (_relayerUpkeep.hasMatch(type)) {
    return build(
      kind: ActivityKind.other,
      title: humanType(type),
      subtitle: type,
      summary: type.endsWith('.MsgUpdateClient')
          ? 'Update the IBC client ${_text(message['client_id'])}'.trim()
          : 'IBC relayer step: ${humanType(type).toLowerCase()}',
    );
  }

  if (type.endsWith('.MsgSplitRouteSwapExactAmountIn')) {
    final routes = message['routes'] is List
        ? [for (final route in message['routes'] as List) _record(route)]
        : <Map<String, Object?>?>[];
    var total = BigInt.zero;
    for (final route in routes) {
      final share = _text(route?['token_in_amount']);
      if (_digits.hasMatch(share)) total += BigInt.parse(share);
    }
    final inDenom = _text(message['token_in_denom']);
    final c = withCoin(
      inDenom.isNotEmpty && total > BigInt.zero ? (denom: inDenom, amount: total.toString()) : null,
    );
    final pools = routes.isNotEmpty && routes.first?['pools'] is List
        ? routes.first!['pools'] as List
        : const [];
    final outDenom = pools.isEmpty ? '' : _text(_record(pools.last)?['token_out_denom']);
    final outSymbol = outDenom.isEmpty ? '' : identityOf(chainId, outDenom).ticker;
    final symbol = c.facts?.ticker ?? plainSymbol;
    return build(
      kind: ActivityKind.swap,
      title: outSymbol.isNotEmpty && symbol.isNotEmpty ? 'Swap $symbol for $outSymbol' : 'Swap',
      subtitle: 'on ${routes.length} route${routes.length == 1 ? '' : 's'}',
      summary: c.words.isNotEmpty
          ? 'Swap ${c.words}${outSymbol.isNotEmpty ? ' for $outSymbol' : ''}'
          : 'Swap',
      coin: c.coin,
      facts: c.facts,
      sign: '-',
    );
  }

  if (type.contains('MsgSwap') || type.endsWith('.MsgJoinPool') || type.endsWith('.MsgExitPool')) {
    final c = withCoin(_firstCoin(message['token_in'] ?? message['token_in_maxs']));
    final routes = message['routes'] is List ? message['routes'] as List : const [];
    final outDenom = routes.isEmpty ? '' : _text(_record(routes.last)?['token_out_denom']);
    final outSymbol = outDenom.isEmpty ? '' : identityOf(chainId, outDenom).ticker;
    final symbol = c.facts?.ticker ?? plainSymbol;
    return build(
      kind: ActivityKind.swap,
      title: humanType(type),
      subtitle: outSymbol.isNotEmpty ? '$symbol for $outSymbol' : type,
      summary: c.words.isNotEmpty
          ? '${humanType(type)}: ${c.words}${outSymbol.isNotEmpty ? ' for $outSymbol' : ''}'
          : humanType(type),
      coin: c.coin,
      facts: c.facts,
      sign: '-',
    );
  }

  if (type.endsWith('.MsgExecuteContract')) {
    final contract = _text(message['contract']);
    final call = _executeMsgOf(message['msg']);
    final action = call == null || call.isEmpty ? '' : call.keys.first;
    final c = withCoin(_firstCoin(message['funds']));
    return build(
      kind: action.contains('swap') ? ActivityKind.swap : ActivityKind.other,
      title: action.isNotEmpty ? 'Call $action' : 'Contract call',
      subtitle: 'on $contract',
      summary: 'Call ${action.isNotEmpty ? action : 'a contract'} on ${shortAddress(contract)}'
          '${c.words.isNotEmpty ? ' with ${c.words}' : ''}',
      coin: c.coin,
      facts: c.facts,
      sign: '-',
      to: contract,
      contract: contract,
    );
  }

  if (type.endsWith('.MsgDelegate') || type.endsWith('.MsgUndelegate')) {
    final delegate = type.endsWith('.MsgDelegate');
    final validator = _text(message['validator_address']);
    final c = withCoin(_firstCoin(message['amount']));
    return build(
      kind: ActivityKind.staking,
      title: delegate ? 'Delegate' : 'Undelegate',
      subtitle: validator,
      summary: delegate
          ? 'Delegate ${c.words} to ${shortAddress(validator)}'
          : 'Undelegate ${c.words} from ${shortAddress(validator)}',
      coin: c.coin,
      facts: c.facts,
      from: delegate ? null : validator,
      to: delegate ? validator : null,
    );
  }

  if (type.endsWith('.MsgBeginRedelegate')) {
    final from = _text(message['validator_src_address']);
    final to = _text(message['validator_dst_address']);
    final c = withCoin(_firstCoin(message['amount']));
    return build(
      kind: ActivityKind.staking,
      title: 'Redelegate',
      subtitle: to,
      summary: 'Move ${c.words} from ${shortAddress(from)} to ${shortAddress(to)}',
      coin: c.coin,
      facts: c.facts,
      from: from,
      to: to,
    );
  }

  if (type.endsWith('.MsgWithdrawDelegatorReward')) {
    final validator = _text(message['validator_address']);
    return build(
      kind: ActivityKind.claim,
      title: 'Claim rewards',
      subtitle: validator,
      summary: 'Claim staking rewards from ${shortAddress(validator)}',
      from: validator,
    );
  }

  if (type.endsWith('.MsgVote') || type.endsWith('.MsgVoteWeighted')) {
    final proposal = _text(message['proposal_id']);
    final option =
        _text(message['option']).replaceAll('VOTE_OPTION_', '').replaceAll('_', ' ').toLowerCase();
    return build(
      kind: ActivityKind.governance,
      title: 'Vote on #$proposal',
      subtitle: option,
      summary: option.isNotEmpty ? 'Vote $option on proposal #$proposal' : 'Vote on proposal #$proposal',
      proposalId: proposal,
      vote: option,
    );
  }

  return build(
    kind: ActivityKind.other,
    title: humanType(type),
    subtitle: type,
    summary: humanType(type),
  );
}

/// Turn one tx search response row into a history row for [address].
ActivityItem? activityFromTxResponse(
  Map<String, Object?> tx,
  String chainId,
  String address, {
  Map<String, String> feeRecipients = const {},
}) {
  final hash = _text(tx['txhash']);
  if (hash.isEmpty) return null;
  final body = _record(_record(tx['tx'])?['body']);
  final raw = body?['messages'];
  final messages = <Map<String, Object?>>[
    if (raw is List)
      for (final message in raw)
        if (_record(message) != null) _record(message)!,
  ];
  final message = pickMessage(messages, address);
  if (message == null) return null;
  final swap = isSwapTx(messages);
  final described = describeMessage(
    message,
    address,
    chainId,
    swapTx: swap,
    feeRecipients: feeRecipients,
  );
  final code = tx['code'];
  return ActivityItem(
    chainId: chainId,
    hash: hash,
    kind: described.kind,
    title: described.title,
    subtitle: described.subtitle,
    timestamp: DateTime.tryParse(_text(tx['timestamp'])) ?? DateTime.fromMillisecondsSinceEpoch(0),
    success: code == null || (code is num && code == 0),
    amount: described.amount,
    denom: described.denom,
    decimals: described.decimals,
    decimalsKnown: described.decimalsKnown,
    symbol: described.symbol,
    unknownCoin: described.unknownCoin,
    from: described.from,
    to: described.to,
    channel: described.channel,
    messageType: shortTypeName(_typeUrlOf(message)),
    zuniaFee: described.zuniaFee,
    swap: swap,
  );
}

/* -------------------------------------------------------------------------- *
 * Showing a row's amount
 * -------------------------------------------------------------------------- */

/// `-` when value left the account, `+` when it arrived, nothing for staking.
String activitySign(ActivityItem item) {
  if (item.outgoing) return '-';
  return item.kind == ActivityKind.received ||
          item.kind == ActivityKind.ibc ||
          item.kind == ActivityKind.claim
      ? '+'
      : '';
}

/// A row's amount for lists (`history`) or the detail (`confirm`): `-12.34
/// USDC.n`, `+12340000 base units ibc/498A…6BA6E4`. Null when nothing moved.
String? activityAmountText(
  ActivityItem item, {
  TokenAmountVariant variant = TokenAmountVariant.history,
  bool hidden = false,
}) {
  final unsigned = item.amount?.replaceFirst('-', '') ?? '';
  if (!_digits.hasMatch(unsigned) || !unsigned.contains(RegExp('[1-9]'))) return null;
  if (hidden) return maskedAmount;
  final scale = item.scale;
  final value = formatTokenAmount(unsigned, scale, variant);
  final unit = amountUnit(scale);
  return '${activitySign(item)}$value${unit.isEmpty ? '' : ' $unit'}';
}

/* -------------------------------------------------------------------------- *
 * One transaction
 * -------------------------------------------------------------------------- */

@immutable
class TxFeeCoin {
  const TxFeeCoin({required this.denom, required this.amount, required this.scale});
  final String denom;
  final String amount;
  final AmountScale scale;
}

@immutable
class TxDetailMessage {
  const TxDetailMessage({required this.type, required this.described});
  final String type;
  final DescribedMessage described;
}

/// Everything the transaction detail shows, read from the chain.
@immutable
class TxDetailInfo {
  const TxDetailInfo({
    required this.chainId,
    required this.hash,
    required this.height,
    required this.timestamp,
    required this.success,
    required this.error,
    required this.memo,
    required this.fee,
    required this.gasWanted,
    required this.gasUsed,
    required this.messages,
    required this.packets,
    required this.swap,
  });

  final String chainId;
  final String hash;
  final String? height;
  final DateTime? timestamp;
  final bool success;

  /// The chain's own words when it rejected the transaction.
  final String? error;
  final String memo;
  final List<TxFeeCoin> fee;
  final String? gasWanted;
  final String? gasUsed;
  final List<TxDetailMessage> messages;

  /// IBC packets the transaction sent, to follow them across chains.
  final List<ExtractedPacket> packets;
  final bool swap;

  /// The Zunia fee rows of a swap, if any.
  List<DescribedMessage> get zuniaFees =>
      [for (final message in messages) if (message.described.zuniaFee) message.described];
}

const int _maxErrorChars = 400;

/// `/cosmos/tx/v1beta1/txs/{hash}` read into the detail. Null when the body
/// is not a transaction.
TxDetailInfo? parseTxDetail(
  Object? body,
  String chainId,
  String address, {
  Map<String, String> feeRecipients = const {},
}) {
  final root = _record(body);
  final response = _record(root?['tx_response']) ?? root;
  final hash = _text(response?['txhash']);
  if (response == null || hash.isEmpty) return null;
  final tx = _record(root?['tx']) ?? _record(response['tx']);
  final txBody = _record(tx?['body']);
  final fee = _record(_record(tx?['auth_info'])?['fee']);
  final code = response['code'] is num ? (response['code'] as num).toInt() : 0;
  final rawLog = _text(response['raw_log']);
  final messages = <Map<String, Object?>>[
    if (txBody?['messages'] is List)
      for (final message in txBody!['messages'] as List)
        if (_record(message) != null) _record(message)!,
  ];
  final swap = isSwapTx(messages);
  final feeCoins = <TxFeeCoin>[];
  if (fee?['amount'] is List) {
    for (final raw in fee!['amount'] as List) {
      final coin = _firstCoin(raw);
      if (coin == null) continue;
      feeCoins.add(TxFeeCoin(
        denom: coin.denom,
        amount: coin.amount,
        scale: AmountScale.of(identityOf(chainId, coin.denom)),
      ));
    }
  }
  final error = code == 0
      ? null
      : (rawLog.isNotEmpty ? rawLog : 'The chain rejected it with code $code.');
  return TxDetailInfo(
    chainId: chainId,
    hash: hash,
    height: _text(response['height']).isEmpty ? null : _text(response['height']),
    timestamp: DateTime.tryParse(_text(response['timestamp'])),
    success: code == 0,
    error: error == null || error.length <= _maxErrorChars ? error : error.substring(0, _maxErrorChars),
    memo: _text(txBody?['memo']),
    fee: feeCoins,
    gasWanted: _text(response['gas_wanted']).isEmpty ? null : _text(response['gas_wanted']),
    gasUsed: _text(response['gas_used']).isEmpty ? null : _text(response['gas_used']),
    messages: [
      for (final message in messages)
        TxDetailMessage(
          type: shortTypeName(_typeUrlOf(message)),
          described: describeMessage(
            message,
            address,
            chainId,
            swapTx: swap,
            feeRecipients: feeRecipients,
          ),
        ),
    ],
    // A failed transaction sends nothing, whatever its messages asked for.
    packets: code == 0 ? extractPacketsFromTx(body) : const [],
    swap: swap,
  );
}

/* -------------------------------------------------------------------------- *
 * Filters
 * -------------------------------------------------------------------------- */

/// The Activity screen's filters, in the order they are offered.
enum ActivityFilter { all, sent, received, ibc, staking, claim, governance, swap }

extension ActivityFilterLabel on ActivityFilter {
  String get label => switch (this) {
        ActivityFilter.all => 'All',
        ActivityFilter.sent => 'Sent',
        ActivityFilter.received => 'Received',
        ActivityFilter.ibc => 'IBC',
        ActivityFilter.staking => 'Staking',
        ActivityFilter.claim => 'Claim',
        ActivityFilter.governance => 'Gov',
        ActivityFilter.swap => 'Swap',
      };
}

/// Whether [item] belongs under [filter]. A transfer over IBC is still a send
/// or a receipt, and claimed rewards count as staking too.
bool activityMatches(ActivityItem item, ActivityFilter filter) => switch (filter) {
      ActivityFilter.all => true,
      ActivityFilter.staking => item.kind == ActivityKind.staking || item.kind == ActivityKind.claim,
      ActivityFilter.sent =>
        item.kind == ActivityKind.sent || (item.kind == ActivityKind.ibc && item.outgoing),
      ActivityFilter.received =>
        item.kind == ActivityKind.received || (item.kind == ActivityKind.ibc && !item.outgoing),
      ActivityFilter.ibc => item.kind == ActivityKind.ibc,
      ActivityFilter.claim => item.kind == ActivityKind.claim,
      ActivityFilter.governance => item.kind == ActivityKind.governance,
      ActivityFilter.swap => item.kind == ActivityKind.swap || item.swap,
    };

/// Every word of [query] appears in the row's title, subtitle, coin, chain or hash.
bool activitySearchMatches(ActivityItem item, String query, {String? chainName}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final haystack = [
    item.title,
    item.subtitle,
    item.symbol,
    item.denom ?? '',
    item.chainId,
    chainName ?? '',
    item.hash,
    item.from ?? '',
    item.to ?? '',
  ].join(' ').toLowerCase();
  return words.every(haystack.contains);
}
