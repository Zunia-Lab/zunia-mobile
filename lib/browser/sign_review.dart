/// What a signing prompt says about a transaction a site asked Zunia to sign,
/// in either mode, shared by the in-app browser, Zunia Connect and
/// WalletConnect.
///
/// Direct bytes are decoded by the kernel, whose sentences are shown as
/// written, with each message's type URL, recipient and detail (zunia-core
/// 0.1.1 payload v2). Amino documents are described here in the kernel's own
/// words (a port of zunia-extension/lib/amino-summary.ts and lib/signing.ts),
/// so the sign mode a dApp picks does not change what the user reads. One
/// sentence is not the kernel's in either mode: a CW721 transfer names which
/// token, which collection and to whom, where the kernel names the action alone.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/packet_memo.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/util/amounts.dart';

/// One message of a transaction, in the words the prompt shows.
class ReviewMessage {
  const ReviewMessage({
    required this.type,
    required this.summary,
    this.unknown = false,
    this.recipient,
    this.detail,
  });

  /// Protobuf type URL (direct) or Amino type (amino).
  final String type;

  /// The exact sentence, never reworded after.
  final String summary;

  /// Zunia could not read it; approving it is blind signing.
  final bool unknown;

  /// The address it pays: a send's, a transfer's receiver, an NFT's new owner.
  final String? recipient;

  /// What the summary leaves out: `{kind: execute-contract, contract, msg,
  /// funds}` or `{kind: ibc-transfer, sourceChannel, receiver, token, memo}`.
  final Map<String, Object?>? detail;

  ReviewMessage copyWith({String? summary, String? recipient}) => ReviewMessage(
        type: type,
        summary: summary ?? this.summary,
        unknown: unknown,
        recipient: recipient ?? this.recipient,
        detail: detail,
      );

  Map<String, Object?> toJson() => {
        'type': type,
        'summary': summary,
        if (unknown) 'unknown': true,
        'recipient': ?recipient,
        'detail': ?detail,
      };
}

/// What the prompt needs to know about the wallet to judge a transaction.
class ReviewContext {
  const ReviewContext({
    this.chain,
    this.knownRecipients = const {},
    this.blindSigning = false,
    this.nftBridges = const {},
  });

  /// The chain signing, for naming coins; null when the catalog lacks it.
  final ChainEntry? chain;

  /// Addresses paid before or saved in the address book.
  final Set<String> knownRecipients;

  /// The user turned blind signing on (Settings, off by default).
  final bool blindSigning;

  /// cw-ics721 bridges this wallet knows on the chain.
  final Set<String> nftBridges;
}

class SignReview {
  const SignReview({
    required this.chainId,
    required this.messages,
    required this.fees,
    required this.warnings,
    required this.requiresBlindSigning,
    this.fee,
    this.memo,
    this.resolved = const [],
  });

  final String chainId;
  final List<ReviewMessage> messages;

  /// "Fee" (every coin it pays) and "Gas", or "Fee: Not specified".
  final List<(String, String)> fees;

  /// The fee as signed. Null when the document's could not be read.
  final TxFee? fee;

  final List<String> warnings;

  /// True when a message is unreadable and blind signing is off: refused.
  final bool requiresBlindSigning;

  final String? memo;

  /// Per message, same order: each coin it moves in words, for coins the
  /// chain's registry entry names. Empty for anything else.
  final List<List<String>> resolved;

  bool get hasUnknown => messages.any((m) => m.unknown);
}

/* -------------------------------------------------------------------------- *
 * Refusals
 * -------------------------------------------------------------------------- */

/// The longest "Raw transaction" a prompt is handed, in characters. Far above
/// any transaction a chain takes: CometBFT's default mempool limit is 1 MiB.
const kPreviewMaxChars = 4 * 1024 * 1024;

/// Pretty JSON for the prompt, always whole. A transaction that cannot be
/// shown whole is refused, never cut: padding placed ahead of a packet memo's
/// receiver would push what decides where the funds go out of the text the
/// prompt tells the user to check.
String previewJson(Object? value) {
  final String text;
  try {
    text = const JsonEncoder.withIndent('  ').convert(_previewable(value));
  } catch (_) {
    throw const ProviderError(
      ProviderErrorCode.unsupported,
      'This transaction cannot be shown in full',
    );
  }
  if (text.length > kPreviewMaxChars) {
    throw const ProviderError(
      ProviderErrorCode.unsupported,
      'This transaction is too large to show in full',
    );
  }
  return text;
}

Object? _previewable(Object? value) {
  if (value is Uint8List) return '${value.length} bytes';
  if (value is BigInt) return value.toString();
  if (value is Map) return {for (final e in value.entries) '${e.key}': _previewable(e.value)};
  if (value is List) return value.map(_previewable).toList();
  return value;
}

/// The refusal a site gets when a document holds a message Zunia cannot read
/// and blind signing is off. Keeps the sentence sites already match on and
/// names each unreadable type (at most five).
ProviderError blindSigningRefusal(SignReview review) {
  final types = <String>[];
  for (final message in review.messages.where((m) => m.unknown)) {
    final type = message.type.trim();
    if (type.isEmpty) continue;
    final shown = type.length > 128 ? '${type.substring(0, 127)}…' : type;
    if (!types.contains(shown)) types.add(shown);
  }
  final named = types.take(5).join(', ');
  return ProviderError(
    ProviderErrorCode.unsupported,
    'Blind signing disabled for unknown messages${named.isEmpty ? '' : ': $named'}',
  );
}

