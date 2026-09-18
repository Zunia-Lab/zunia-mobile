/// CW721 reads, NFT message building, and ICS721 cross-chain transfers.
///
/// Dart mirror of `nft.ts`, module for module and name for name. The four rules
/// of the TypeScript original hold here too:
///
/// 1. It never signs. `build*Msg` returns an [NftExecute] that
///    `crypto/amino_tx.dart` encodes and signs; no key material comes near this
///    file.
/// 2. It never opens a socket itself. Chain reads go through [LcdClient];
///    off-chain metadata reads go through a caller-supplied
///    [NftMetadataFetcher].
/// 3. It never resolves `token_uri` on its own. That URI usually points at a
///    third-party host, so loading it tells that host which wallet holds which
///    NFT, from which IP address. The caller has to opt in by handing in a
///    fetcher and a gateway list; there is no default transport and no default
///    gateway on purpose.
/// 4. Everything is gated on the chain declaring the `cosmwasm` feature. A
///    chain without it gets `unsupportedChain`, not a confusing HTTP error.
///
/// Query and execute shapes are copied from INTERCHAIN-SPEC.md §6-7, never
/// derived. Where a shape is *not* in the spec — the ICS721 `IbcOutgoingMsg`
/// timeout, the newer `collection_info` extension object — it is parsed
/// defensively and the comment says so.
///
/// Three deliberate divergences from `nft.ts`, each marked DIVERGENCE below:
///
/// - `BuiltMsg` becomes [NftExecute], which carries the execute body rather
///   than proto-JSON with a base64 `msg`. Mobile's encoder lives in
///   `crypto/amino_tx.dart` and needs the object, not the bytes; the same split
///   `tracking.dart` already makes for `XcsRecovery`.
/// - The CosmWasm gate's "treat an unknown feature list as capable" escape
///   hatch lives on [NftChainContext] rather than on every call, so two call
///   sites in one screen cannot disagree about what the chain supports.
/// - [inspectNftExecute] has no TypeScript twin. A CW721 transfer is an opaque
///   `MsgExecuteContract` to a signing screen, and "Execute contract" is not
///   informed consent, so the message is decoded back out of the body that will
///   actually be signed.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'lcd.dart';
import 'types.dart';

/* -------------------------------------------------------------------------- *
 * Constants
 * -------------------------------------------------------------------------- */

/// The registry capability every function in this module requires.
const String cosmWasmFeature = 'cosmwasm';

/// Page size the spec's `tokens` example uses.
const int defaultTokenPageLimit = 30;

/// cw721 clamps `limit` internally, so asking for more just returns fewer and
/// makes the "is there another page?" test unreliable. Clamp on our side too.
const int maxTokenPageLimit = 100;

/// Safety stop for the paginating helpers, so a hostile contract cannot loop us.
const int defaultMaxPages = 20;

/// Contracts probed per discovery run, unless the caller raises it.
const int defaultMaxDiscoveryContracts = 25;

/// Token ids pulled per contract during discovery.
const int defaultMaxDiscoveryTokens = 100;

/// Default ICS721 packet timeout.
///
/// TODO-VERIFY: cw-ics721's `IbcOutgoingMsg.timeout` is not optional as far as
/// we can tell, so a timeout is always emitted rather than omitted. Ten minutes
/// matches the PFM examples in the spec.
const int defaultIcs721TimeoutMinutes = 10;

/// What the user has to be told before an ICS721 transfer.
///
/// The destination chain does not receive "the NFT". It mints a debt-voucher
/// NFT backed by the original, which stays escrowed in the bridge contract on
/// the source chain. Marketplaces on the destination may not recognise it, and
/// the only way back is to send the voucher home, which burns it and releases
/// the original.
const String ics721VoucherWarning =
    'The destination chain mints a voucher NFT backed by this one. The '
    'original stays locked in the bridge contract until the voucher is sent '
    'back.';

/// Why an NFT list can never be promised to be complete.
///
/// Rendered as-is by the clients. CosmWasm has no chain-level "tokens by owner"
/// index: `tokens` is a per-contract query, so a wallet can only ask contracts
/// it already knows about. Saying this in the UI is better than showing an
/// empty list that looks authoritative.
const String nftDiscoveryLimitation =
    'CosmWasm has no chain-wide index of NFTs by owner. This list only covers '
    'contracts Zunia knows about; add a collection address to check another '
    'one.';

/* -------------------------------------------------------------------------- *
 * Small guards
 * -------------------------------------------------------------------------- */

Map<String, Object?>? _asRecord(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// Non-empty strings only: an empty `token_uri` is the same as none.
String? _asString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

final RegExp _digits = RegExp(r'^\d+$');

/// A non-negative integer, from either a JSON number or a decimal string.
///
/// uint64 fields are stringified by some LCD gateways and left as numbers by
/// others, and `num_tokens` is the one place we need the value as a number.
int? _asUint(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is String && _digits.hasMatch(value)) return int.tryParse(value);
  return null;
}

/// A uint64 kept as a decimal string, so nothing is lost above 2^53.
String? _asDecimalString(Object? value) {
  if (value is String && _digits.hasMatch(value)) return value;
  if (value is int && value >= 0) return '$value';
  return null;
}

InterchainError _malformed(String chainId, String what, [Object? cause]) =>
    InterchainError(
      InterchainErrorCode.malformedResponse,
      '$chainId: $what',
      chainId: chainId,
      cause: cause,
    );

/// The action name of a CosmWasm message, i.e. its single top-level key.
String messageAction(Map<String, Object?> message) =>
    message.keys.isEmpty ? 'unknown' : message.keys.first;

/// Unpadded base64url of the UTF-8 JSON, which is what a wasm query path takes.
String _jsonToBase64Url(Object? value) {
  final bytes = utf8.encode(jsonEncode(value));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Standard, padded base64 of the UTF-8 JSON, which is what a `Binary` field
/// takes.
String _jsonToBase64(Object? value) => base64.encode(utf8.encode(jsonEncode(value)));

/// Decode standard or url-safe base64 that may be missing its padding.
///
/// Throws [FormatException] on anything that is not base64. Callers decide
/// whether that is fatal.
List<int> _decodeBase64Loose(String raw) {
  final normalised = raw.replaceAll('-', '+').replaceAll('_', '/');
  final padding = (4 - normalised.length % 4) % 4;
  return base64.decode(normalised + ('=' * padding));
}

/* -------------------------------------------------------------------------- *
 * Capability gate
 * -------------------------------------------------------------------------- */

/// True when this chain can serve CW721 queries and executes.
///
/// [allowUnknownFeatures] treats a chain with no `features` list as capable.
/// Off by default: absent is not the same as declared, and guessing wrong means
/// firing wasm queries at a chain that cannot answer them. The escape hatch
/// exists because the bundled catalog generator currently drops `features`, so
/// a host that has established the capability another way can say so.
bool supportsCosmWasm(ChainInfo chain, {bool allowUnknownFeatures = false}) {
  final features = chain.features;
  if (features == null) return allowUnknownFeatures;
  return features.contains(cosmWasmFeature);
}

/// Throw unless the chain declares `cosmwasm`.
///
/// Throws [InterchainError] `unsupportedChain`. Not retryable: the chain needs
/// the feature flag, or the NFT surface needs to be hidden for it.
void assertCosmWasmChain(ChainInfo chain, {bool allowUnknownFeatures = false}) {
  if (supportsCosmWasm(chain, allowUnknownFeatures: allowUnknownFeatures)) {
    return;
  }
  final reason = chain.features == null
      ? 'publishes no feature list'
      : 'does not declare the "$cosmWasmFeature" feature';
  throw InterchainError(
    InterchainErrorCode.unsupportedChain,
    '${chain.chainId} $reason; CW721 is unavailable',
    chainId: chain.chainId,
  );
}

/* -------------------------------------------------------------------------- *
 * Addresses
 * -------------------------------------------------------------------------- */

/// True when [address] is a bech32 string under [prefix].
///
/// Deliberately a string comparison against `prefix + "1"` rather than a
/// `^[a-z]+1` regex. Safrochain's prefix is `addr_safro`, with an underscore,
/// which a character-class regex rejects; bech32 itself allows any printable
/// ASCII in the human-readable part and separates it with the *last* `1`, so
/// matching the configured prefix plus the separator is both correct and
/// tolerant. No checksum verification here — that belongs in the kernel, which
/// owns bech32.
bool addressHasPrefix(String address, String prefix) {
  if (address.isEmpty || prefix.isEmpty) return false;
  return address.startsWith('${prefix}1') && address.length > prefix.length + 1;
}

/// Reject an address that is not on [chain].
///
/// Sending an NFT to a well-formed address with the wrong prefix loses it, and
/// the mistake is invisible on review, so the check is not optional.
void _assertChainAddress(ChainInfo chain, String address, String label) {
  if (addressHasPrefix(address, chain.bech32Prefix)) return;
  throw InterchainError(
    InterchainErrorCode.contractError,
    '$label "$address" is not a ${chain.chainName} address '
    '(expected prefix "${chain.bech32Prefix}")',
    chainId: chain.chainId,
  );
}

/* -------------------------------------------------------------------------- *
 * Smart queries
 * -------------------------------------------------------------------------- */

/// A chain plus the client that reads it. Every CW721 read takes one.
///
/// DIVERGENCE from `nft.ts`: [allowUnknownFeatures] lives here rather than on
/// each call's options, so one context cannot be read as capable by one screen
/// and incapable by the next.
@immutable
class NftChainContext {
  const NftChainContext({
    required this.chain,
    required this.lcd,
    this.allowUnknownFeatures = false,
  });

  final ChainInfo chain;
  final LcdClient lcd;
  final bool allowUnknownFeatures;
}

/// The LCD path for a CosmWasm smart query.
///
/// `GET /cosmwasm/wasm/v1/contract/{addr}/smart/{base64url(json)}`. Public
/// because it is the one piece worth asserting on directly in a test, and
/// because a failing query is much easier to debug when the path can be
/// printed.
String smartQueryPath(String contract, Map<String, Object?> query) {
  final address = contract.trim();
  if (address.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.contractError,
      'Smart query needs a contract address',
    );
  }
  // The address is caller data and lands in a URL path; encode it rather than
  // trusting that it is bech32. A no-op for real addresses.
  return '/cosmwasm/wasm/v1/contract/${Uri.encodeComponent(address)}'
      '/smart/${_jsonToBase64Url(query)}';
}

