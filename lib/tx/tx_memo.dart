/// Transaction-body memos Zunia writes when the user leaves the field empty.
///
/// Port of `zunia-extension/lib/tx-memo.ts` (0.1.5). This is the Cosmos
/// `tx.body.memo`, visible on explorers and permanent, so a token is named in
/// it only when its identity is proven on the chain that signs (`Send USDC.n`
/// for Noble's own USDC). A token nothing proves gets the generic phrase
/// (`Send`). It is never written onto an ICS20 / PFM / ibc-hooks packet memo:
/// those are protocol JSON and live on the message.
library;

import 'dart:convert';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

const String zuniaWalletTag = 'by Zunia-wallet';
const int _maxMemoChars = 256;

/// Keep a user-written memo; when blank, write a type-specific Zunia default
/// that always ends with [zuniaWalletTag]. [chainId] is the chain that signs
/// [msgs]: their coin denoms are its bank denoms, so it names them.
String resolveTxMemo(String? userMemo, List<TxMsg> msgs, [String? chainId]) {
  final custom = (userMemo ?? '').trim();
  if (custom.isNotEmpty) return custom;
  return defaultTxMemo(msgs, chainId);
}

String defaultTxMemo(List<TxMsg> msgs, [String? chainId]) => _withTag(_phraseFor(msgs, chainId));

String _withTag(String phrase) {
  const tag = ' · $zuniaWalletTag';
  if (phrase.length + tag.length <= _maxMemoChars) return '$phrase$tag';
  final keep = _maxMemoChars - tag.length - 1;
  return '${phrase.substring(0, keep < 1 ? 1 : keep)}…$tag';
}

/// A transaction is named by its first message; several claims read as one.
String _phraseFor(List<TxMsg> msgs, String? chainId) {
  if (msgs.isEmpty) return 'Signed';
  final phrases = [for (final msg in msgs) _phraseForOne(msg, chainId)];
  if (phrases.length > 1 && phrases.every((line) => line.startsWith('Claim rewards'))) {
    return 'Claim rewards';
  }
  return phrases.first;
}

enum _Kind {
  send, ibc, ibcForward, swap, swapCall, poolSwap, stake, unstake, redelegate, claim, vote, nft,
  nftIbc, recover, contract, other,
}

String _phraseForOne(TxMsg msg, String? chainId) {
  final kind = _messageKind(msg);
  final value = msg.value;
  final symbol = _tokenSymbol(_firstCoinDenom(value), chainId, kind);
  switch (kind) {
    case _Kind.send:
      return _labeled('Send', symbol);
    case _Kind.ibc:
      return _labeled('IBC transfer', symbol);
    case _Kind.ibcForward:
      return _labeled('IBC forward', symbol);
    case _Kind.swap:
      return _labeled('Swap', symbol);
    case _Kind.swapCall:
      return _swapCallPhrase(value, chainId);
    case _Kind.poolSwap:
      return _poolSwapPhrase(value, chainId);
    case _Kind.stake:
      return _labeled('Stake', symbol);
    case _Kind.unstake:
      return _labeled('Unstake', symbol);
    case _Kind.redelegate:
      return _labeled('Redelegate', symbol);
    case _Kind.claim:
      return 'Claim rewards';
    case _Kind.vote:
      return _votePhrase(value);
    case _Kind.nft:
      return 'NFT transfer';
    case _Kind.nftIbc:
      return 'NFT IBC send';
    case _Kind.recover:
      return 'Recover funds';
    case _Kind.contract:
      return 'Contract call';
    case _Kind.other:
      return 'Signed';
  }
}

String _labeled(String action, String? symbol) => symbol == null ? action : '$action $symbol';