/// The chain the site asked to sign on must be the one named in the document:
/// the approval was for one chain and the signature would be valid on another.
void assertSameChain(String requested, String inDocument) {
  if (requested != inDocument) {
    throw ProviderError.invalid(
      'The document is for ${inDocument.isEmpty ? 'an unnamed chain' : inDocument}, '
      'not $requested. Zunia refused to sign it.',
    );
  }
}

/* -------------------------------------------------------------------------- *
 * Coins in words
 * -------------------------------------------------------------------------- */

final _digits = RegExp(r'^\d+$');

/// Whether [denom] is spelled the way a bank holds it: IBC mints every voucher
/// as `ibc/` + uppercase hex, so `ibc/498a…` is not the voucher it names.
bool isBankSpelling(String denom) =>
    !denom.startsWith('ibc/') || denom == 'ibc/${denom.substring(4).toUpperCase()}';

({String symbol, int decimals, bool native})? _currencyOf(ChainEntry? chain, String denom) {
  if (chain == null || denom.isEmpty || !isBankSpelling(denom)) return null;
  if (denom == chain.coinMinimalDenom && chain.coinDenom.isNotEmpty) {
    return (symbol: chain.coinDenom, decimals: chain.coinDecimals, native: true);
  }
  if (denom == chain.feeMinimalDenom && chain.feeDenom.isNotEmpty) {
    return (symbol: chain.feeDenom, decimals: chain.feeDecimals, native: true);
  }
  for (final currency in chain.currencies) {
    if (currency.coinMinimalDenom == denom && currency.coinDenom.isNotEmpty) {
      return (symbol: currency.coinDenom, decimals: currency.coinDecimals, native: false);
    }
  }
  return null;
}

/// A coin named exactly, every digit kept (`1.234567 OSMO`) when the chain's
/// registry entry names its denom; as the document spells it otherwise.
String exactCoinText(ChainEntry? chain, String amount, String denom) {
  final currency = _currencyOf(chain, denom);
  if (currency == null || !_digits.hasMatch(amount)) return '$amount $denom';
  return '${formatBaseUnitsExact(amount, decimals: currency.decimals)} ${currency.symbol}';
}

/// A fee in words: every coin it pays, since the chain deducts all of them.
String feeText(ChainEntry? chain, List<FeeCoin> coins) => coins.isEmpty
    ? 'None'
    : coins.map((c) => exactCoinText(chain, c.amount, c.denom)).join(' + ');