/// Unwrap the `{ "data": … }` envelope a smart query comes back in.
///
/// wasmd marshals the contract's reply as raw JSON, so `data` is normally an
/// object. Older nodes and some gateway proxies base64 the bytes instead, so a
/// string is decoded rather than rejected — and if that decode fails, the
/// string is returned as-is, because a contract is allowed to answer with a
/// bare JSON string.
///
/// Throws [InterchainError] `malformedResponse` when there is no `data`.
Object? unwrapSmartQueryData(Object? body, String chainId) {
  final row = _asRecord(body);
  if (row == null || !row.containsKey('data')) {
    throw _malformed(chainId, 'smart query response has no data field');
  }
  final data = row['data'];
  if (data == null) {
    throw _malformed(chainId, 'smart query returned empty data');
  }
  if (data is String) {
    try {
      return jsonDecode(utf8.decode(_decodeBase64Loose(data)));
    } on Object {
      return data;
    }
  }
  return data;
}

/// Run one CosmWasm smart query and return the contract's reply.
///
/// No capability gate here — this is the generic primitive, and the CW721
/// wrappers below apply [assertCosmWasmChain] before calling it. The chain id
/// comes from [LcdClient.chainId] rather than a separate parameter, so the two
/// can never disagree.
///
/// Returns the contract's reply as [Object]. Narrow it yourself. Throws
/// [InterchainError] `contractError` when the contract rejected the query,
/// `malformedResponse` when the envelope is wrong, or whatever
/// [LcdClient.getJson] throws.
Future<Object?> smartQuery(
  LcdClient lcd,
  String contract,
  Map<String, Object?> query, [
  LcdRequestOptions? options,
]) async {
  final path = smartQueryPath(contract, query);
  Object? body;
  try {
    body = await lcd.getJson(path, options);
  } on InterchainError catch (error) {
    throw _asContractError(error, lcd.chainId, contract, query);
  }
  return unwrapSmartQueryData(body, lcd.chainId);
}

/// Reclassify an LCD failure that is really the contract saying no.
///
/// wasmd answers an unparseable or unsupported query with HTTP 400 carrying the
/// serde error. `lcd.dart` treats a 400 as fatal and reports `lcdUnreachable`,
/// which would tell the user the network is down when the truth is that this
/// contract does not implement this query. The body text does not survive
/// `lcd.dart`, so the message names the query instead.
InterchainError _asContractError(
  InterchainError error,
  String chainId,
  String contract,
  Map<String, Object?> query,
) {
  if (error.code == InterchainErrorCode.aborted ||
      error.code == InterchainErrorCode.readsDisabled) {
    return error;
  }
  if (error.httpStatus == 400) {
    return InterchainError(
      InterchainErrorCode.contractError,
      '$chainId: $contract rejected "${messageAction(query)}" (HTTP 400)',
      chainId: chainId,
      httpStatus: 400,
      cause: error,
    );
  }
  return error;
}

/// True when a failure means "this contract does not answer that query", so a
/// caller may reasonably try a different spelling.
///
/// A cancelled call and a disabled-reads gate are never retried under another
/// name: the first is the user's decision, the second is a settings prompt.
/// HTTP 500 is included because a few LCD gateways report contract panics that
/// way, which is why the fallback is only ever used to pick between two known
/// query spellings and not to paper over a broken node.
bool _isQueryUnsupported(Object error) {
  if (error is! InterchainError) return false;
  if (error.code == InterchainErrorCode.aborted ||
      error.code == InterchainErrorCode.readsDisabled) {
    return false;
  }
  if (error.code == InterchainErrorCode.contractError ||
      error.code == InterchainErrorCode.malformedResponse) {
    return true;
  }
  return error.httpStatus == 400 || error.httpStatus == 500;
}

/// Gate, then query. Every CW721 read funnels through here.
Future<Object?> _cw721Query(
  NftChainContext ctx,
  String contract,
  Map<String, Object?> query,
  LcdRequestOptions? request,
) async {
  assertCosmWasmChain(ctx.chain, allowUnknownFeatures: ctx.allowUnknownFeatures);
  return smartQuery(ctx.lcd, contract, query, request);
}

/* -------------------------------------------------------------------------- *
 * Reads: token ids
 * -------------------------------------------------------------------------- */

/// One page of token ids.
@immutable
class NftTokenIdPage {
  const NftTokenIdPage({required this.tokenIds, required this.nextStartAfter});

  final List<String> tokenIds;

  /// Pass as `startAfter` to get the next page, or null when the contract
  /// returned a short page, which means this was the last one.
  final String? nextStartAfter;
}

int _clampLimit(int? limit) {
  if (limit == null) return defaultTokenPageLimit;
  if (limit < 1) return 1;
  if (limit > maxTokenPageLimit) return maxTokenPageLimit;
  return limit;
}

/// Narrow a `{"tokens": [...]}` reply. `tokens` and `all_tokens` share it.
List<String> _parseTokenIds(Object? raw, String chainId) {
  final row = _asRecord(raw);
  if (row == null) throw _malformed(chainId, 'token list is not an object');
  final list = row['tokens'];
  if (list is! List) {
    throw _malformed(chainId, 'token list has no tokens array');
  }
  final out = <String>[];
  for (final entry in list) {
    // Numeric token ids are stringified by some contracts and not by others.
    if (entry is String) {
      out.add(entry);
    } else if (entry is int) {
      out.add('$entry');
    }
    // Anything else is not a token id; dropping it beats poisoning the list.
  }
  return out;
}

NftTokenIdPage _pageFrom(List<String> tokenIds, int limit) => NftTokenIdPage(
      tokenIds: tokenIds,
      nextStartAfter:
          tokenIds.length >= limit && tokenIds.isNotEmpty ? tokenIds.last : null,
    );

