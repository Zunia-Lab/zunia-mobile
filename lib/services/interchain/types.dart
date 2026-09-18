/// Shared contract for the interchain engine.
///
/// This directory is a Dart mirror of `@zunialab/interchain`
/// (`zunia-sdk/packages/interchain/src`), module for module and name for name,
/// because mobile cannot import the TypeScript package and two implementations
/// that drift are worse than one that is duplicated on purpose. When a module
/// here diverges from its TS twin the divergence is commented and named.
///
/// Layering, same as the TS package: `types.dart` depends on nothing;
/// `lcd.dart`, `registry.dart` and `channels.dart` depend only on it;
/// `memo.dart` and `denom.dart` sit above those; `swap.dart` above `memo.dart`;
/// `route.dart` above all of them. `tracking.dart` is a leaf. No cycles.
library;

import 'package:flutter/foundation.dart';

/// ICS20 port. Every transfer channel in this package uses it unless a caller
/// names another (cw20-ics20 uses `wasm.<contract>`, ICS721 its own).
const String transferPort = 'transfer';

/// Discriminants for [InterchainError]. Switch on these, never on the message:
/// the message is developer-facing and the copy shown to a user is chosen by
/// the screen.
enum InterchainErrorCode {
  noRoute,
  invalidRequest,
  channelClosed,
  lcdUnreachable,
  unsupportedChain,
  unsupportedEnvironment,
  invalidMemo,
  slippageExceeded,
  packetTimeout,
  contractError,
  txRejected,
  malformedResponse,
  readsDisabled,
  aborted,
}

/// The only error type this engine throws.
class InterchainError implements Exception {
  InterchainError(
    this.code,
    this.message, {
    this.chainId,
    this.channelId,
    this.endpoint,
    this.httpStatus,
    this.cause,
  });

  final InterchainErrorCode code;

  /// Developer-facing. Screens map [code] to their own copy.
  final String message;

  final String? chainId;
  final String? channelId;
  final String? endpoint;
  final int? httpStatus;
  final Object? cause;

  @override
  String toString() => 'InterchainError(${code.name}): $message';
}

/* -------------------------------------------------------------------------- *
 * Chains
 * -------------------------------------------------------------------------- */

/// The chain metadata this engine reads. Deliberately narrower than the app's
/// `ChainEntry`: nothing here should need a gas price or an icon.
@immutable
class ChainInfo {
  const ChainInfo({
    required this.chainId,
    required this.chainName,
    required this.bech32Prefix,
    required this.coinMinimalDenom,
    this.network = 'mainnet',
    this.rest,
    this.features,
  });

  final String chainId;
  final String chainName;
  final String bech32Prefix;
  final String coinMinimalDenom;

  /// `mainnet` or `testnet`. A route that mixes the two never completes.
  final String network;

  /// REST base URL, or null when the chain has none configured.
  final String? rest;

  /// Registry `features`, e.g. `['cosmwasm']`.
  ///
  /// Null means nobody told us, which is NOT the same as `[]`. The bundled
  /// catalog generator drops the field today, so null is the common case and
  /// every consumer must treat it as "unknown", never as "unsupported".
  final List<String>? features;
}

/// Chain lookup. Implemented over the app's `ChainCatalog` in `registry.dart`.
abstract class ChainRegistry {
  ChainInfo? get(String chainId);

  /// Every chain, for the "which chain calls this denom native?" fallback.
  List<ChainInfo> list();
}

/* -------------------------------------------------------------------------- *
 * IBC channels
 * -------------------------------------------------------------------------- */

/// Channel handshake state, normalised from the LCD's `STATE_OPEN` spelling.
///
/// `tryopen` is spelled as one word to match `IbcChannelState` in the TS
/// package and `ZuniaChannelState` in `zunia_ui`, so a value crosses all three
/// without a lookup table.
enum IbcChannelState { open, closed, init, tryopen, unknown }

/// One transfer channel found on the source chain.
@immutable
class IbcChannelOption {
  const IbcChannelOption({
    required this.channelId,
    required this.portId,
    required this.counterpartyChannelId,
    required this.counterpartyPortId,
    required this.connectionId,
    required this.counterpartyChainId,
    required this.state,
  });

  final String channelId;
  final String portId;
  final String counterpartyChannelId;
  final String counterpartyPortId;
  final String connectionId;

  /// Null when the connection's client state could not be resolved.
  final String? counterpartyChainId;

  final IbcChannelState state;
}