String _grouped(String digits) {
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// One coin a message moves, under its raw summary: `= 1.5 OSMO · native on
/// Osmosis · verified by registry`. Null unless the registry entry names it;
/// display only, nothing here is signed.
String? resolvedCoinLine(ChainEntry? chain, FeeCoin coin) {
  final currency = _currencyOf(chain, coin.denom);
  if (chain == null || currency == null || !_digits.hasMatch(coin.amount)) return null;
  final amount = formatBaseUnitsExact(coin.amount, decimals: currency.decimals);
  final where = currency.native ? 'native on ${chain.chainName}' : 'on ${chain.chainName}';
  return '= $amount ${currency.symbol} · $where · verified by registry';
}

final _coinText = RegExp(r'^(\d+) ([A-Za-z][A-Za-z0-9/:._-]*)$');

/// The kernel's summary formats that carry one coin.
final _summaryFormats = <RegExp>[
  RegExp(r'^Send (.+) to [a-z0-9]+$'),
  RegExp(r'^IBC transfer (\S+ \S+) to \S+ over \S+$'),
  RegExp(r'^(?:Delegate|Undelegate) (\S+ \S+) (?:to|from) \S+$'),
  RegExp(r'^Redelegate (\S+ \S+) from \S+ to \S+$'),
  RegExp(r'^Execute ".*" on \S+ sending (.+)$'),
];

/// The coin a kernel summary names, or none when it is not one of the formats
/// above or holds more than one coin (a forged denom can carry a comma).
List<FeeCoin> summaryCoins(String summary) {
  for (final format in _summaryFormats) {
    final match = format.firstMatch(summary);
    if (match == null) continue;
    final coin = _coinText.firstMatch(match.group(1)!);
    return coin == null ? const [] : [FeeCoin(coin.group(2)!, coin.group(1)!)];
  }
  return const [];
}

/// The coins an Amino message moves, read from its value: `amount`, `token`,
/// `funds` or `sent_funds`.
List<FeeCoin> aminoCoins(Map<String, dynamic> value) {
  final out = <FeeCoin>[];
  for (final field in [value['amount'], value['token'], value['funds'], value['sent_funds']]) {
    for (final item in field is List ? field : [field]) {
      if (item is Map &&
          item['denom'] is String &&
          (item['denom'] as String).isNotEmpty &&
          item['amount'] is String &&
          _digits.hasMatch(item['amount'] as String)) {
        out.add(FeeCoin(item['denom'] as String, item['amount'] as String));
      }
    }
  }
  return out;
}

/* -------------------------------------------------------------------------- *
 * Amino messages in the kernel's words
 * -------------------------------------------------------------------------- */

const _maxSwapHops = 8;
const _maxSwapSplits = 16;
final _u64Max = (BigInt.one << 64) - BigInt.one;

Map<String, dynamic>? _fields(Object? value) =>
    value is Map<String, dynamic> ? value : (value is Map ? Map<String, dynamic>.from(value) : null);

/// A `math.Int` as Amino writes it: digits only, no leading zero, at most 78.
String? _amount(Object? value) =>
    value is String && RegExp(r'^(?:0|[1-9]\d{0,77})$').hasMatch(value) ? value : null;

String? _positive(Object? value) {
  final text = _amount(value);
  return text != null && text != '0' ? text : null;
}

String? _uint64(Object? value) {
  final text = _amount(value);
  return text != null && BigInt.parse(text) <= _u64Max ? text : null;
}

String? _id(Object? value) {
  final text = _uint64(value);
  return text != null && text != '0' ? text : null;
}

String? _denom(Object? value) =>
    value is String && RegExp(r'^[A-Za-z][A-Za-z0-9/:._-]{2,127}$').hasMatch(value) ? value : null;

FeeCoin? _coin(Object? value, {bool aboveZero = false}) {
  final raw = _fields(value);
  if (raw == null) return null;
  final name = _denom(raw['denom']);
  final units = aboveZero ? _positive(raw['amount']) : _amount(raw['amount']);
  return name != null && units != null ? FeeCoin(name, units) : null;
}

/// A coin in the spelling the chain's Amino JSON gives it, or null.
FeeCoin? aminoCoin(Object? value) => _coin(value);

String _coinWords(FeeCoin coin) => '${coin.amount} ${coin.denom}';

/// An address a user can compare by eye: printable ASCII, no space.
String? _renderable(Object? value) {
  if (value is! String || value.isEmpty) return null;
  for (final code in value.codeUnits) {
    if (code < 0x21 || code > 0x7e) return null;
  }
  return value;
}

/// An account or a validator of the chain signing: 20 bytes of bech32.
String? _account(Object? value) {
  final text = _renderable(value);
  if (text == null) return null;
  final bytes = bech32Bytes(text);
  return bytes != null && bytes.length == 20 ? text : null;
}

typedef _Description = ({String summary, bool unknown, String? recipient, Map<String, Object?>? detail});

_Description _said(String summary, {bool unknown = false, String? recipient, Map<String, Object?>? detail}) =>
    (summary: summary, unknown: unknown, recipient: recipient, detail: detail);

_Description? Function(Map<String, dynamic>) _delegation(String verb, String preposition) =>
    (value) {
      final validator = _account(value['validator_address']);
      final staked = _coin(value['amount']);
      return _account(value['delegator_address']) != null && validator != null && staked != null
          ? _said('$verb ${_coinWords(staked)} $preposition $validator')
          : null;
    };

_Description? _redelegation(Map<String, dynamic> value) {
  final from = _account(value['validator_src_address']);
  final to = _account(value['validator_dst_address']);
  final staked = _coin(value['amount']);
  return _account(value['delegator_address']) != null && from != null && to != null && staked != null
      ? _said('Redelegate ${_coinWords(staked)} from $from to $to')
      : null;
}

_Description? _rewardClaim(Map<String, dynamic> value) {
  final validator = _account(value['validator_address']);
  return _account(value['delegator_address']) != null && validator != null
      ? _said('Claim staking rewards from $validator')
      : null;
}

String? _voteLabel(Object? option) => switch (option) {
      1 || 'VOTE_OPTION_YES' => 'Yes',
      2 || 'VOTE_OPTION_ABSTAIN' => 'Abstain',
      3 || 'VOTE_OPTION_NO' => 'No',
      4 || 'VOTE_OPTION_NO_WITH_VETO' => 'No with veto',
      _ => null,
    };

_Description? Function(Map<String, dynamic>) _vote({required bool withMetadata}) => (value) {
      final proposal = _id(value['proposal_id']);
      if (proposal == null || _account(value['voter']) == null) return null;
      if (value.containsKey('metadata') && !(withMetadata && value['metadata'] is String)) {
        return null;
      }
      final label = _voteLabel(value['option']);
      // An option outside the enum is named as such and gated, never read as a
      // default: "Yes" by mistake is the worst reading there is.
      return label != null
          ? _said('Vote $label on proposal $proposal')
          : _said('Vote on proposal $proposal with an unrecognised option', unknown: true);
    };

bool _readableTimeout(Map<String, dynamic> value) {
  final height = value.containsKey('timeout_height') ? _fields(value['timeout_height']) : <String, dynamic>{};
  if (height == null) return false;
  final counters = [height['revision_number'], height['revision_height'], value['timeout_timestamp']];
  return counters.every((counter) => counter == null || _uint64(counter) != null);
}

_Description? _transfer(Map<String, dynamic> value) {
  final channel = _renderable(value['source_channel']);
  final token = _coin(value['token']);
  final receiver = _renderable(value['receiver']);
  if (_renderable(value['source_port']) == null ||
      channel == null ||
      token == null ||
      _account(value['sender']) == null ||
      receiver == null) {
    return null;
  }
  final memo = value['memo'] ?? '';
  if (!_readableTimeout(value) || memo is! String) return null;
  return _said(
    'IBC transfer ${_coinWords(token)} to $receiver over $channel',
    recipient: receiver,
    detail: {
      'kind': 'ibc-transfer',
      'sourceChannel': channel,
      'receiver': receiver,
      'token': token.toJson(),
      'memo': memo,
    },
  );
}

typedef _Hop = ({String pool, String denom});

List<_Hop>? _route(Object? value, String denomField) {
  if (value is! List || value.isEmpty || value.length > _maxSwapHops) return null;
  final hops = <_Hop>[];
  for (final item in value) {
    final hop = _fields(item);
    final pool = hop == null ? null : _id(hop['pool_id']);
    final name = hop == null ? null : _denom(hop[denomField]);
    if (pool == null || name == null) return null;
    hops.add((pool: pool, denom: name));
  }
  return hops;
}

String _poolIds(List<_Hop> hops) => hops.map((h) => h.pool).join(' → ');

String _through(List<_Hop> hops) => '${hops.length == 1 ? 'pool' : 'pools'} ${_poolIds(hops)}';

typedef _Leg = ({List<_Hop> hops, String share});

String _throughSplit(List<_Leg> legs) {
  final pools = legs.fold<int>(0, (count, leg) => count + leg.hops.length);
  return '${legs.length} ${legs.length == 1 ? 'route' : 'routes'} '
      '(${pools == 1 ? 'pool' : 'pools'} ${legs.map((l) => _poolIds(l.hops)).join('; ')})';
}

List<_Leg>? _split(
  Object? value,
  String denomField,
  String shareField,
  String Function(List<_Hop>) end,
) {
  if (value is! List || value.isEmpty || value.length > _maxSwapSplits) return null;
  final legs = <_Leg>[];
  for (final item in value) {
    final leg = _fields(item);
    final hops = leg == null ? null : _route(leg['pools'], denomField);
    final share = leg == null ? null : _positive(leg[shareField]);
    if (hops == null || share == null) return null;
    if (legs.isNotEmpty && end(legs.first.hops) != end(hops)) return null;
    final pools = hops.map((h) => '${h.pool}:${h.denom}').join(',');
    if (legs.any((earlier) => earlier.hops.map((h) => '${h.pool}:${h.denom}').join(',') == pools)) {
      return null;
    }
    legs.add((hops: hops, share: share));
  }
  return legs;
}

String _total(List<_Leg> legs) =>
    legs.fold<BigInt>(BigInt.zero, (sum, leg) => sum + BigInt.parse(leg.share)).toString();

String _lastDenom(List<_Hop> hops) => hops.isEmpty ? '' : hops.last.denom;
String _firstDenom(List<_Hop> hops) => hops.isEmpty ? '' : hops.first.denom;

_Description? _swapExactIn(Map<String, dynamic> value) {
  final hops = _route(value['routes'], 'token_out_denom');
  final tokenIn = _coin(value['token_in'], aboveZero: true);
  final minimum = _positive(value['token_out_min_amount']);
  if (_account(value['sender']) == null || hops == null || tokenIn == null || minimum == null) {
    return null;
  }
  return _said(
    'Swap ${_coinWords(tokenIn)} for at least $minimum ${_lastDenom(hops)} through ${_through(hops)}',
  );
}

_Description? _splitExactIn(Map<String, dynamic> value) {
  final legs = _split(value['routes'], 'token_out_denom', 'token_in_amount', _lastDenom);
  final denomIn = _denom(value['token_in_denom']);
  final minimum = _positive(value['token_out_min_amount']);
  if (_account(value['sender']) == null || legs == null || denomIn == null || minimum == null) {
    return null;
  }
  final out = _lastDenom(legs.first.hops);
  return _said(
    'Swap ${_total(legs)} $denomIn for at least $minimum $out through ${_throughSplit(legs)}',
  );
}

_Description? _swapExactOut(Map<String, dynamic> value) {
  final hops = _route(value['routes'], 'token_in_denom');
  final maximum = _positive(value['token_in_max_amount']);
  final tokenOut = _coin(value['token_out'], aboveZero: true);
  if (_account(value['sender']) == null || hops == null || maximum == null || tokenOut == null) {
    return null;
  }
  return _said(
    'Swap at most $maximum ${_firstDenom(hops)} for exactly ${_coinWords(tokenOut)} through ${_through(hops)}',
  );
}

_Description? _splitExactOut(Map<String, dynamic> value) {
  final legs = _split(value['routes'], 'token_in_denom', 'token_out_amount', _firstDenom);
  final denomOut = _denom(value['token_out_denom']);
  final maximum = _positive(value['token_in_max_amount']);
  if (_account(value['sender']) == null || legs == null || denomOut == null || maximum == null) {
    return null;
  }
  final spent = _firstDenom(legs.first.hops);
  return _said(
    'Swap at most $maximum $spent for exactly ${_total(legs)} $denomOut through ${_throughSplit(legs)}',
  );
}

final Map<String, _Description? Function(Map<String, dynamic>)> _describers = {
  'cosmos-sdk/MsgDelegate': _delegation('Delegate', 'to'),
  'cosmos-sdk/MsgUndelegate': _delegation('Undelegate', 'from'),
  'cosmos-sdk/MsgBeginRedelegate': _redelegation,
  'cosmos-sdk/MsgWithdrawDelegationReward': _rewardClaim,
  'cosmos-sdk/MsgVote': _vote(withMetadata: false),
  'cosmos-sdk/v1/MsgVote': _vote(withMetadata: true),
  'cosmos-sdk/MsgTransfer': _transfer,
  'osmosis/poolmanager/swap-exact-amount-in': _swapExactIn,
  'osmosis/poolmanager/split-amount-in': _splitExactIn,
  'osmosis/poolmanager/swap-exact-amount-out': _swapExactOut,
  'osmosis/poolmanager/split-amount-out': _splitExactOut,
};

/// Every Amino type [describeAminoMsg] reads.
List<String> get describedAminoTypes => _describers.keys.toList();

/// The kernel's sentence for an Amino message of one of the described types,
/// or null for any other type and for one not in the shape the chain's Amino
/// JSON gives it, which the caller shows with its generic summary.
ReviewMessage? describeAminoMsg(String type, Object? value) {
  final describe = _describers[type];
  final body = _fields(value);
  final said = describe != null && body != null ? describe(body) : null;
  return said == null
      ? null
      : ReviewMessage(
          type: type,
          summary: said.summary,
          unknown: said.unknown,
          recipient: said.recipient,
          detail: said.detail,
        );
}

/* -------------------------------------------------------------------------- *
 * Contract calls and CW721
 * -------------------------------------------------------------------------- */

/// Whether a contract message's top-level key can be quoted: a plain name,
/// the kernel's own rule (`^[A-Za-z0-9_-]{1,128}$`).
bool isPlainContractAction(String key) => RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key);