_Kind _messageKind(TxMsg msg) {
  final type = msg.typeUrl.toLowerCase();
  if (type.contains('beginredelegate')) return _Kind.redelegate;
  if (type.contains('undelegate')) return _Kind.unstake;
  if (type.contains('delegate') && !type.contains('withdraw')) return _Kind.stake;
  if (type.contains('withdrawdelegat') || type.contains('withdrawdelegationreward')) return _Kind.claim;
  if (type.contains('msgvote') || type.endsWith('/vote')) return _Kind.vote;
  if (type.contains('msgsend') || type.contains('multisend')) return _Kind.send;
  if (type.contains('msgtransfer') || type.contains('ibc.applications.transfer')) {
    final packet = _packetMemoKind(msg.value);
    if (packet == 'swap') return _Kind.swap;
    if (packet == 'forward') return _Kind.ibcForward;
    return _Kind.ibc;
  }
  if (type.contains('poolmanager') &&
      (type.contains('msgswapexactamountin') || type.contains('msgsplitrouteswapexactamountin'))) {
    return _Kind.poolSwap;
  }
  if (type.contains('executecontract') || type.contains('wasm/msgexecute')) {
    final action = _wasmAction(msg.value);
    if (action == 'transfer_nft') return _Kind.nft;
    if (action == 'send_nft') return _Kind.nftIbc;
    if (action == 'recover' || action == 'recover_failed' || action == 'retrieve') return _Kind.recover;
    if (action == 'osmosis_swap') return _Kind.swapCall;
    return _Kind.contract;
  }
  return _Kind.other;
}

String? _packetMemoKind(Map<String, dynamic> value) {
  final memo = value['memo'];
  if (memo is! String || memo.trim().isEmpty) return null;
  try {
    final parsed = jsonDecode(memo);
    if (parsed is! Map) return null;
    if (parsed['wasm'] != null) return 'swap';
    if (parsed['forward'] != null) return 'forward';
  } on FormatException {
    // Plain text on the packet is not a Zunia default. Leave it alone.
  }
  return null;
}

Map<String, Object?>? _decodeWasmMsg(Object? raw) {
  if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
  if (raw is! String || raw.isEmpty) return null;
  Map<String, Object?>? tryJson(String text) {
    try {
      final parsed = jsonDecode(text);
      return parsed is Map ? parsed.map((key, value) => MapEntry('$key', value)) : null;
    } on FormatException {
      return null;
    }
  }

  final asJson = tryJson(raw);
  if (asJson != null) return asJson;
  try {
    return tryJson(utf8.decode(base64.decode(raw)));
  } on Object {
    return null;
  }
}

String? _wasmAction(Map<String, dynamic> value) {
  final parsed = _decodeWasmMsg(value['msg']);
  return parsed == null || parsed.isEmpty ? null : parsed.keys.first;
}

bool _isCoin(Object? value) => value is Map && value['denom'] is String && (value['denom'] as String).isNotEmpty;

String? _firstCoinDenom(Map<String, dynamic> value) {
  if (_isCoin(value['token'])) return (value['token'] as Map)['denom'] as String;
  if (_isCoin(value['amount'])) return (value['amount'] as Map)['denom'] as String;
  final amount = value['amount'];
  if (amount is List && amount.isNotEmpty && _isCoin(amount.first)) {
    return (amount.first as Map)['denom'] as String;
  }
  return null;
}

String _swapCallPhrase(Map<String, dynamic> value, String? chainId) {
  final msg = _decodeWasmMsg(value['msg']);
  if (msg == null || msg.length != 1) return 'Contract call';
  final swap = msg['osmosis_swap'];
  if (swap is! Map) return 'Contract call';
  final output = swap['output_denom'];
  final funds = value['funds'];
  if (output is! String || output.isEmpty) return 'Contract call';
  if (funds is! List || funds.length != 1 || !_isCoin(funds.first)) return 'Contract call';
  final sold = _tokenSymbol((funds.first as Map)['denom'] as String, chainId, _Kind.swapCall);
  final bought = _tokenSymbol(output, chainId, _Kind.swapCall);
  return sold != null && bought != null ? 'Swap $sold to $bought' : 'Contract call';
}