/// How the far side of a channel answered.
enum CounterpartyCheckStatus { ok, notFound, notOpen, mismatch, unreachable, skipped }

/// The destination chain's view of a channel.
@immutable
class CounterpartyCheck {
  const CounterpartyCheck({
    required this.status,
    required this.ok,
    required this.chainId,
    required this.channelId,
    required this.portId,
    required this.state,
    required this.pointsBackTo,
    required this.message,
  });

  final CounterpartyCheckStatus status;
  final bool ok;
  final String? chainId;
  final String? channelId;
  final String? portId;
  final IbcChannelState state;

  /// The channel the far side names as its counterparty, or null.
  final String? pointsBackTo;

  /// User-facing. Rendered as-is.
  final String message;
}

/// Result of checking one channel id, including the copy the screen renders.
@immutable
class IbcChannelCheck {
  const IbcChannelCheck({
    required this.ok,
    required this.state,
    required this.channelId,
    required this.portId,
    required this.message,
    this.counterpartyChannelId,
    this.counterpartyChainId,
    this.counterparty,
  });

  final bool ok;
  final IbcChannelState state;
  final String channelId;
  final String portId;
  final String message;
  final String? counterpartyChannelId;
  final String? counterpartyChainId;

  /// Populated only when the caller asked for the counterparty check.
  final CounterpartyCheck? counterparty;
}

/* -------------------------------------------------------------------------- *
 * Denoms
 * -------------------------------------------------------------------------- */

/// A denom trace, normalised from
/// `{ "path": "transfer/channel-0", "base_denom": "uatom" }`.
@immutable
class DenomTrace {
  const DenomTrace({required this.path, required this.baseDenom});

  /// Slash-joined `port/channel` pairs, outermost hop first.
  final String path;

  /// The denom on its origin chain, e.g. `uatom`.
  final String baseDenom;
}

/// One `port/channel` pair out of a [DenomTrace.path].
@immutable
class DenomHop {
  const DenomHop({required this.port, required this.channelId});

  final String port;
  final String channelId;

  @override
  bool operator ==(Object other) =>
      other is DenomHop && other.port == port && other.channelId == channelId;

  @override
  int get hashCode => Object.hash(port, channelId);
}

/// A denom after resolution.
@immutable
class ResolvedDenom {
  const ResolvedDenom({
    required this.denom,
    required this.baseDenom,
    required this.path,
    required this.hops,
    required this.originChainId,
    required this.isNative,
    required this.ibcHash,
  });

  /// As presented on the holding chain: `uatom` or `ibc/27394F…`.
  final String denom;
  final String baseDenom;

  /// Raw trace path; `''` for a native denom.
  final String path;

  /// Parsed [path], outermost hop first. Empty for a native denom.
  final List<DenomHop> hops;

  /// Origin chain id, or null when it could not be resolved. Never guessed.
  final String? originChainId;

  final bool isNative;

  /// Uppercase SHA-256 of `path/baseDenom`; null for a native denom.
  final String? ibcHash;
}

/* -------------------------------------------------------------------------- *
 * Routing
 * -------------------------------------------------------------------------- */

/// What happens at a hop.
///
/// - `transfer` — the ICS20 send the user signs on the source chain.
/// - `forward` — a packet-forward-middleware hop, executed from the memo by the
///   intermediate chain. The user does not sign it.
/// - `swap` — an ibc-hooks contract call, executed inside packet processing.
///   The relayer pays that gas, not the user.
enum RouteHopKind { transfer, forward, swap }

/// One leg of a [RoutePlan].
@immutable
class RouteHop {
  const RouteHop({
    required this.chainId,
    required this.channelId,
    required this.port,
    required this.counterpartyChainId,
    required this.kind,
  });

  final String chainId;

  /// Empty for a swap, which moves no packet of its own.
  final String channelId;
  final String port;
  final String? counterpartyChainId;
  final RouteHopKind kind;
}

/// A complete plan for moving value from one chain to another.
///
/// Inert data: one ICS20 transfer plus the memo that makes the remaining hops
/// happen. Nothing here is signed.
@immutable
class RoutePlan {
  const RoutePlan({
    required this.sourceChainId,
    required this.destChainId,
    required this.inputDenom,
    required this.outputDenom,
    required this.hops,
    required this.memo,
    required this.warnings,
    required this.estimatedDurationSeconds,
    required this.requiresPfm,
    required this.requiresIbcHooks,
  });

  final String sourceChainId;
  final String destChainId;