/// The action an ExecuteMsg declares (its single top-level key), when it is a
/// plain name.
String? cosmWasmActionName(Object? body) {
  final parsed = _fields(body);
  if (parsed == null || parsed.length != 1) return null;
  final key = parsed.keys.single;
  return isPlainContractAction(key) ? key : null;
}

/// A contract message whose single top-level key is not a plain name: the
/// kernel reads it as unknown, and so does this.
bool hasUnreadableContractAction(Object? body) {
  final parsed = _fields(body);
  return parsed != null && parsed.length == 1 && !isPlainContractAction(parsed.keys.single);
}

String? _nonEmpty(Object? value) => value is String && value.isNotEmpty ? value : null;

sealed class Cw721Action {
  const Cw721Action(this.collection, this.tokenId);
  final String collection;
  final String tokenId;
}

final class Cw721Transfer extends Cw721Action {
  const Cw721Transfer(super.collection, super.tokenId, this.recipient);
  final String recipient;
}

final class Cw721Send extends Cw721Action {
  const Cw721Send(super.collection, super.tokenId, this.receivingContract, this.ics721);
  final String receivingContract;

  /// Read only from a bridge this wallet knows: any contract can be handed a
  /// payload shaped like a bridge's, and keep the NFT.
  final ({String receiver, String channelId})? ics721;
}