String _poolSwapPhrase(Map<String, dynamic> value, String? chainId) {
  final tokenIn = value['token_in'];
  final soldDenom = _isCoin(tokenIn) ? (tokenIn as Map)['denom'] as String : '${value['token_in_denom'] ?? ''}'.trim();
  final routes = value['routes'] is List ? value['routes'] as List : const [];
  Object? lastHop;
  if (routes.isNotEmpty) {
    final first = routes.first;
    if (first is Map && first['pools'] is List && (first['pools'] as List).isNotEmpty) {
      lastHop = (first['pools'] as List).last;
    } else {
      lastHop = routes.last;
    }
  }
  final outputDenom = lastHop is Map ? '${lastHop['token_out_denom'] ?? ''}'.trim() : '';
  if (soldDenom.isEmpty || outputDenom.isEmpty) return 'Swap';
  final sold = _tokenSymbol(soldDenom, chainId, _Kind.swapCall);
  final bought = _tokenSymbol(outputDenom, chainId, _Kind.swapCall);
  return sold != null && bought != null ? 'Swap $sold to $bought' : 'Swap';
}

String _votePhrase(Map<String, dynamic> value) {
  final id = '${value['proposal_id'] ?? value['proposalId'] ?? ''}'.trim();
  final option = _voteLabel(value['option']);
  if (id.isNotEmpty && option != null) return 'Vote $option on #$id';
  if (option != null) return 'Vote $option';
  if (id.isNotEmpty) return 'Vote on #$id';
  return 'Vote';
}

String? _voteLabel(Object? option) {
  if (option is num) return const {1: 'Yes', 2: 'Abstain', 3: 'No', 4: 'Veto'}[option.toInt()];
  final raw = '${option ?? ''}'
      .trim()
      .toUpperCase()
      .replaceFirst('VOTE_OPTION_', '')
      .replaceFirst(RegExp(r'_WITH_VETO$'), '');
  return switch (raw) {
    'YES' => 'Yes',
    'NO' => 'No',
    'ABSTAIN' => 'Abstain',
    'VETO' || 'NO_WITH_VETO' => 'Veto',
    _ => null,
  };
}

const Set<_Kind> _stakingKinds = {_Kind.stake, _Kind.unstake, _Kind.redelegate};

final RegExp _tracedPrefix = RegExp(r'^(?:[a-z0-9._-]+/channel-\d+/)+', caseSensitive: false);

/// The identity a message's coin has for the memo. With the signing chain the
/// denom is that chain's bank denom; without it, a plain denom is named only
/// when every bundled chain that could be signing it agrees on its ticker.
TokenIdentity? _memoIdentity(String denom, String? chainId, _Kind kind) {
  if (chainId != null) return identityOf(chainId, denom);
  if (denom.startsWith('ibc/') || denom.replaceFirst(_tracedPrefix, '') != denom) return null;
  if (!ChainCatalog.isLoaded) return null;
  final listing = [
    for (final entry in ChainCatalog.instance.registryOnly)
      if (entry.coinMinimalDenom == denom ||
          entry.feeMinimalDenom == denom ||
          currenciesOf(entry).any((row) => denomsMatch(row.coinMinimalDenom, denom)))
        entry,
  ];
  final staking = _stakingKinds.contains(kind)
      ? [for (final entry in listing) if (entry.coinMinimalDenom == denom) entry]
      : const <ChainEntry>[];
  final candidates = staking.isNotEmpty ? staking : listing;
  final mainnets = [for (final entry in candidates) if (entry.network == 'mainnet') entry];
  final named = [
    for (final entry in mainnets.isNotEmpty ? mainnets : candidates) identityOf(entry.chainId, denom),
  ];
  if (named.isEmpty) return null;
  final first = named.first;
  return named.every((identity) => identity.proven && identity.ticker == first.ticker) ? first : null;
}

/// The ticker the memo names a coin by, or null for the generic phrase. Only
/// a proven identity names it: the memo is written on chain for good.
String? _tokenSymbol(String? denom, String? chainId, _Kind kind) {
  if (denom == null || denom.isEmpty) return null;
  final identity = _memoIdentity(denom, chainId, kind);
  return identity != null && identity.proven ? identity.ticker : null;
}