/// One page of `{"tokens": {"owner", "start_after", "limit"}}`.
///
/// `start_after` is omitted rather than sent as null when there is no cursor;
/// cw721 takes an `Option<String>` so the two are equivalent, and omitting
/// keeps the base64url path shorter and byte-identical to the TypeScript
/// engine's.
Future<NftTokenIdPage> listOwnedTokenIds(
  NftChainContext ctx,
  String contract,
  String owner, {
  String? startAfter,
  int? limit,
  LcdRequestOptions? request,
}) async {
  final size = _clampLimit(limit);
  final query = <String, Object?>{
    'tokens': <String, Object?>{
      'owner': owner,
      'start_after': ?startAfter,
      'limit': size,
    },
  };
  final raw = await _cw721Query(ctx, contract, query, request);
  return _pageFrom(_parseTokenIds(raw, ctx.lcd.chainId), size);
}

/// One page of `{"all_tokens": {"start_after", "limit"}}`.
Future<NftTokenIdPage> listAllTokenIds(
  NftChainContext ctx,
  String contract, {
  String? startAfter,
  int? limit,
  LcdRequestOptions? request,
}) async {
  final size = _clampLimit(limit);
  final query = <String, Object?>{
    'all_tokens': <String, Object?>{
      'start_after': ?startAfter,
      'limit': size,
    },
  };
  final raw = await _cw721Query(ctx, contract, query, request);
  return _pageFrom(_parseTokenIds(raw, ctx.lcd.chainId), size);
}

/// Every token id an owner holds in one collection, subject to a cap.
@immutable
class NftTokenIdList {
  const NftTokenIdList({required this.tokenIds, required this.truncated});

  final List<String> tokenIds;

  /// True when the cap was hit and more ids exist. Show it; do not hide it.
  final bool truncated;
}

/// Walk `tokens` until the contract runs out, the cap is hit, or the page
/// budget is spent.
///
/// The page budget is not paranoia: `start_after` is contract-controlled, and a
/// contract that keeps returning full pages of the same id would otherwise loop
/// forever against a public LCD.
Future<NftTokenIdList> listAllOwnedTokenIds(
  NftChainContext ctx,
  String contract,
  String owner, {
  int? limit,
  int maxTokens = defaultMaxDiscoveryTokens,
  int maxPages = defaultMaxPages,
  LcdRequestOptions? request,
}) async {
  final seen = <String>{};
  final out = <String>[];
  String? cursor;

  for (var page = 0; page < maxPages; page++) {
    final result = await listOwnedTokenIds(
      ctx,
      contract,
      owner,
      startAfter: cursor,
      limit: limit,
      request: request,
    );
    for (final id in result.tokenIds) {
      if (!seen.add(id)) continue;
      out.add(id);
      if (out.length >= maxTokens) {
        return NftTokenIdList(tokenIds: out, truncated: true);
      }
    }
    if (result.nextStartAfter == null) {
      return NftTokenIdList(tokenIds: out, truncated: false);
    }
    if (result.nextStartAfter == cursor) {
      // The cursor did not move: the contract is not paginating. Stop rather
      // than spin.
      return NftTokenIdList(tokenIds: out, truncated: true);
    }
    cursor = result.nextStartAfter;
  }
  return NftTokenIdList(tokenIds: out, truncated: true);
}

/* -------------------------------------------------------------------------- *
 * Reads: token detail
 * -------------------------------------------------------------------------- */

/// `{"nft_info": {...}}` — the on-chain half of a token.
@immutable
class NftInfoResponse {
  const NftInfoResponse({required this.tokenUri, required this.metadata});

  final String? tokenUri;

  /// Parsed from `extension`. All-null when the contract stores nothing.
  final NftMetadata metadata;
}

/// One entry of `owner_of.approvals`.
@immutable
class NftApproval {
  const NftApproval({
    required this.spender,
    this.expiresAtHeight,
    this.expiresAtTimeNanos,
    this.neverExpires = false,
  });

  final String spender;

  /// `expires.at_height`, as a decimal string.
  final String? expiresAtHeight;

  /// `expires.at_time`, in nanoseconds, as a decimal string.
  final String? expiresAtTimeNanos;

  /// True only for an explicit `{"never":{}}`.
  final bool neverExpires;
}

/// `{"owner_of": {...}}`.
@immutable
class NftOwnership {
  const NftOwnership({required this.owner, required this.approvals});

  final String owner;
  final List<NftApproval> approvals;
}

/// `{"all_nft_info": {...}}`: ownership and info in one round trip.
@immutable
class NftAllInfoResponse {
  const NftAllInfoResponse({required this.access, required this.info});

  final NftOwnership access;
  final NftInfoResponse info;
}

/// Parse a cw_utils `Expiration`.
///
/// The variant shapes (`at_height`, `at_time`, `never`) are not in the verified
/// spec, so an unrecognised variant yields nulls instead of an error: an
/// approval we cannot describe is not a reason to fail an ownership read.
NftApproval? _parseApproval(Object? raw) {
  final row = _asRecord(raw);
  if (row == null) return null;
  final spender = _asString(row['spender']);
  if (spender == null) return null;
  final expires = _asRecord(row['expires']);
  return NftApproval(
    spender: spender,
    expiresAtHeight: expires == null ? null : _asDecimalString(expires['at_height']),
    expiresAtTimeNanos: expires == null ? null : _asDecimalString(expires['at_time']),
    neverExpires: expires != null && _asRecord(expires['never']) != null,
  );
}

NftOwnership _parseOwnership(Object? raw, String chainId) {
  final row = _asRecord(raw);
  if (row == null) throw _malformed(chainId, 'owner_of is not an object');
  final owner = _asString(row['owner']);
  if (owner == null) throw _malformed(chainId, 'owner_of has no owner');
  final approvals = <NftApproval>[];
  final list = row['approvals'];
  if (list is List) {
    for (final entry in list) {
      final parsed = _parseApproval(entry);
      if (parsed != null) approvals.add(parsed);
    }
  }
  return NftOwnership(owner: owner, approvals: approvals);
}

NftInfoResponse _parseNftInfo(Object? raw, String chainId) {
  final row = _asRecord(raw);
  if (row == null) throw _malformed(chainId, 'nft_info is not an object');
  return NftInfoResponse(
    tokenUri: _asString(row['token_uri']),
    metadata: parseNftMetadata(row['extension']),
  );
}

/// `{"nft_info": {"token_id": …}}`.
Future<NftInfoResponse> getNftInfo(
  NftChainContext ctx,
  String contract,
  String tokenId, {
  LcdRequestOptions? request,
}) async {
  final raw = await _cw721Query(
    ctx,
    contract,
    <String, Object?>{
      'nft_info': <String, Object?>{'token_id': tokenId},
    },
    request,
  );
  return _parseNftInfo(raw, ctx.lcd.chainId);
}

/// `{"owner_of": {"token_id": …, "include_expired": …}}`.
Future<NftOwnership> getOwnerOf(
  NftChainContext ctx,
  String contract,
  String tokenId, {
  bool? includeExpired,
  LcdRequestOptions? request,
}) async {
  final raw = await _cw721Query(
    ctx,
    contract,
    <String, Object?>{
      'owner_of': <String, Object?>{
        'token_id': tokenId,
        'include_expired': ?includeExpired,
      },
    },
    request,
  );
  return _parseOwnership(raw, ctx.lcd.chainId);
}

/// `{"all_nft_info": {"token_id": …}}`. One call instead of two.
Future<NftAllInfoResponse> getAllNftInfo(
  NftChainContext ctx,
  String contract,
  String tokenId, {
  bool? includeExpired,
  LcdRequestOptions? request,
}) async {
  final raw = await _cw721Query(
    ctx,
    contract,
    <String, Object?>{
      'all_nft_info': <String, Object?>{
        'token_id': tokenId,
        'include_expired': ?includeExpired,
      },
    },
    request,
  );
  final row = _asRecord(raw);
  if (row == null) {
    throw _malformed(ctx.lcd.chainId, 'all_nft_info is not an object');
  }
  return NftAllInfoResponse(
    access: _parseOwnership(row['access'], ctx.lcd.chainId),
    info: _parseNftInfo(row['info'], ctx.lcd.chainId),
  );
}