const kCw721FundsWarning =
    'This message also sends coins. A CW721 transfer takes none, so check what you are approving.';

/// A CW721 `transfer_nft` or `send_nft`, read from the contract call, with
/// what the prompt should note about it. Null for anything else.
({Cw721Action action, List<String> warnings})? describeCw721Action(
  String contract,
  Object? body,
  Object? funds, {
  Set<String> bridges = const {},
}) {
  final parsed = _fields(body);
  // An ExecuteMsg is one variant: a body with a second key is not a call the
  // contract would run, so it is not described as one.
  if (contract.isEmpty || parsed == null || parsed.length != 1) return null;
  final warnings = <String>[if (funds is List && funds.isNotEmpty) kCw721FundsWarning];

  final transfer = _fields(parsed['transfer_nft']);
  if (transfer != null) {
    final recipient = _nonEmpty(transfer['recipient']);
    final tokenId = _nonEmpty(transfer['token_id']);
    if (recipient == null || tokenId == null) return null;
    return (action: Cw721Transfer(contract, tokenId, recipient), warnings: warnings);
  }

  final send = _fields(parsed['send_nft']);
  if (send != null) {
    final receiving = _nonEmpty(send['contract']);
    final tokenId = _nonEmpty(send['token_id']);
    final inner = send['msg'];
    if (receiving == null || tokenId == null || inner is! String) return null;
    Object? innerValue;
    try {
      innerValue = jsonDecode(utf8.decode(base64.decode(base64.normalize(inner))));
    } catch (_) {
      return null;
    }
    final outgoing = bridges.contains(receiving) ? _fields(innerValue) : null;
    final receiver = outgoing == null ? null : _nonEmpty(outgoing['receiver']);
    final channelId = outgoing == null ? null : _nonEmpty(outgoing['channel_id']);
    return (
      action: Cw721Send(
        contract,
        tokenId,
        receiving,
        receiver != null && channelId != null ? (receiver: receiver, channelId: channelId) : null,
      ),
      warnings: warnings,
    );
  }
  return null;
}

final _hiddenCharacters = RegExp(r'[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]', unicode: true);
final _ibcChannel = RegExp(r'^channel-\d{1,20}$');

/// A token id the prompt can quote inside its sentence.
bool _shownTokenId(String value) => value.isNotEmpty && !_hiddenCharacters.hasMatch(value);

/// Coins as the kernel writes them when every one is spelled as the chain
/// writes it: "" for none, null when one is not.
String? _checkedCoinsText(Object? funds) {
  if (funds == null) return '';
  if (funds is! List) return null;
  final words = <String>[];
  for (final item in funds) {
    final coin = aminoCoin(item);
    if (coin == null) return null;
    words.add(_coinWords(coin));
  }
  return words.join(', ');
}