  /// Denom as held on the source chain (`ibc/…` or native).
  final String inputDenom;

  /// Denom the recipient ends up with on the destination chain.
  final String outputDenom;

  /// Hops in execution order; `hops[0]` is the transfer the user signs.
  final List<RouteHop> hops;

  /// ICS20 memo for the first transfer. `''` when none is needed — an empty
  /// memo and an absent memo are the same thing on the wire.
  final String memo;

  final List<String> warnings;
  final int estimatedDurationSeconds;
  final bool requiresPfm;
  final bool requiresIbcHooks;
}

/// What the caller wants; the router turns this into a [RoutePlan].
@immutable
class RouteRequest {
  const RouteRequest({
    required this.sourceChainId,
    required this.destChainId,
    required this.inputDenom,
    required this.amount,
    required this.sender,
    required this.recipient,
    this.outputDenom,
    this.slippagePercent,
    this.maxHops,
    this.allowSwap = false,
    this.allowPfm = true,
    this.timeoutMinutes,
    this.recoveryAddress,
  });

  final String sourceChainId;
  final String destChainId;
  final String inputDenom;

  /// Base units as a decimal string. Never a number: uint128 does not fit.
  final String amount;

  final String sender;
  final String recipient;

  /// Defaults to the unwrapped [inputDenom].
  final String? outputDenom;

  /// Tolerated slippage as a percentage, e.g. `1` for 1%. Swaps only.
  final double? slippagePercent;

  final int? maxHops;
  final bool allowSwap;
  final bool allowPfm;
  final int? timeoutMinutes;

  /// Address that can reclaim funds if a swap succeeds but delivery fails
  /// (`on_failed_delivery.local_recovery_addr`). Without it the contract is
  /// told `"do_nothing"` and stuck funds are unrecoverable, so wallets set it.
  final String? recoveryAddress;
}

/* -------------------------------------------------------------------------- *
 * Swaps
 * -------------------------------------------------------------------------- */

/// One pool leg of a swap route.
@immutable
class SwapPoolHop {
  const SwapPoolHop({required this.poolId, required this.tokenOutDenom});

  final String poolId;

  /// Denom leaving this pool, i.e. the input to the next hop.
  final String tokenOutDenom;
}

/// A priced swap.
///
/// Amounts are base units as decimal strings so nothing is lost to floating
/// point. The percentages are doubles because they are display values.
@immutable
class SwapQuote {
  const SwapQuote({
    required this.inputDenom,
    required this.inputAmount,
    required this.outputDenom,
    required this.outputAmount,
    required this.priceImpact,
    required this.poolFee,
    required this.minReceived,
    required this.slippagePercent,
    required this.route,
  });

  final String inputDenom;
  final String inputAmount;
  final String outputDenom;

  /// Expected output before slippage, base units.
  final String outputAmount;

  /// Price impact as a percentage, e.g. 0.42 for 0.42%. Null when the venue
  /// did not report one — never 0, which would read as "no impact".
  final double? priceImpact;

  /// Total pool fee as a percentage of the input. Null when not reported.
  final double? poolFee;

  /// Guaranteed minimum output at [slippagePercent], base units.
  final String minReceived;

  final double slippagePercent;

  /// Pools traversed, in order. Empty when the venue does not expose them.
  final List<SwapPoolHop> route;
}

/* -------------------------------------------------------------------------- *
 * Packet tracking
 * -------------------------------------------------------------------------- */

/// Lifecycle of one IBC packet.
///
/// - `pending` — the send tx committed; no relayer action seen yet.
/// - `relayed` — a `recv_packet` was submitted on the counterparty.
/// - `received` — the counterparty wrote a receipt; funds have landed.
/// - `acknowledged` — the ack came back. Terminal, success.
/// - `timeout` — the deadline passed and funds were refunded.
/// - `failed` — an error acknowledgement; the destination rejected the packet.
/// - `unknown` — no endpoint could tell us. Not an error; keep polling.
enum PacketStatus {
  pending,
  relayed,
  received,
  acknowledged,
  timeout,
  failed,
  unknown,
}

/* -------------------------------------------------------------------------- *
 * NFTs
 * -------------------------------------------------------------------------- */

/// One trait from the CW721 metadata extension.
///
/// Upstream JSON is `{ "trait_type": …, "value": …, "display_type": … }`. The
/// extension is free-form, so parsers tolerate missing keys and coerce
/// non-string values rather than dropping the trait: a level of `7` is still a
/// trait the holder expects to see.
@immutable
class NftAttribute {
  const NftAttribute({
    required this.traitType,
    required this.value,
    this.displayType,
  });