/// `{"num_tokens": {}}`.
///
/// Throws [InterchainError] `malformedResponse` when the reply has no usable
/// `count`. Callers that only want a nice-to-have number should catch.
Future<int> getNumTokens(
  NftChainContext ctx,
  String contract, {
  LcdRequestOptions? request,
}) async {
  final raw = await _cw721Query(
    ctx,
    contract,
    <String, Object?>{'num_tokens': <String, Object?>{}},
    request,
  );
  final count = _asUint(_asRecord(raw)?['count']);
  if (count == null) throw _malformed(ctx.lcd.chainId, 'num_tokens has no count');
  return count;
}

/// Build an [NftToken] from one `all_nft_info` call.
///
/// Metadata comes from the on-chain `extension` only. [NftToken.tokenUri] is
/// returned untouched; resolving it is a separate, opt-in step because it
/// leaves the device. See [fetchNftMetadata].
Future<NftToken> getNftToken(
  NftChainContext ctx,
  String contract,
  String tokenId, {
  LcdRequestOptions? request,
}) async {
  final all = await getAllNftInfo(ctx, contract, tokenId, request: request);
  final meta = all.info.metadata;
  return NftToken(
    tokenId: tokenId,
    name: meta.name,
    description: meta.description,
    imageUri: meta.image,
    animationUri: meta.animationUrl,
    attributes: meta.attributes,
    collectionAddress: contract,
    chainId: ctx.chain.chainId,
    owner: all.access.owner,
    tokenUri: all.info.tokenUri,
  );
}

/* -------------------------------------------------------------------------- *
 * Reads: collection
 * -------------------------------------------------------------------------- */

/// Collection metadata, trying both query spellings.
///
/// cw721 v0.19 answers `collection_info`; everything older answers
/// `contract_info`, and Stargaze's sg721 answers `collection_info` with a
/// different payload again. There is no way to tell from the outside which one
/// a contract implements, so both are tried in that order and the first that
/// answers wins.
///
/// Only `name` and `symbol` are in the verified spec. `description`, `image`
/// and `creator` are read from the top level *and* from an `extension` object,
/// because the newer response nests them; both are best-effort and null when
/// absent.
///
/// Throws [InterchainError] `contractError` when neither spelling works.
Future<NftCollection> getCollectionInfo(
  NftChainContext ctx,
  String contract, {
  bool includeTokenCount = true,
  LcdRequestOptions? request,
}) async {
  assertCosmWasmChain(ctx.chain, allowUnknownFeatures: ctx.allowUnknownFeatures);

  const spellings = <Map<String, Object?>>[
    <String, Object?>{'collection_info': <String, Object?>{}},
    <String, Object?>{'contract_info': <String, Object?>{}},
  ];

  Object? raw;
  var answered = false;
  Object? lastError;
  for (final query in spellings) {
    try {
      raw = await smartQuery(ctx.lcd, contract, query, request);
      answered = true;
      break;
    } on InterchainError catch (error) {
      if (!_isQueryUnsupported(error)) rethrow;
      lastError = error;
    }
  }
  if (!answered) {
    throw InterchainError(
      InterchainErrorCode.contractError,
      '${ctx.chain.chainId}: $contract answered neither collection_info nor '
      'contract_info',
      chainId: ctx.chain.chainId,
      cause: lastError,
    );
  }

  int? tokenCount;
  if (includeTokenCount) {
    try {
      tokenCount = await getNumTokens(ctx, contract, request: request);
    } on InterchainError catch (error) {
      // Documented as null when the contract does not answer it. A cancelled
      // call is the user's decision and must not be swallowed.
      if (error.code == InterchainErrorCode.aborted) rethrow;
      tokenCount = null;
    }
  }

  return _parseCollectionInfo(raw, ctx.chain.chainId, contract, tokenCount);
}

NftCollection _parseCollectionInfo(
  Object? raw,
  String chainId,
  String contract,
  int? tokenCount,
) {
  final row = _asRecord(raw);
  if (row == null) {
    throw _malformed(chainId, 'collection info is not an object');
  }
  final extension = _asRecord(row['extension']) ?? const <String, Object?>{};
  String? pick(List<String> keys) {
    for (final key in keys) {
      final hit = _asString(row[key]) ?? _asString(extension[key]);
      if (hit != null) return hit;
    }
    return null;
  }

  return NftCollection(
    chainId: chainId,
    contractAddress: contract,
    name: pick(const ['name']),
    symbol: pick(const ['symbol']),
    description: pick(const ['description']),
    imageUri: pick(const ['image', 'image_url', 'image_uri']),
    tokenCount: tokenCount,
    creator: pick(const ['creator']),
  );
}

/* -------------------------------------------------------------------------- *
 * Metadata
 * -------------------------------------------------------------------------- */

/// The standard NFT metadata document.
///
/// Same shape whether it came from the on-chain `extension` or from a fetched
/// `token_uri`. Every field is optional upstream, so every field is nullable
/// here; nothing is invented to fill a gap.
@immutable
class NftMetadata {
  const NftMetadata({
    this.name,
    this.description,
    this.image,
    this.animationUrl,
    this.externalUrl,
    this.attributes = const [],
  });

  final String? name;
  final String? description;

  /// `image`. May itself be an `ipfs://` URI.
  final String? image;

  /// `animation_url`.
  final String? animationUrl;

  /// `external_url`. Not in the verified spec, but part of the same
  /// cw721-metadata-onchain struct; null whenever it is absent.
  final String? externalUrl;

  final List<NftAttribute> attributes;
}

const NftMetadata _emptyMetadata = NftMetadata();

/// Coerce one attribute value to a string.
///
/// The extension is free-form: numbers, booleans and nested objects all occur.
/// Coercing keeps the trait visible in the UI, which is better than silently
/// dropping a trait because its value was a number.
String? _attributeValue(Object? value) {
  if (value is String) return value;
  if (value is num) return value is int ? '$value' : '$value';
  if (value is bool) return '$value';
  if (value == null) return '';
  try {
    return jsonEncode(value);
  } on Object {
    return null;
  }
}

List<NftAttribute> _parseAttributes(Object? raw) {
  if (raw is! List) return const [];
  final out = <NftAttribute>[];
  for (final entry in raw) {
    final row = _asRecord(entry);
    if (row == null) continue;
    final value = _attributeValue(row['value']);
    if (value == null) continue;
    out.add(NftAttribute(
      // A trait with no `trait_type` still carries a value worth showing.
      traitType: _asString(row['trait_type']) ?? '',
      value: value,
      displayType: _asString(row['display_type']),
    ));
  }
  return out;
}

/// Parse a metadata document from anywhere: the on-chain `extension`, a fetched
/// `token_uri` body, or a `data:` URI payload.
///
/// Never throws. Anything that is not an object becomes an empty document,
/// because a broken metadata document must not take a token off the screen.
NftMetadata parseNftMetadata(Object? raw) {
  final row = _asRecord(raw);
  if (row == null) return _emptyMetadata;
  return NftMetadata(
    name: _asString(row['name']),
    description: _asString(row['description']),
    image: _asString(row['image']),
    animationUrl: _asString(row['animation_url']),
    externalUrl: _asString(row['external_url']),
    attributes: _parseAttributes(row['attributes']),
  );
}

/// Fill the null fields of a token from a metadata document.
///
/// On-chain values win: the `extension` is signed into chain state, a fetched
/// document is whatever a host served this second.
NftToken applyNftMetadata(NftToken token, NftMetadata metadata) => NftToken(
      tokenId: token.tokenId,
      collectionAddress: token.collectionAddress,
      chainId: token.chainId,
      name: token.name ?? metadata.name,
      description: token.description ?? metadata.description,
      imageUri: token.imageUri ?? metadata.image,
      animationUri: token.animationUri ?? metadata.animationUrl,
      attributes:
          token.attributes.isNotEmpty ? token.attributes : metadata.attributes,
      owner: token.owner,
      tokenUri: token.tokenUri,
    );

/// What a `token_uri` resolved to.
///
/// - `http` — [ResolvedTokenUri.urls] can be fetched, in order.
/// - `inline` — [ResolvedTokenUri.inline] already holds the document; nothing
///   leaves the device.
/// - `unsupported` — nothing can be done; [ResolvedTokenUri.reason] says why.
enum ResolvedTokenUriKind { http, inline, unsupported }