/// A CW721 transfer in words, or null so the caller keeps the kernel's
/// sentence: unless the collection and the recipient or contract are
/// addresses of one chain, the token id hides nothing and the coins are spelled
/// as the chain spells them (these are the site's words inside the wallet's).
({String summary, String recipient})? _describeNftCall(
  String contract,
  Object? body,
  Object? funds,
  Set<String> bridges,
) {
  final described = describeCw721Action(contract, body, funds, bridges: bridges);
  final prefix = shownAddressPrefix(contract);
  final sending = _checkedCoinsText(funds);
  if (described == null || prefix == null || sending == null || !_shownTokenId(described.action.tokenId)) {
    return null;
  }
  final coins = sending.isEmpty ? '' : ' sending $sending';
  switch (described.action) {
    case Cw721Transfer(:final tokenId, :final collection, :final recipient):
      if (shownAddressPrefix(recipient) != prefix) return null;
      return (
        summary: 'Give away NFT $tokenId from collection $collection to $recipient$coins',
        recipient: recipient,
      );
    case Cw721Send(:final tokenId, :final collection, :final receivingContract, :final ics721):
      if (shownAddressPrefix(receivingContract) != prefix) return null;
      final bridged = ics721 != null &&
              _ibcChannel.hasMatch(ics721.channelId) &&
              shownAddressPrefix(ics721.receiver) != null
          ? ', which says it bridges it across ${ics721.channelId} to ${ics721.receiver}'
          : '';
      return (
        summary: 'Hand NFT $tokenId from collection $collection to contract $receivingContract$coins$bridged',
        recipient: receivingContract,
      );
  }
}

String? _coinsText(Object? coins) {
  if (coins is! List || coins.isEmpty) return null;
  return coins.map((coin) {
    final c = coin is Map ? coin : const {};
    return '${c['amount'] ?? '?'} ${c['denom'] ?? ''}'.trim();
  }).join(', ');
}

List<FeeCoin>? _wellFormedCoins(Object? value) {
  if (value == null) return const [];
  if (value is! List) return null;
  final coins = <FeeCoin>[];
  for (final item in value) {
    if (item is! Map || item['denom'] is! String || item['amount'] is! String) return null;
    coins.add(FeeCoin(item['denom'] as String, item['amount'] as String));
  }
  return coins;
}

ReviewMessage _summarizeExecuteContract(String type, Map<String, dynamic> value, Set<String> bridges) {
  final contract = value['contract'] is String ? value['contract'] as String : '';
  // wasmd renamed `sent_funds` to `funds`; both appear depending on the SDK.
  final funds = value['funds'] ?? value['sent_funds'];
  final coins = _wellFormedCoins(funds);
  final detail = contract.isNotEmpty && value.containsKey('msg') && coins != null
      ? <String, Object?>{
          'kind': 'execute-contract',
          'contract': contract,
          'msg': value['msg'],
          'funds': [for (final c in coins) c.toJson()],
        }
      : null;

  final nft = _describeNftCall(contract, value['msg'], funds, bridges);
  if (nft != null) {
    return ReviewMessage(type: type, summary: nft.summary, recipient: nft.recipient, detail: detail);
  }

  final action = cosmWasmActionName(value['msg']);
  final sending = _coinsText(funds);
  final target = contract.isEmpty ? 'an unnamed contract' : contract;
  // An action key that is not a plain name is never quoted, and the call
  // counts as unreadable, as the kernel does in direct mode.
  return ReviewMessage(
    type: type,
    summary: action != null
        ? 'Execute "$action" on $target${sending == null ? '' : ' sending $sending'}'
        : 'Execute a contract call on $target that Zunia could not read',
    unknown: hasUnreadableContractAction(value['msg']),
    detail: detail,
  );
}

/// Amino messages in the kernel's words.
List<ReviewMessage> summarizeAminoMsgs(List<Object?> msgs, {Set<String> bridges = const {}}) {
  return msgs.map((raw) {
    final msg = _fields(raw) ?? const <String, dynamic>{};
    final type = msg['type'] is String && (msg['type'] as String).isNotEmpty
        ? msg['type'] as String
        : 'unknown';
    final value = _fields(msg['value']) ?? const <String, dynamic>{};
    if (type == 'wasm/MsgExecuteContract' || type.endsWith('MsgExecuteContract')) {
      return _summarizeExecuteContract(type, value, bridges);
    }
    if (type == 'cosmos-sdk/MsgSend' || type.endsWith('MsgSend')) {
      final to = '${value['to_address'] ?? value['toAddress'] ?? ''}';
      final amount = value['amount'] is List
          ? (value['amount'] as List).map((a) {
              final c = a is Map ? a : const {};
              return '${c['amount'] ?? '?'} ${c['denom'] ?? ''}'.trim();
            }).join(', ')
          : '?';
      return ReviewMessage(
        type: type,
        summary: 'Send $amount to ${to.isEmpty ? 'unknown' : to}',
        recipient: to.isEmpty ? null : to,
      );
    }
    final described = describeAminoMsg(type, value);
    if (described != null) return described;
    // Anything else, including one of those types in a shape the chain would
    // not rebuild, keeps the generic line; a type without "Msg" is gated.
    return ReviewMessage(type: type, summary: 'Message $type', unknown: !type.contains('Msg'));
  }).toList();
}