  final String traitType;
  final String value;
  final String? displayType;

  @override
  bool operator ==(Object other) =>
      other is NftAttribute &&
      other.traitType == traitType &&
      other.value == value &&
      other.displayType == displayType;

  @override
  int get hashCode => Object.hash(traitType, value, displayType);
}

/// One token. Every metadata field is nullable: the extension is optional, and
/// a null here means "the contract did not say", never "empty".
@immutable
class NftToken {
  const NftToken({
    required this.tokenId,
    required this.collectionAddress,
    required this.chainId,
    this.name,
    this.description,
    this.imageUri,
    this.animationUri,
    this.attributes = const [],
    this.owner,
    this.tokenUri,
  });

  final String tokenId;

  final String? name;
  final String? description;

  /// May be `ipfs://…`. Resolving a gateway is the host's decision, not the
  /// engine's, because it decides which third party learns what this wallet
  /// holds.
  final String? imageUri;

  final String? animationUri;
  final List<NftAttribute> attributes;

  final String collectionAddress;
  final String chainId;

  /// Current owner from `owner_of`, when the caller asked for it.
  final String? owner;

  /// Raw `token_uri`, before any off-chain metadata is fetched.
  final String? tokenUri;

  NftToken copyWith({
    String? name,
    String? description,
    String? imageUri,
    String? animationUri,
    List<NftAttribute>? attributes,
    String? owner,
  }) =>
      NftToken(
        tokenId: tokenId,
        collectionAddress: collectionAddress,
        chainId: chainId,
        name: name ?? this.name,
        description: description ?? this.description,
        imageUri: imageUri ?? this.imageUri,
        animationUri: animationUri ?? this.animationUri,
        attributes: attributes ?? this.attributes,
        owner: owner ?? this.owner,
        tokenUri: tokenUri,
      );
}

/// A CW721 collection, from `collection_info` or the older `contract_info`.
@immutable
class NftCollection {
  const NftCollection({
    required this.chainId,
    required this.contractAddress,
    this.name,
    this.symbol,
    this.description,
    this.imageUri,
    this.tokenCount,
    this.creator,
  });

  final String chainId;

  /// CW721 contract address. Same value as [NftToken.collectionAddress].
  final String contractAddress;

  final String? name;
  final String? symbol;
  final String? description;
  final String? imageUri;

  /// From `{"num_tokens":{}}`; null when the contract does not answer it.
  final int? tokenCount;

  /// From `collection_info` / `contract_info`; older contracts omit it.
  final String? creator;
}

/// A request to move an NFT.
///
/// Same-chain when [destChainId] is null or equal to [chainId] (a CW721
/// `transfer_nft`); otherwise ICS721, which is a `send_nft` to the bridge
/// contract carrying a base64 `msg` with `receiver` and `channel_id`.
@immutable
class NftTransferRequest {
  const NftTransferRequest({
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
    required this.sender,
    required this.recipient,
    this.destChainId,
    this.channelId,
    this.bridgeContract,
    this.timeoutMinutes,
    this.memo,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;
  final String sender;
  final String recipient;

  /// Destination chain for a cross-chain transfer.
  final String? destChainId;

  /// ICS721 channel on [chainId]. Required for cross-chain.
  final String? channelId;

  /// cw-ics721 bridge contract on [chainId]. Never hardcode one: it is
  /// per-chain deployment data and must come from host config, exactly like the
  /// crosschain-swaps address.
  final String? bridgeContract;

  /// Packet timeout in minutes.
  final int? timeoutMinutes;

  /// Passed through when the bridge supports it.
  final String? memo;

  bool get isCrossChain => destChainId != null && destChainId != chainId;

  NftTransferRequest copyWith({
    String? recipient,
    String? destChainId,
    String? channelId,
    String? bridgeContract,
    int? timeoutMinutes,
    String? memo,
  }) =>
      NftTransferRequest(
        chainId: chainId,
        collectionAddress: collectionAddress,
        tokenId: tokenId,
        sender: sender,
        recipient: recipient ?? this.recipient,
        destChainId: destChainId ?? this.destChainId,
        channelId: channelId ?? this.channelId,
        bridgeContract: bridgeContract ?? this.bridgeContract,
        timeoutMinutes: timeoutMinutes ?? this.timeoutMinutes,
        memo: memo ?? this.memo,
      );
}