/// The outcome of resolving a `token_uri`.
@immutable
class ResolvedTokenUri {
  const ResolvedTokenUri({
    required this.kind,
    this.urls = const [],
    this.inline,
    this.reason,
  });

  final ResolvedTokenUriKind kind;
  final List<String> urls;

  /// Decoded `data:` payload.
  final String? inline;

  /// Developer-facing explanation when [kind] is `unsupported`.
  final String? reason;
}

String _joinGateway(String base, String suffix) {
  final left = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  // encodeFull, not encodeComponent: the suffix is `CID/path/1.json` and the
  // slashes have to survive.
  return '$left/${Uri.encodeFull(suffix)}';
}

/// Decode a `data:` URI.
///
/// `data:[<mediatype>][;base64],<data>`. Returns null when the URI is malformed
/// rather than throwing: a bad `token_uri` is the contract's problem, not a
/// reason to fail the read.
String? _decodeDataUri(String uri) {
  final comma = uri.indexOf(',');
  if (comma < 0) return null;
  final header = uri.substring('data:'.length, comma);
  final payload = uri.substring(comma + 1);
  try {
    if (RegExp(r';\s*base64\s*$', caseSensitive: false).hasMatch(header)) {
      return utf8.decode(_decodeBase64Loose(payload));
    }
    return Uri.decodeComponent(payload);
  } on Object {
    return null;
  }
}

/// CIDv0 (`Qm…`, base58) or CIDv1 (`b…`, base32 lowercase).
final RegExp _bareCid =
    RegExp(r'^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{58,})(/.*)?$');

/// The `<cid>/<path>` part of an IPFS reference, or null when it is not one.
///
/// `ipfs://ipfs/Qm…` occurs in the wild alongside `ipfs://Qm…`; the duplicated
/// segment is stripped so the gateway does not get `/ipfs/ipfs/Qm…`.
String? _ipfsSuffix(String uri) {
  if (uri.startsWith('ipfs://')) {
    final rest = uri.substring('ipfs://'.length);
    final stripped =
        rest.startsWith('ipfs/') ? rest.substring('ipfs/'.length) : rest;
    return stripped.isEmpty ? null : stripped;
  }
  if (uri.startsWith('ipns://')) {
    final rest = uri.substring('ipns://'.length);
    return rest.isEmpty ? null : 'ipns/$rest';
  }
  return _bareCid.hasMatch(uri) ? uri : null;
}

/// Turn a `token_uri` into something that can be read.
///
/// Handles `ipfs://`, `ipns://`, `ar://`, `https://`, `http://` (opt-in) and
/// TODO-VERIFY: a bare CIDv0/CIDv1 with no scheme is treated as IPFS — a
/// heuristic, not a spec rule, but several contracts store exactly that and the
/// alternative is showing the user nothing.
///
/// [ipfsGateways] and [arweaveGateways] have no default. A hardcoded gateway
/// would send every user's NFT holdings to one operator, and hosts differ on
/// which gateway they trust. [allowInsecureHttp] is off because plain http is
/// cleartext and downgradeable, and a wallet should not quietly make one.
///
/// This function performs no I/O.
ResolvedTokenUri resolveTokenUri(
  String uri, {
  List<String> ipfsGateways = const [],
  List<String> arweaveGateways = const [],
  bool allowInsecureHttp = false,
}) {
  final trimmed = uri.trim();
  if (trimmed.isEmpty) {
    return const ResolvedTokenUri(
      kind: ResolvedTokenUriKind.unsupported,
      reason: 'Empty token_uri',
    );
  }

  if (trimmed.startsWith('data:')) {
    final inline = _decodeDataUri(trimmed);
    if (inline == null) {
      return const ResolvedTokenUri(
        kind: ResolvedTokenUriKind.unsupported,
        reason: 'Malformed data: URI',
      );
    }
    return ResolvedTokenUri(
      kind: ResolvedTokenUriKind.inline,
      inline: inline,
    );
  }

  if (trimmed.startsWith('https://')) {
    return ResolvedTokenUri(
      kind: ResolvedTokenUriKind.http,
      urls: [trimmed],
    );
  }

  if (trimmed.startsWith('http://')) {
    if (!allowInsecureHttp) {
      return const ResolvedTokenUri(
        kind: ResolvedTokenUriKind.unsupported,
        reason: 'Plain http:// is disabled',
      );
    }
    return ResolvedTokenUri(kind: ResolvedTokenUriKind.http, urls: [trimmed]);
  }

  final ipfsPath = _ipfsSuffix(trimmed);
  if (ipfsPath != null) {
    if (ipfsGateways.isEmpty) {
      return const ResolvedTokenUri(
        kind: ResolvedTokenUriKind.unsupported,
        reason: 'No IPFS gateway configured',
      );
    }
    return ResolvedTokenUri(
      kind: ResolvedTokenUriKind.http,
      urls: [for (final base in ipfsGateways) _joinGateway(base, ipfsPath)],
    );
  }

  if (trimmed.startsWith('ar://')) {
    final suffix = trimmed.substring('ar://'.length);
    if (arweaveGateways.isEmpty || suffix.isEmpty) {
      return const ResolvedTokenUri(
        kind: ResolvedTokenUriKind.unsupported,
        reason: 'No Arweave gateway configured',
      );
    }
    return ResolvedTokenUri(
      kind: ResolvedTokenUriKind.http,
      urls: [for (final base in arweaveGateways) _joinGateway(base, suffix)],
    );
  }

  final head = trimmed.length <= 24 ? trimmed : trimmed.substring(0, 24);
  return ResolvedTokenUri(
    kind: ResolvedTokenUriKind.unsupported,
    reason: 'Unsupported token_uri scheme: $head',
  );
}

/// Reads one URL and returns the parsed JSON body.
///
/// Supplied by the host, never defaulted to a global HTTP client. That is the
/// opt-in: with no fetcher there is no transport, so metadata cannot leak by
/// accident. The implementation owns the timeout, the redirect policy and the
/// response size limit — a metadata host is untrusted and can serve a gigabyte.
typedef NftMetadataFetcher = Future<Object?> Function(String url);

/// Where a metadata document came from. `inline` means nothing left the device.
enum NftMetadataSource { inline, remote }

/// A metadata document plus its provenance.
@immutable
class NftMetadataResult {
  const NftMetadataResult({
    required this.metadata,
    required this.source,
    this.url,
  });

  final NftMetadata metadata;
  final NftMetadataSource source;

  /// The URL that answered, or null for an inline document.
  final String? url;
}

/// Resolve and read a `token_uri`.
///
/// Privacy: for anything other than a `data:` URI this contacts a third party
/// chosen by the NFT's minter. That host learns the reader's IP and which token
/// they are looking at, and an IPFS gateway learns it for every token in a
/// collection at once. Nothing here happens without the caller passing [fetch],
/// and hosts must ask the user first.
///
/// Throws [InterchainError] `readsDisabled` when a remote read is needed and no
/// fetcher was supplied, `malformedResponse` when the URI cannot be resolved or
/// the inline document is not JSON, and `lcdUnreachable` when every candidate
/// URL failed.
Future<NftMetadataResult> fetchNftMetadata(
  String tokenUri, {
  NftMetadataFetcher? fetch,
  List<String> ipfsGateways = const [],
  List<String> arweaveGateways = const [],
  bool allowInsecureHttp = false,
}) async {
  final resolved = resolveTokenUri(
    tokenUri,
    ipfsGateways: ipfsGateways,
    arweaveGateways: arweaveGateways,
    allowInsecureHttp: allowInsecureHttp,
  );

  if (resolved.kind == ResolvedTokenUriKind.unsupported) {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      'Cannot resolve token_uri: ${resolved.reason ?? 'unsupported'}',
    );
  }

  if (resolved.kind == ResolvedTokenUriKind.inline) {
    try {
      return NftMetadataResult(
        metadata: parseNftMetadata(jsonDecode(resolved.inline ?? '')),
        source: NftMetadataSource.inline,
      );
    } on FormatException catch (cause) {
      throw InterchainError(
        InterchainErrorCode.malformedResponse,
        'Inline token_uri payload is not JSON',
        cause: cause,
      );
    }
  }

  if (fetch == null) {
    throw InterchainError(
      InterchainErrorCode.readsDisabled,
      'Off-chain NFT metadata was not loaded: no metadata fetcher was supplied',
    );
  }

  Object? lastError;
  for (final url in resolved.urls) {
    try {
      final body = await fetch(url);
      return NftMetadataResult(
        metadata: parseNftMetadata(body),
        source: NftMetadataSource.remote,
        url: url,
      );
    } on Object catch (error) {
      if (error is InterchainError &&
          error.code == InterchainErrorCode.aborted) {
        rethrow;
      }
      lastError = error;
    }
  }

  // `lcdUnreachable` is reused deliberately: the UI copy for it ("can't reach
  // the network, try again") is exactly right here, and an NFT-only error code
  // would be a code with no distinct next action.
  throw InterchainError(
    InterchainErrorCode.lcdUnreachable,
    'No metadata host answered for $tokenUri',
    endpoint: resolved.urls.isEmpty ? null : resolved.urls.first,
    cause: lastError,
  );
}