/* -------------------------------------------------------------------------- *
 * The review
 * -------------------------------------------------------------------------- */

/// Told whenever a transfer carries a packet memo, beside the note that says
/// where it sends the tokens.
const kPacketMemoNotice =
    'This transfer carries instructions for the receiving chain (packet memo). Check them under Raw transaction.';

const kBlindSigningOffWarning =
    'Blind signing is off. Enable it in settings to approve undecoded messages.';

SignReview buildSignReview({
  required String expectedChainId,
  required String decodedChainId,
  required List<ReviewMessage> messages,
  required ReviewContext context,
  String? memo,
  TxFee? fee,
  List<List<FeeCoin>>? coins,
}) {
  // "unknown" is what a kernel that cannot read the document reports; the raw
  // document's own chain id has already been checked by the caller.
  if (decodedChainId.isNotEmpty && decodedChainId != 'unknown') {
    assertSameChain(expectedChainId, decodedChainId);
  }
  final warnings = <String>[];
  final notes = <String>{};
  var unknown = false;
  for (final m in messages) {
    if (m.unknown) {
      warnings.add('Unknown or undecoded message: ${m.type}');
      unknown = true;
    }
    final recipient = m.recipient;
    if (recipient != null && !context.knownRecipients.contains(recipient)) {
      warnings.add('First-time recipient: $recipient');
    }
    final detail = m.detail;
    if (detail?['kind'] == 'execute-contract') {
      final described = describeCw721Action(
        '${detail!['contract']}',
        detail['msg'],
        detail['funds'],
      );
      notes.addAll(described?.warnings ?? const []);
    }
    if (detail?['kind'] == 'ibc-transfer' && '${detail!['memo'] ?? ''}'.trim().isNotEmpty) {
      notes.add(kPacketMemoNotice);
      final where = packetMemoNote('${detail['memo']}');
      if (where != null) notes.add(where);
    }
  }
  warnings.addAll(notes);
  if (unknown && !context.blindSigning) warnings.add(kBlindSigningOffWarning);

  final fees = fee == null
      ? const [('Fee', 'Not specified')]
      : [
          ('Fee', feeText(context.chain, fee.amount)),
          ('Gas', _digits.hasMatch(fee.gas) ? _grouped(fee.gas) : fee.gas),
        ];

  final resolved = [
    for (var i = 0; i < messages.length; i++)
      messages[i].unknown
          ? const <String>[]
          : [
              for (final coin in (coins != null && i < coins.length ? coins[i] : summaryCoins(messages[i].summary)))
                ?resolvedCoinLine(context.chain, coin),
            ],
  ];

  return SignReview(
    chainId: decodedChainId.isEmpty || decodedChainId == 'unknown' ? expectedChainId : decodedChainId,
    messages: messages,
    fees: fees,
    fee: fee,
    warnings: warnings,
    requiresBlindSigning: unknown && !context.blindSigning,
    memo: memo,
    resolved: resolved,
  );
}

/// An Amino fee in which every coin and the gas limit are spelled as the chain
/// writes them, or null.
TxFee? _aminoFee(Object? value) {
  final fee = _fields(value);
  if (fee == null) return null;
  final limit = _uint64(fee['gas']);
  final amount = fee['amount'];
  if (amount is! List || limit == null) return null;
  final coins = <FeeCoin>[];
  for (final item in amount) {
    final coin = aminoCoin(item);
    if (coin == null) return null;
    coins.add(coin);
  }
  return TxFee(coins, limit);
}

/// The chain an Amino sign doc names, or INVALID_PARAMS.
String aminoSignDocChainId(Object? signDoc) {
  if (signDoc is! Map) throw const ProviderError.invalid('signDoc must be an object');
  final chainId = signDoc['chain_id'];
  if (chainId is! String || chainId.isEmpty) {
    throw const ProviderError.invalid('signDoc.chain_id is missing');
  }
  if (signDoc['msgs'] is! List) throw const ProviderError.invalid('signDoc.msgs must be an array');
  return chainId;
}

SignReview reviewAminoSignDoc({
  required String expectedChainId,
  required Map<String, dynamic> signDoc,
  required ReviewContext context,
}) {
  final msgs = signDoc['msgs'] is List ? (signDoc['msgs'] as List).cast<Object?>() : const <Object?>[];
  return buildSignReview(
    expectedChainId: expectedChainId,
    decodedChainId: signDoc['chain_id'] is String ? signDoc['chain_id'] as String : expectedChainId,
    messages: summarizeAminoMsgs(msgs, bridges: context.nftBridges),
    context: context,
    memo: signDoc['memo'] is String ? signDoc['memo'] as String : null,
    fee: _aminoFee(signDoc['fee']),
    coins: [
      for (final msg in msgs)
        msg is Map && msg['value'] is Map
            ? aminoCoins(Map<String, dynamic>.from(msg['value'] as Map))
            : const <FeeCoin>[],
    ],
  );
}

/// The prefix `zunia-cosmos` gives a message it could not decode.
const _unknownSummaryPrefix = 'UNKNOWN ACTION:';

/// The kernel's payload v2 as review messages; every message unknown when the
/// payload is not v2 or says something is unreadable while no message owns up
/// to it (erring toward more gating costs one confirmation, the other way lets
/// an unreadable message through a screen that called it safe).
({String chainId, String memo, TxFee? fee, List<ReviewMessage> messages}) adaptKernelPayload(
  Map<String, dynamic> decoded,
) {
  final chainId = decoded['chainId'] is String ? decoded['chainId'] as String : 'unknown';
  final memo = decoded['memo'] is String ? decoded['memo'] as String : '';
  final messages = decoded['messages'];
  final summaries = decoded['summaries'];
  final fee = decoded['fee'];
  final v2 = messages is List &&
      summaries is List &&
      messages.length == summaries.length &&
      fee is Map &&
      fee['amount'] is List &&
      fee['gasLimit'] is String &&
      decoded['accountNumber'] is String &&
      [
        for (var i = 0; i < messages.length; i++)
          messages[i] is Map &&
              (messages[i] as Map)['typeUrl'] is String &&
              (messages[i] as Map)['summary'] == summaries[i] &&
              (messages[i] as Map)['unknown'] is bool,
      ].every((ok) => ok);
  if (!v2) {
    final lines = summaries is List ? summaries.map((s) => '$s').toList() : const <String>[];
    return (
      chainId: chainId,
      memo: memo,
      fee: null,
      messages: [
        for (final line in lines)
          ReviewMessage(type: line.startsWith(_unknownSummaryPrefix) ? '/unknown.Msg' : '', summary: line, unknown: true),
      ],
    );
  }
  final rows = messages.cast<Map>();
  final unknownAt = [
    for (final m in rows) m['unknown'] == true || '${m['summary']}'.startsWith(_unknownSummaryPrefix),
  ];
  final unexplained = decoded['hasUnknownMsgs'] == true && !unknownAt.contains(true);
  TxFee? txFee;
  final coins = <FeeCoin>[];
  var readable = true;
  for (final coin in (fee['amount'] as List)) {
    if (coin is Map && coin['denom'] is String && coin['amount'] is String) {
      coins.add(FeeCoin(coin['denom'] as String, coin['amount'] as String));
    } else {
      readable = false;
    }
  }
  if (readable) txFee = TxFee(coins, fee['gasLimit'] as String);
  return (
    chainId: chainId,
    memo: memo,
    fee: txFee,
    messages: [
      for (var i = 0; i < rows.length; i++)
        if (unknownAt[i] || unexplained)
          ReviewMessage(type: '${rows[i]['typeUrl']}', summary: '${rows[i]['summary']}', unknown: true)
        else
          ReviewMessage(
            type: '${rows[i]['typeUrl']}',
            summary: '${rows[i]['summary']}',
            recipient: rows[i]['recipient'] is String && (rows[i]['recipient'] as String).isNotEmpty
                ? rows[i]['recipient'] as String
                : null,
            detail: _detailOf(rows[i]['detail']),
          ),
    ],
  );
}

Map<String, Object?>? _detailOf(Object? value) {
  if (value is! Map) return null;
  final detail = Map<String, Object?>.from(value);
  if (detail['kind'] == 'execute-contract') {
    return detail['contract'] is String && detail.containsKey('msg') && detail['funds'] is List
        ? detail
        : null;
  }
  if (detail['kind'] == 'ibc-transfer') {
    return detail['receiver'] is String && detail['sourceChannel'] is String && detail['memo'] is String
        ? detail
        : null;
  }
  return null;
}

/// The kernel's messages with a CW721 transfer worded as the Amino path words
/// it; every other summary exactly as the kernel wrote it.
List<ReviewMessage> withNftSentences(List<ReviewMessage> messages, Set<String> bridges) {
  return messages.map((message) {
    final detail = message.detail;
    if (message.unknown || detail?['kind'] != 'execute-contract') return message;
    final nft = _describeNftCall('${detail!['contract']}', detail['msg'], detail['funds'], bridges);
    if (nft == null) return message;
    return ReviewMessage(
      type: message.type,
      summary: nft.summary,
      recipient: nft.recipient,
      detail: detail,
    );
  }).toList();
}

/// Summarize the exact `SignDoc` bytes that will be signed. The kernel decodes
/// the same bytes the signature covers, so the prompt cannot describe one
/// transaction while the key signs another.
SignReview reviewDirectSignBytes({
  required String expectedChainId,
  required Uint8List signBytes,
  required ReviewContext context,
}) {
  final Map<String, dynamic> decoded;
  try {
    decoded = WalletKernel.instance.decodeDirect(signBytes);
  } on ProviderError {
    rethrow;
  } catch (e) {
    throw ProviderError.invalid('Zunia could not read this transaction: $e');
  }
  final payload = adaptKernelPayload(decoded);
  return buildSignReview(
    expectedChainId: expectedChainId,
    decodedChainId: payload.chainId,
    messages: withNftSentences(payload.messages, context.nftBridges),
    context: context,
    memo: payload.memo,
    fee: payload.fee,
  );
}

/// The Direct transaction as the prompt's "Raw transaction" shows it: the fee
/// as signed, every coin of it, and each message with what its summary leaves
/// out (a contract call's message and coins, a transfer's packet memo).
String directPreviewJson(SignReview review) => previewJson({
      'chainId': review.chainId,
      'memo': review.memo ?? '',
      'fee': review.fee == null
          ? null
          : {
              'amount': [for (final c in review.fee!.amount) c.toJson()],
              'gas': review.fee!.gas,
            },
      'messages': [for (final m in review.messages) m.toJson()],
    });