/* -------------------------------------------------------------------------- *
 * Discovery
 * -------------------------------------------------------------------------- */

/// How a contract address got into a discovery run.
///
/// Surfaced so the UI can say "you added this one" versus "we shipped this
/// one", which matters when a list looks wrong.
enum NftDiscoverySource { known, indexer, user }

/// A chain-specific NFT indexer, supplied by the host.
///
/// The only way to get a genuinely complete list. Implementations talk to
/// whatever that chain has — a Stargaze-style GraphQL API, a subquery node, an
/// in-house service — and this module neither knows nor cares which. It is an
/// interface rather than a URL because those services share no protocol.
abstract class NftIndexer {
  /// For logs and for the "source: …" line in the UI.
  String get name;

  /// CW721 contract addresses on [chainId] where [owner] holds something.
  Future<List<String>> listContracts(String chainId, String owner);
}

/// One collection an owner holds something in.
@immutable
class NftHolding {
  const NftHolding({
    required this.contractAddress,
    required this.source,
    required this.tokenIds,
    required this.truncated,
  });

  final String contractAddress;
  final NftDiscoverySource source;
  final List<String> tokenIds;

  /// True when the per-contract cap cut the list short.
  final bool truncated;
}

/// A contract or indexer that could not be read. Shown, not swallowed.
@immutable
class NftDiscoveryIssue {
  const NftDiscoveryIssue({required this.contractAddress, required this.message});

  /// Null for an indexer-level failure.
  final String? contractAddress;

  final String message;
}

/// Inputs for [discoverNfts].
@immutable
class NftDiscoveryOptions {
  const NftDiscoveryOptions({
    this.knownContracts = const [],
    this.userContracts = const [],
    this.indexer,
    this.maxContracts = defaultMaxDiscoveryContracts,
    this.maxTokensPerContract = defaultMaxDiscoveryTokens,
    this.request,
  });

  /// Contracts the host ships for this chain.
  final List<String> knownContracts;

  /// Contracts the user typed in. Always probed, even past the cap.
  final List<String> userContracts;

  /// A real index, when the chain has one.
  final NftIndexer? indexer;

  final int maxContracts;
  final int maxTokensPerContract;
  final LcdRequestOptions? request;
}

/// What a discovery run found, and what it could not promise.
@immutable
class NftDiscoveryResult {
  const NftDiscoveryResult({
    required this.chainId,
    required this.owner,
    required this.holdings,
    required this.sources,
    required this.complete,
    required this.limitation,
    required this.issues,
  });

  final String chainId;
  final String owner;
  final List<NftHolding> holdings;

  /// Which of the three paths contributed.
  final List<NftDiscoverySource> sources;

  /// True only when an indexer answered without error. Contract-list scanning
  /// can never be complete, and a UI that hides that is lying to the user.
  final bool complete;

  /// [nftDiscoveryLimitation], unless [complete].
  final String? limitation;

  final List<NftDiscoveryIssue> issues;
}

List<String> _dedupe(List<String> values) {
  final seen = <String>{};
  final out = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    out.add(trimmed);
  }
  return out;
}

String _errorMessage(Object error) =>
    error is InterchainError ? '${error.code.name}: ${error.message}' : '$error';

/// Find the NFTs an owner holds on one chain.
///
/// There are exactly three ways to do this and all three are exposed, because
/// none of them is sufficient on its own:
///
/// - `knownContracts` — a curated list the host ships. Cheap, always partial.
/// - `indexer` — a chain-specific service. Complete where one exists, which is
///   for a minority of chains.
/// - `userContracts` — an address the user pasted. The escape hatch that makes
///   the other two survivable.
///
/// The reason the caller has to supply all of this is that CosmWasm has no
/// chain-level "tokens by owner" query: `tokens` is per contract, so without a
/// contract address there is nothing to ask. [NftDiscoveryResult.complete] and
/// [NftDiscoveryResult.limitation] carry that fact to the UI instead of hiding
/// it behind an empty list.
///
/// Contracts are probed one at a time on purpose: these are public LCD nodes,
/// and a burst of parallel wasm queries is the fastest way to get rate-limited.
Future<NftDiscoveryResult> discoverNfts(
  NftChainContext ctx,
  String owner, {
  NftDiscoveryOptions options = const NftDiscoveryOptions(),
}) async {
  assertCosmWasmChain(ctx.chain, allowUnknownFeatures: ctx.allowUnknownFeatures);

  final chainId = ctx.chain.chainId;
  final issues = <NftDiscoveryIssue>[];
  final sources = <NftDiscoverySource>{};
  // Insertion-ordered, like the TS Map: an address re-added later keeps its
  // original position and only changes label.
  final origin = <String, NftDiscoverySource>{};

  var indexed = false;
  final indexer = options.indexer;
  if (indexer != null) {
    try {
      final rows = await indexer.listContracts(chainId, owner);
      for (final address in _dedupe(rows)) {
        origin[address] = NftDiscoverySource.indexer;
      }
      indexed = true;
      sources.add(NftDiscoverySource.indexer);
    } on Object catch (error) {
      if (error is InterchainError &&
          error.code == InterchainErrorCode.aborted) {
        rethrow;
      }
      issues.add(NftDiscoveryIssue(
        contractAddress: null,
        message: '${indexer.name}: ${_errorMessage(error)}',
      ));
    }
  }

  for (final address in _dedupe(options.knownContracts)) {
    origin.putIfAbsent(address, () => NftDiscoverySource.known);
  }
  // User-supplied last so it wins the label: if the user typed an address we
  // already ship, the UI should still say they asked for it.
  for (final address in _dedupe(options.userContracts)) {
    origin[address] = NftDiscoverySource.user;
  }

  final candidates = <String>[];
  for (final entry in origin.entries) {
    // The user's own addresses are never dropped by the cap: they typed them
    // and expect an answer about that specific contract.
    if (entry.value == NftDiscoverySource.user ||
        candidates.length < options.maxContracts) {
      candidates.add(entry.key);
    }
  }

  final holdings = <NftHolding>[];
  for (final address in candidates) {
    try {
      final list = await listAllOwnedTokenIds(
        ctx,
        address,
        owner,
        maxTokens: options.maxTokensPerContract,
        request: options.request,
      );
      if (list.tokenIds.isEmpty) continue;
      final source = origin[address] ?? NftDiscoverySource.known;
      sources.add(source);
      holdings.add(NftHolding(
        contractAddress: address,
        source: source,
        tokenIds: list.tokenIds,
        truncated: list.truncated,
      ));
    } on Object catch (error) {
      if (error is InterchainError &&
          error.code == InterchainErrorCode.aborted) {
        rethrow;
      }
      issues.add(NftDiscoveryIssue(
        contractAddress: address,
        message: _errorMessage(error),
      ));
    }
  }

  final complete = indexed && issues.isEmpty;
  return NftDiscoveryResult(
    chainId: chainId,
    owner: owner,
    holdings: holdings,
    sources: sources.toList(),
    complete: complete,
    limitation: complete ? null : nftDiscoveryLimitation,
    issues: issues,
  );
}

/* -------------------------------------------------------------------------- *
 * Message building
 * -------------------------------------------------------------------------- */

/// A `cosmwasm.wasm.v1.MsgExecuteContract` waiting to be encoded.
///
/// DIVERGENCE from `nft.ts`'s `BuiltMsg`: [msg] is the ExecuteMsg as an object,
/// not base64 in a proto-JSON envelope. `crypto/amino_tx.dart` owns the amino
/// and proto encodings and needs the object for both, and keeping the two in
/// one place is what stops the classic CosmWasm bug where the signature covers
/// different bytes from the ones the chain executes.
///
/// No `funds` field: CW721 executes carry none, and `msgExecuteContract`
/// already defaults them to the empty list proto3 expects.
@immutable
class NftExecute {
  const NftExecute({
    required this.sender,
    required this.contract,
    required this.msg,
  });

  final String sender;

  /// The contract the message executes against — the CW721 collection, even for
  /// an ICS721 transfer, where the *bridge* is named inside `send_nft`.
  final String contract;

  /// The ExecuteMsg. Exactly one top-level key.
  final Map<String, Object?> msg;

  /// Canonical JSON of [msg], for display and for the signing screen.
  String get msgJson => jsonEncode(msg);

  /// The single top-level key, e.g. `transfer_nft`.
  String get action => messageAction(msg);
}

void _assertTokenId(ChainInfo chain, String tokenId) {
  if (tokenId.isNotEmpty) return;
  throw InterchainError(
    InterchainErrorCode.contractError,
    'Token id is required',
    chainId: chain.chainId,
  );
}

/// `{"transfer_nft": {"recipient": …, "token_id": …}}`.
///
/// Same-chain only. The recipient is checked against the chain's bech32 prefix
/// because a CW721 transfer to a valid-looking address on the wrong chain is
/// unrecoverable.
///
/// Throws [InterchainError] `unsupportedChain` without `cosmwasm`, or
/// `contractError` on an empty token id or an address on the wrong chain.
NftExecute buildTransferNftMsg(
  ChainInfo chain, {
  required String sender,
  required String collectionAddress,
  required String tokenId,
  required String recipient,
  bool allowUnknownFeatures = false,
}) {
  assertCosmWasmChain(chain, allowUnknownFeatures: allowUnknownFeatures);
  _assertChainAddress(chain, sender, 'Sender');
  _assertChainAddress(chain, collectionAddress, 'Collection address');
  _assertChainAddress(chain, recipient, 'Recipient');
  _assertTokenId(chain, tokenId);

  return NftExecute(
    sender: sender,
    contract: collectionAddress,
    msg: <String, Object?>{
      'transfer_nft': <String, Object?>{
        'recipient': recipient,
        'token_id': tokenId,
      },
    },
  );
}

/// `{"send_nft": {"contract": …, "token_id": …, "msg": "<base64>"}}`.
///
/// Two levels of encoding: the CW721 `msg` field is a `Binary`, so the inner
/// payload is base64-encoded JSON, and then the whole `send_nft` object is
/// encoded again as the `MsgExecuteContract.msg` bytes by the amino/proto
/// encoder. Getting either level wrong produces a message the contract rejects
/// at execution, after the user has already signed.
///
/// Throws [InterchainError] `unsupportedChain`, or `contractError` for a bad
/// address or empty token id.
NftExecute buildSendNftMsg(
  ChainInfo chain, {
  required String sender,
  required String collectionAddress,
  required String tokenId,
  required String contract,
  required Object? msg,
  bool allowUnknownFeatures = false,
}) {
  assertCosmWasmChain(chain, allowUnknownFeatures: allowUnknownFeatures);
  _assertChainAddress(chain, sender, 'Sender');
  _assertChainAddress(chain, collectionAddress, 'Collection address');
  _assertChainAddress(chain, contract, 'Receiving contract');
  _assertTokenId(chain, tokenId);

  return NftExecute(
    sender: sender,
    contract: collectionAddress,
    msg: <String, Object?>{
      'send_nft': <String, Object?>{
        'contract': contract,
        'token_id': tokenId,
        'msg': _jsonToBase64(msg),
      },
    },
  );
}

/* -------------------------------------------------------------------------- *
 * ICS721
 * -------------------------------------------------------------------------- */

/// True when an ICS721 transfer can be built for this request.
///
/// There is no registry feature for ICS721, so the capability *is* the host's
/// configuration: a bridge contract deployed on this chain and a channel to the
/// destination. Neither may be hardcoded — both are per-deployment data.
bool supportsIcs721(
  ChainInfo chain,
  NftTransferRequest request, {
  bool allowUnknownFeatures = false,
}) {
  if (!supportsCosmWasm(chain, allowUnknownFeatures: allowUnknownFeatures)) {
    return false;
  }
  return (request.bridgeContract?.isNotEmpty ?? false) &&
      (request.channelId?.isNotEmpty ?? false);
}

/// What the user must be shown before signing an ICS721 transfer.
///
/// Returned rather than thrown: none of these stop the transfer, they change
/// what the user is agreeing to.
List<String> ics721TransferWarnings(NftTransferRequest request) {
  final warnings = <String>[ics721VoucherWarning];
  if (request.destChainId == null) {
    warnings.add(
      'Destination chain is unknown; the receiver address was not checked.',
    );
  }
  if (request.timeoutMinutes == null) {
    warnings.add(
      'Using the default $defaultIcs721TimeoutMinutes-minute packet timeout.',
    );
  }
  return warnings;
}

/// Nanosecond timeout timestamp, [minutes] from [now].
///
/// BigInt because nanoseconds since the epoch passed 2^53 in 1970 + ~104 days;
/// an int would be fine on a 64-bit VM but not on the web, and the string has
/// to be exact either way.
String _timeoutTimestampNanos(int minutes, DateTime Function() now) {
  final millis = now().millisecondsSinceEpoch + minutes * 60000;
  return (BigInt.from(millis) * BigInt.from(1000000)).toString();
}

/// Build the ICS721 cross-chain NFT transfer.
///
/// This is a CW721 `send_nft` on the collection, targeting the cw-ics721 bridge
/// contract, whose `msg` is a base64 `IbcOutgoingMsg` carrying `receiver` and
/// `channel_id`. The NFT is escrowed by the bridge on this chain; the
/// destination mints a voucher. See [ics721VoucherWarning] — hosts must show it
/// before the signing prompt, not after.
///
/// Only `receiver` and `channel_id` are confirmed by the verified spec.
/// `timeout` is modelled on `cosmwasm_std::IbcTimeout` and always sent, because
/// the field does not appear to be optional in cw-ics721; `memo` is sent only
/// when given, because it does appear to be. Both can be overridden.
///
/// Throws [InterchainError] `unsupportedChain` when the chain lacks `cosmwasm`
/// or the host configured no bridge/channel, `contractError` for a bad address
/// or token id.
NftExecute buildIcs721TransferMsg(
  ChainInfo chain,
  NftTransferRequest request, {
  ChainInfo? destChain,
  Object? timeout,
  DateTime Function()? now,
  bool allowUnknownFeatures = false,
}) {
  assertCosmWasmChain(chain, allowUnknownFeatures: allowUnknownFeatures);

  if (request.chainId != chain.chainId) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'Request is for ${request.chainId} but the chain given is '
      '${chain.chainId}',
      chainId: chain.chainId,
    );
  }
  final bridgeContract = request.bridgeContract;
  if (bridgeContract == null || bridgeContract.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'No cw-ics721 bridge contract configured for ${chain.chainId}',
      chainId: chain.chainId,
    );
  }
  final channelId = request.channelId;
  if (channelId == null || channelId.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      'No ICS721 channel given for ${chain.chainId} → '
      '${request.destChainId ?? 'destination'}',
      chainId: chain.chainId,
    );
  }
  if (request.recipient.isEmpty) {
    throw InterchainError(
      InterchainErrorCode.contractError,
      'Recipient is required',
      chainId: chain.chainId,
    );
  }
  // The receiver is on the destination chain, so it is checked against that
  // chain's prefix when the host knows it, and left alone when it does not.
  if (destChain != null) {
    _assertChainAddress(destChain, request.recipient, 'Recipient');
  }

  final clock = now ?? DateTime.now;
  final resolvedTimeout = timeout ??
      <String, Object?>{
        'timestamp': _timeoutTimestampNanos(
          request.timeoutMinutes ?? defaultIcs721TimeoutMinutes,
          clock,
        ),
      };

  final outgoing = <String, Object?>{
    'receiver': request.recipient,
    'channel_id': channelId,
    'timeout': resolvedTimeout,
    // Omitted, not null, when absent: cw-ics721 takes an Option<String> and an
    // omitted key deserialises to None.
    if (request.memo != null) 'memo': request.memo,
  };

  return buildSendNftMsg(
    chain,
    sender: request.sender,
    collectionAddress: request.collectionAddress,
    tokenId: request.tokenId,
    contract: bridgeContract,
    msg: outgoing,
    allowUnknownFeatures: allowUnknownFeatures,
  );
}

/// Build the right message for an [NftTransferRequest].
///
/// Same chain (no `destChainId`, or one equal to `chainId`) is a `transfer_nft`;
/// anything else is ICS721. Callers that want the cross-chain warnings should
/// call [ics721TransferWarnings] as well — an [NftExecute] has nowhere to put
/// them.
NftExecute buildNftTransferMsg(
  ChainInfo chain,
  NftTransferRequest request, {
  ChainInfo? destChain,
  Object? timeout,
  DateTime Function()? now,
  bool allowUnknownFeatures = false,
}) {
  if (!request.isCrossChain) {
    return buildTransferNftMsg(
      chain,
      sender: request.sender,
      collectionAddress: request.collectionAddress,
      tokenId: request.tokenId,
      recipient: request.recipient,
      allowUnknownFeatures: allowUnknownFeatures,
    );
  }
  return buildIcs721TransferMsg(
    chain,
    request,
    destChain: destChain,
    timeout: timeout,
    now: now,
    allowUnknownFeatures: allowUnknownFeatures,
  );
}

/* -------------------------------------------------------------------------- *
 * Decoding what will be signed
 * -------------------------------------------------------------------------- */

/// What an [NftExecute] turned out to be.
///
/// `unknown` is the important one: it means the wallet could not account for
/// the message, and a screen that cannot say what a signature does must not
/// offer the signature.
enum NftExecuteKind { transferNft, sendNft, ics721Transfer, unknown }

/// A decoded CW721 execute, for the approval screen.
///
/// DIVERGENCE: no TypeScript twin. `MsgExecuteContract` is opaque, and
/// "Execute contract" is not informed consent, so the wallet reads back the
/// exact body it is about to sign — including the doubly-base64'd
/// `IbcOutgoingMsg` — rather than describing the intent it started from. If the
/// two ever disagree, this reports what the bytes say.
@immutable
class NftExecuteInspection {
  const NftExecuteInspection({
    required this.kind,
    required this.summary,
    required this.warnings,
    required this.collectionAddress,
    this.tokenId,
    this.recipient,
    this.receivingContract,
    this.channelId,
    this.innerMsg,
  });

  final NftExecuteKind kind;

  /// One line for a signing screen. Plain, factual, safe to render verbatim.
  final String summary;

  /// Things worth showing before the user approves. Not errors.
  final List<String> warnings;

  /// The CW721 contract the message executes against.
  final String collectionAddress;

  final String? tokenId;

  /// New owner (`transfer_nft`) or ICS721 receiver on the destination chain.
  final String? recipient;

  /// The contract a `send_nft` hands the token to — the bridge, for ICS721.
  final String? receivingContract;

  /// ICS721 channel read out of the decoded `IbcOutgoingMsg`.
  final String? channelId;

  /// The decoded inner `Binary`, when there was one. Null for `transfer_nft`.
  final Map<String, Object?>? innerMsg;

  /// True when the wallet could account for every part of the message.
  bool get readable => kind != NftExecuteKind.unknown;
}

/// Decode an [NftExecute] back into a sentence.
///
/// [collectionName] and [destChainName] are display strings the caller already
/// has; they only ever make the sentence more specific and are never used to
/// decide the [NftExecuteKind].
NftExecuteInspection inspectNftExecute(
  NftExecute execute, {
  String? collectionName,
  String? destChainName,
}) {
  final warnings = <String>[];
  final collection = collectionName?.trim().isNotEmpty ?? false
      ? '${collectionName!.trim()} (${execute.contract})'
      : execute.contract;

  final transfer = _asRecord(execute.msg['transfer_nft']);
  if (execute.msg.length == 1 && transfer != null) {
    final tokenId = _asString(transfer['token_id']);
    final recipient = _asString(transfer['recipient']);
    if (tokenId == null || recipient == null) {
      return NftExecuteInspection(
        kind: NftExecuteKind.unknown,
        summary: 'This transfer_nft is missing a token id or a recipient, so '
            'Zunia cannot say what it would move.',
        warnings: const [],
        collectionAddress: execute.contract,
      );
    }
    return NftExecuteInspection(
      kind: NftExecuteKind.transferNft,
      summary: 'Hands token $tokenId of $collection to $recipient on this '
          'chain. The transfer is final and Zunia cannot reverse it.',
      warnings: warnings,
      collectionAddress: execute.contract,
      tokenId: tokenId,
      recipient: recipient,
    );
  }

  final send = _asRecord(execute.msg['send_nft']);
  if (execute.msg.length == 1 && send != null) {
    final tokenId = _asString(send['token_id']);
    final receiving = _asString(send['contract']);
    final encoded = _asString(send['msg']);
    if (tokenId == null || receiving == null || encoded == null) {
      return NftExecuteInspection(
        kind: NftExecuteKind.unknown,
        summary: 'This send_nft is missing a token id, a receiving contract or '
            'its payload, so Zunia cannot say what it would do.',
        warnings: const [],
        collectionAddress: execute.contract,
      );
    }

    Map<String, Object?>? inner;
    try {
      inner = _asRecord(jsonDecode(utf8.decode(_decodeBase64Loose(encoded))));
    } on Object {
      inner = null;
    }
    if (inner == null) {
      return NftExecuteInspection(
        kind: NftExecuteKind.unknown,
        summary: 'This send_nft carries a payload Zunia could not decode, so '
            'nothing here can say what the receiving contract would do with '
            'token $tokenId.',
        warnings: const [],
        collectionAddress: execute.contract,
        tokenId: tokenId,
        receivingContract: receiving,
      );
    }

    final receiver = _asString(inner['receiver']);
    final channelId = _asString(inner['channel_id']);
    if (receiver != null && channelId != null) {
      warnings.add(ics721VoucherWarning);
      final where = destChainName?.trim().isNotEmpty ?? false
          ? destChainName!.trim()
          : 'the destination chain';
      return NftExecuteInspection(
        kind: NftExecuteKind.ics721Transfer,
        summary: 'Escrows token $tokenId of $collection in the bridge contract '
            '$receiving and asks it to deliver a voucher to $receiver on '
            '$where over $channelId.',
        warnings: warnings,
        collectionAddress: execute.contract,
        tokenId: tokenId,
        recipient: receiver,
        receivingContract: receiving,
        channelId: channelId,
        innerMsg: inner,
      );
    }

    // A send_nft that is not ICS721 is still describable: the token leaves for
    // a contract, and the payload is shown rather than summarised, because
    // nothing here knows what that contract does with it.
    warnings.add(
      'Zunia does not recognise this receiving contract, so it cannot say what '
      'happens to the token after it arrives.',
    );
    return NftExecuteInspection(
      kind: NftExecuteKind.sendNft,
      summary: 'Hands token $tokenId of $collection to the contract '
          '$receiving, with a payload it will act on.',
      warnings: warnings,
      collectionAddress: execute.contract,
      tokenId: tokenId,
      receivingContract: receiving,
      innerMsg: inner,
    );
  }

  return NftExecuteInspection(
    kind: NftExecuteKind.unknown,
    summary: 'Zunia does not recognise "${execute.action}" as a CW721 '
        'transfer, so it cannot describe what signing this would do.',
    warnings: const [],
    collectionAddress: execute.contract,
  );
}
