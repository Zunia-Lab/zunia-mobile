/// Riverpod wiring for the NFT surface.
///
/// Everything chain-facing comes from `lib/services/interchain/nft.dart`, the
/// Dart mirror of `@zunialab/interchain`'s `nft.ts`. This file only decides
/// *which* questions get asked and turns each refusal into a sentence a screen
/// can render next to a disabled control.
///
/// The rule this file exists to enforce: an NFT list is never presented as a
/// fact about an account unless something was actually queried. CosmWasm has no
/// chain-wide "tokens by owner" index, so "nothing found" and "nothing asked"
/// are completely different states and [NftGalleryStatus] keeps them apart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/nft_metadata_fetcher.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// Token details fetched in one gallery run.
///
/// Every discovered id gets a card immediately — the id and the collection are
/// enough to render one — and this only caps how many get a name and an image
/// in the same pass. A cap on detail is honest; a cap on the list would not be.
const int kNftTokenDetailBudget = 24;

/* -------------------------------------------------------------------------- *
 * Chain capability
 * -------------------------------------------------------------------------- */

/// Whether a chain can hold CW721 tokens.
///
/// Three states, not two. `unknown` is the one that matters: the bundled chain
/// catalog drops the registry's `features` array, so the wallet frequently
/// cannot tell, and answering "no" would hide a working feature while answering
/// "yes" would fire wasm queries at chains that cannot serve them.
enum NftChainSupportState { supported, unsupported, unknown }

/// A capability verdict plus the sentence that explains it.
@immutable
class NftChainSupport {
  const NftChainSupport({
    required this.chainId,
    required this.state,
    required this.reason,
    required this.evidence,
  });

  final String chainId;
  final NftChainSupportState state;

  /// User-facing. Null only when [state] is `supported`.
  final String? reason;

  /// Which check produced this. Developer-facing, safe to log.
  final String evidence;

  bool get usable => state == NftChainSupportState.supported;
}

/// Does this chain run CosmWasm?
///
/// The registry's `features` list is the first authority. When it is absent —
/// which is every chain in the bundled catalog today — the chain itself is
/// asked, through the one wasm probe the channel service already owned. Live
/// reads being off is handled here rather than in the probe so the reason names
/// the setting the user can change.
final nftChainSupportProvider =
    FutureProvider.family<NftChainSupport, String>((ref, chainId) async {
  final registry = ref.watch(interchainRegistryProvider);
  final chain = registry.get(chainId);
  if (chain == null) {
    return NftChainSupport(
      chainId: chainId,
      state: NftChainSupportState.unknown,
      reason: '$chainId is not in the chain catalog, so Zunia cannot tell '
          'whether it runs CosmWasm.',
      evidence: 'chain is not in the registry',
    );
  }

  final features = chain.features;
  if (features != null) {
    final declared = features.contains(cosmWasmFeature);
    return NftChainSupport(
      chainId: chainId,
      state: declared
          ? NftChainSupportState.supported
          : NftChainSupportState.unsupported,
      reason: declared
          ? null
          : '${chain.chainName} does not run CosmWasm, so no CW721 contract '
              'can exist on it and no address can hold an NFT there. This is a '
              'property of the chain, not of your wallet.',
      evidence: 'registry features',
    );
  }

  if (lcdEndpointsFromChain(chain).isEmpty) {
    return NftChainSupport(
      chainId: chainId,
      state: NftChainSupportState.unknown,
      reason: '${chain.chainName} has no REST endpoint configured, and the '
          'bundled chain catalog does not carry its feature list, so Zunia '
          'cannot tell whether it runs CosmWasm.',
      evidence: 'no REST endpoint and no features',
    );
  }

  if (!ref.watch(preferencesProvider.select((p) => p.liveReads))) {
    return NftChainSupport(
      chainId: chainId,
      state: NftChainSupportState.unknown,
      reason: 'The bundled chain catalog does not say whether '
          '${chain.chainName} runs CosmWasm, and live reads are off, so the '
          'chain cannot be asked. Turn live reads on in Settings.',
      evidence: 'live reads are off',
    );
  }

  final probe = await ref.watch(channelServiceProvider).detectCosmWasmSupport(
        chainId,
      );
  return switch (probe.status) {
    ModuleSupportStatus.supported => NftChainSupport(
        chainId: chainId,
        state: NftChainSupportState.supported,
        reason: null,
        evidence: probe.evidence,
      ),
    ModuleSupportStatus.unsupported => NftChainSupport(
        chainId: chainId,
        state: NftChainSupportState.unsupported,
        reason: '${chain.chainName} answered that it has no CosmWasm module, '
            'so no CW721 contract can exist on it. This is a property of the '
            'chain, not of your wallet.',
        evidence: probe.evidence,
      ),
    ModuleSupportStatus.unknown => NftChainSupport(
        chainId: chainId,
        state: NftChainSupportState.unknown,
        reason: '${chain.chainName} did not answer whether it runs CosmWasm '
            '(${probe.evidence}), and the bundled chain catalog drops the '
            'registry feature list, so Zunia will not claim either way.',
        evidence: probe.evidence,
      ),
  };
});

/// A read context for a chain, or null when NFTs cannot be read there.
///
/// `allowUnknownFeatures` is true because reaching this point already means the
/// capability was established — by the registry or by asking the chain — and
/// the engine's own gate would otherwise refuse a catalog entry with no feature
/// list. Nothing else in the app may set that flag.
final nftContextProvider =
    FutureProvider.family<NftChainContext?, String>((ref, chainId) async {
  final support = await ref.watch(nftChainSupportProvider(chainId).future);
  if (!support.usable) return null;
  final chain = ref.watch(interchainRegistryProvider).get(chainId);
  if (chain == null || lcdEndpointsFromChain(chain).isEmpty) return null;
  return NftChainContext(
    chain: chain,
    lcd: ref.watch(lcdFactoryProvider)(chain),
    allowUnknownFeatures: true,
  );
});

/* -------------------------------------------------------------------------- *
 * Collections the user added by hand
 * -------------------------------------------------------------------------- */

const String _kUserCollections = 'zunia.nft.collections';

/// CW721 addresses the user typed in, per chain, persisted between launches.
///
/// The third discovery path, and on a build with no shipped list and no indexer
/// it is the only one. Kept separate from the shipped list so the gallery can
/// say which of the two an entry came from when a result looks wrong.
class NftUserCollectionStore extends ChangeNotifier {
  NftUserCollectionStore() {
    unawaited(_restore());
  }

  Map<String, List<String>> _byChain = const {};

  /// True once storage has been read, so a screen does not treat the empty
  /// startup map as "the user has added nothing".
  bool get loaded => _loaded;
  bool _loaded = false;

  List<String> forChain(String chainId) =>
      List.unmodifiable(_byChain[chainId] ?? const <String>[]);

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kUserCollections);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          _byChain = {
            for (final entry in decoded.entries)
              if (entry.value is List)
                entry.key: [
                  for (final value in entry.value! as List)
                    if (value is String && value.isNotEmpty) value,
                ],
          };
        }
      } on FormatException {
        // A corrupt list is dropped rather than repaired: half a set of
        // collection addresses looks authoritative and is not.
        _byChain = const {};
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final store = await SharedPreferences.getInstance();
    await store.setString(_kUserCollections, jsonEncode(_byChain));
  }

  /// Add an address. Returns false when it was already there.
  Future<bool> add(String chainId, String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return false;
    final next = Map<String, List<String>>.from(_byChain);
    final bucket = List<String>.from(next[chainId] ?? const <String>[]);
    if (bucket.contains(trimmed)) return false;
    bucket.add(trimmed);
    next[chainId] = bucket;
    _byChain = next;
    notifyListeners();
    await _save();
    return true;
  }

  Future<void> remove(String chainId, String address) async {
    final next = Map<String, List<String>>.from(_byChain);
    final bucket = List<String>.from(next[chainId] ?? const <String>[])
      ..remove(address);
    if (bucket.isEmpty) {
      next.remove(chainId);
    } else {
      next[chainId] = bucket;
    }
    _byChain = next;
    notifyListeners();
    await _save();
  }
}

final nftUserCollectionsProvider =
    ChangeNotifierProvider<NftUserCollectionStore>(
  (ref) => NftUserCollectionStore(),
);

/* -------------------------------------------------------------------------- *
 * Media policy
 * -------------------------------------------------------------------------- */

/// The metadata transport, or null when artwork must not be fetched.
///
/// Requires both switches. `liveReads` is the user's permission to talk to
/// chain endpoints; `nftMedia` is their separate permission to talk to whatever
/// host a stranger's token points at. Neither implies the other.
final nftMetadataFetcherProvider = Provider<NftMetadataFetcher?>((ref) {
  final prefs = ref.watch(preferencesProvider);
  return createNftMetadataFetcher(
    liveReads: prefs.liveReads,
    mediaEnabled: prefs.nftMedia,
  );
});

/// Why artwork is not being loaded, or null when it is.
///
/// Rendered next to the switch so the trade-off is stated where the choice is
/// made, and so "no picture" never reads as "broken".
String? nftMediaBlockedReason({
  required bool liveReads,
  required bool mediaEnabled,
  required bool hasIpfsGateway,
}) {
  if (!liveReads) {
    return 'Live reads are off, so nothing is fetched from any host — chain '
        'endpoints included. Turn them on in Settings first.';
  }
  if (!mediaEnabled) {
    return 'Artwork is off. Turning it on fetches images from whatever host '
        'each token points at, which tells that host your IP address and which '
        'tokens you hold.';
  }
  if (!hasIpfsGateway) {
    return 'Artwork stored on IPFS cannot be loaded: this build has no IPFS '
        'gateway configured, and Zunia does not pick one for you because that '
        'would route every collection through a single operator. Tokens hosted '
        'on https still load.';
  }
  return null;
}

/* -------------------------------------------------------------------------- *
 * Gallery
 * -------------------------------------------------------------------------- */

/// What the gallery is showing, and why.
///
/// The two states worth naming: `nothingToQuery` means no contract address was
/// available to ask about, so nothing was read and the list says nothing about
/// the account. `empty` means contracts were read and held nothing. Collapsing
/// those two into one empty state is the defect this enum exists to prevent.
enum NftGalleryStatus {
  idle,
  loading,
  unsupported,
  supportUnknown,
  readsDisabled,
  noEndpoint,
  noAccount,
  nothingToQuery,
  empty,
  loaded,
  failed,
}

/// One card's worth of what the wallet knows about a token.
@immutable
class NftGalleryItem {
  const NftGalleryItem({
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
    required this.source,
    this.token,
    this.collectionName,
    this.detailError,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;
  final NftDiscoverySource source;

  /// Null until the detail read lands, or when the budget ran out.
  final NftToken? token;

  final String? collectionName;

  /// Why this token has no detail. Null while none was attempted.
  final String? detailError;

  NftGalleryItem copyWith({
    NftToken? token,
    String? collectionName,
    String? detailError,
  }) =>
      NftGalleryItem(
        chainId: chainId,
        collectionAddress: collectionAddress,
        tokenId: tokenId,
        source: source,
        token: token ?? this.token,
        collectionName: collectionName ?? this.collectionName,
        detailError: detailError ?? this.detailError,
      );
}

/// Everything one chain's gallery needs to render honestly.
@immutable
class NftGalleryState {
  const NftGalleryState({
    required this.chainId,
    this.status = NftGalleryStatus.idle,
    this.reason,
    this.items = const [],
    this.issues = const [],
    this.sources = const [],
    this.contractsQueried = 0,
    this.complete = false,
    this.limitation,
    this.detailBudgetSpent = false,
  });

  final String chainId;
  final NftGalleryStatus status;

  /// Why the gallery is not showing tokens. Null when [status] is `loaded`.
  final String? reason;

  final List<NftGalleryItem> items;

  /// Contracts and indexers that could not be read. Shown, never swallowed.
  final List<NftDiscoveryIssue> issues;

  /// Which discovery paths contributed to this run.
  final List<NftDiscoverySource> sources;

  /// How many contracts were actually asked. `empty` with a zero here would be
  /// a lie, which is why [NftGalleryStatus.nothingToQuery] exists.
  final int contractsQueried;

  /// True only when an indexer answered without error.
  final bool complete;

  /// The engine's sentence about why a list can never be promised complete.
  final String? limitation;

  /// True when more tokens were found than [kNftTokenDetailBudget] allowed
  /// details for, so some cards show an id and no artwork.
  final bool detailBudgetSpent;

  bool get busy => status == NftGalleryStatus.loading;

  /// [reason] is deliberately *not* carried forward when omitted.
  ///
  /// Every other field defaults to its current value; a reason does not,
  /// because a stale one outliving the state that produced it is exactly how a
  /// screen ends up explaining a situation that no longer holds. Pass it every
  /// time the status is not `loaded`.
  NftGalleryState copyWith({
    NftGalleryStatus? status,
    String? reason,
    List<NftGalleryItem>? items,
    List<NftDiscoveryIssue>? issues,
    List<NftDiscoverySource>? sources,
    int? contractsQueried,
    bool? complete,
    String? limitation,
    bool? detailBudgetSpent,
  }) =>
      NftGalleryState(
        chainId: chainId,
        status: status ?? this.status,
        reason: reason,
        items: items ?? this.items,
        issues: issues ?? this.issues,
        sources: sources ?? this.sources,
        contractsQueried: contractsQueried ?? this.contractsQueried,
        complete: complete ?? this.complete,
        limitation: limitation ?? this.limitation,
        detailBudgetSpent: detailBudgetSpent ?? this.detailBudgetSpent,
      );
}

/// Runs discovery for one chain and enriches what it finds.
///
/// Nothing here runs on construction. A gallery that queried on mount would
/// scan every enabled chain the moment the app opened, which is both slow and a
/// privacy decision the user did not make; the screen calls [refresh].
class NftGalleryController extends StateNotifier<NftGalleryState> {
  NftGalleryController(this._ref, String chainId)
      : super(NftGalleryState(chainId: chainId));

  final Ref _ref;

  /// Guards against two overlapping runs writing each other's results.
  int _run = 0;

  Future<void> refresh() async {
    final run = ++_run;
    final chainId = state.chainId;
    state = state.copyWith(status: NftGalleryStatus.loading, reason: null);

    final support = await _ref.read(nftChainSupportProvider(chainId).future);
    if (run != _run) return;
    switch (support.state) {
      case NftChainSupportState.unsupported:
        state = state.copyWith(
          status: NftGalleryStatus.unsupported,
          reason: support.reason,
          items: const [],
        );
        return;
      case NftChainSupportState.unknown:
        state = state.copyWith(
          status: NftGalleryStatus.supportUnknown,
          reason: support.reason,
          items: const [],
        );
        return;
      case NftChainSupportState.supported:
        break;
    }

    final registry = _ref.read(interchainRegistryProvider);
    final chain = registry.get(chainId);
    final chainName = chain?.chainName ?? chainId;
    if (chain == null || lcdEndpointsFromChain(chain).isEmpty) {
      state = state.copyWith(
        status: NftGalleryStatus.noEndpoint,
        reason: '$chainName has no REST endpoint configured, so no contract '
            'on it can be queried.',
        items: const [],
      );
      return;
    }
    if (!_ref.read(preferencesProvider.select((p) => p.liveReads))) {
      state = state.copyWith(
        status: NftGalleryStatus.readsDisabled,
        reason: 'Live reads are off, so no CW721 contract was queried. This '
            'says nothing about what this address holds.',
        items: const [],
      );
      return;
    }

    String? owner;
    for (final account in _ref.read(chainAccountsProvider)) {
      if (account.chain.chainId == chainId) owner = account.address;
    }
    if (owner == null) {
      state = state.copyWith(
        status: NftGalleryStatus.noAccount,
        reason: 'This wallet has no address on $chainName, so there is nothing '
            'to look up. Enable the network first.',
        items: const [],
      );
      return;
    }

    final known = kNftKnownCollections[chainId] ?? const <String>[];
    final user = _ref.read(nftUserCollectionsProvider).forChain(chainId);
    if (known.isEmpty && user.isEmpty && !kNftIndexerAvailable) {
      state = state.copyWith(
        status: NftGalleryStatus.nothingToQuery,
        reason: 'Nothing was queried. CosmWasm has no chain-wide index of NFTs '
            'by owner, this build ships no collection list for $chainName, and '
            'no indexer is configured — so without a contract address there is '
            'no question to ask. Paste a collection address to check one.',
        items: const [],
        contractsQueried: 0,
      );
      return;
    }

    final ctx = await _ref.read(nftContextProvider(chainId).future);
    if (run != _run) return;
    if (ctx == null) {
      state = state.copyWith(
        status: NftGalleryStatus.noEndpoint,
        reason: 'Zunia could not open a read connection to $chainName.',
        items: const [],
      );
      return;
    }

    NftDiscoveryResult discovery;
    try {
      discovery = await discoverNfts(
        ctx,
        owner,
        options: NftDiscoveryOptions(
          knownContracts: known,
          userContracts: user,
          request: const LcdRequestOptions(cacheTtl: Duration(seconds: 30)),
        ),
      );
    } on InterchainError catch (error) {
      if (run != _run) return;
      state = state.copyWith(
        status: NftGalleryStatus.failed,
        reason: 'Could not read collections on $chainName: ${error.message}',
        items: const [],
      );
      return;
    }
    if (run != _run) return;

    final queried = <String>{...known, ...user}.length;
    final items = <NftGalleryItem>[
      for (final holding in discovery.holdings)
        for (final tokenId in holding.tokenIds)
          NftGalleryItem(
            chainId: chainId,
            collectionAddress: holding.contractAddress,
            tokenId: tokenId,
            source: holding.source,
          ),
    ];

    state = state.copyWith(
      status: items.isEmpty ? NftGalleryStatus.empty : NftGalleryStatus.loaded,
      reason: items.isEmpty
          ? 'Zunia queried $queried '
              '${queried == 1 ? 'collection' : 'collections'} on $chainName and '
              'this address holds nothing in '
              '${queried == 1 ? 'it' : 'them'}. Other collections it does not '
              'know about are not covered.'
          : null,
      items: items,
      issues: discovery.issues,
      sources: discovery.sources,
      contractsQueried: queried,
      complete: discovery.complete,
      limitation: discovery.limitation,
      detailBudgetSpent: items.length > kNftTokenDetailBudget,
    );

    await _loadDetail(run, ctx, discovery);
  }

  /// Fill in names, images and collection titles, one call at a time.
  ///
  /// Sequential on purpose: these are public LCD nodes and a burst of wasm
  /// queries is the fastest way to be rate-limited into looking broken.
  Future<void> _loadDetail(
    int run,
    NftChainContext ctx,
    NftDiscoveryResult discovery,
  ) async {
    final names = <String, String>{};
    for (final holding in discovery.holdings) {
      if (run != _run) return;
      try {
        final info = await getCollectionInfo(
          ctx,
          holding.contractAddress,
          includeTokenCount: false,
          request: const LcdRequestOptions(cacheTtl: Duration(minutes: 5)),
        );
        final name = info.name;
        if (name != null) names[holding.contractAddress] = name;
      } on InterchainError {
        // A collection that will not name itself still shows its address, and
        // its tokens are not hidden over a missing title.
      }
      if (run != _run) return;
      state = state.copyWith(
        items: [
          for (final item in state.items)
            item.collectionName == null && names.containsKey(item.collectionAddress)
                ? item.copyWith(collectionName: names[item.collectionAddress])
                : item,
        ],
      );
    }

    var spent = 0;
    for (final item in [...state.items]) {
      if (run != _run) return;
      if (spent >= kNftTokenDetailBudget) break;
      spent += 1;
      NftToken? token;
      String? failure;
      try {
        token = await getNftToken(
          ctx,
          item.collectionAddress,
          item.tokenId,
          request: const LcdRequestOptions(cacheTtl: Duration(minutes: 1)),
        );
      } on InterchainError catch (error) {
        failure = error.message;
      }
      if (run != _run) return;
      state = state.copyWith(
        items: [
          for (final row in state.items)
            row.collectionAddress == item.collectionAddress &&
                    row.tokenId == item.tokenId
                ? row.copyWith(token: token, detailError: failure)
                : row,
        ],
      );
    }
  }
}

final nftGalleryProvider = StateNotifierProvider.family<NftGalleryController,
    NftGalleryState, String>(
  (ref, chainId) => NftGalleryController(ref, chainId),
);

/* -------------------------------------------------------------------------- *
 * One token
 * -------------------------------------------------------------------------- */

/// Identity of a token, and the key of [nftTokenDetailProvider].
@immutable
class NftTokenRef {
  const NftTokenRef({
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;

  @override
  bool operator ==(Object other) =>
      other is NftTokenRef &&
      other.chainId == chainId &&
      other.collectionAddress == collectionAddress &&
      other.tokenId == tokenId;

  @override
  int get hashCode => Object.hash(chainId, collectionAddress, tokenId);
}

/// One token, its collection, and an honest account of its artwork.
@immutable
class NftTokenDetail {
  const NftTokenDetail({
    required this.token,
    this.collection,
    this.imageUrl,
    this.imageReason,
    this.metadataSource,
    this.metadataReason,
  });

  final NftToken token;
  final NftCollection? collection;

  /// A URL the platform can fetch, or null. Never a guess.
  final String? imageUrl;

  /// Why there is no [imageUrl]. Null when there is one.
  final String? imageReason;

  /// Where the off-chain document came from, when one was read.
  final NftMetadataSource? metadataSource;

  /// Why off-chain metadata was not read. Null when it was, or when the token
  /// carries no `token_uri` to read.
  final String? metadataReason;
}

/// Load one token: on-chain first, then the off-chain document if and only if
/// the user has turned artwork on.
///
/// The on-chain `extension` always wins over the fetched document, because the
/// former is in chain state and the latter is whatever a host served this
/// second.
final nftTokenDetailProvider =
    FutureProvider.family<NftTokenDetail, NftTokenRef>((ref, key) async {
  final ctx = await ref.watch(nftContextProvider(key.chainId).future);
  if (ctx == null) {
    final support = await ref.watch(nftChainSupportProvider(key.chainId).future);
    throw InterchainError(
      InterchainErrorCode.unsupportedChain,
      support.reason ?? 'This chain cannot be read for CW721 tokens.',
      chainId: key.chainId,
    );
  }

  var token = await getNftToken(ctx, key.collectionAddress, key.tokenId);

  NftCollection? collection;
  try {
    collection = await getCollectionInfo(ctx, key.collectionAddress);
  } on InterchainError {
    // A nameless collection is still a collection; its address carries the
    // identity and the screen shows that instead.
  }

  final prefs = ref.watch(preferencesProvider);
  final fetcher = ref.watch(nftMetadataFetcherProvider);
  NftMetadataSource? source;
  String? metadataReason;

  final tokenUri = token.tokenUri;
  if (tokenUri != null) {
    try {
      final result = await fetchNftMetadata(
        tokenUri,
        fetch: fetcher,
        ipfsGateways: kNftIpfsGateways,
        arweaveGateways: kNftArweaveGateways,
      );
      token = applyNftMetadata(token, result.metadata);
      source = result.source;
    } on InterchainError catch (error) {
      metadataReason = error.code == InterchainErrorCode.readsDisabled
          ? nftMediaBlockedReason(
              liveReads: prefs.liveReads,
              mediaEnabled: prefs.nftMedia,
              hasIpfsGateway: kNftIpfsGateways.isNotEmpty,
            )
          : 'The off-chain metadata document could not be read: '
              '${error.message}';
    }
  }

  final image = token.imageUri;
  String? imageUrl;
  String? imageReason;
  if (image == null) {
    imageReason = 'This token carries no image, on chain or off.';
  } else if (!prefs.nftMedia || !prefs.liveReads) {
    imageReason = nftMediaBlockedReason(
      liveReads: prefs.liveReads,
      mediaEnabled: prefs.nftMedia,
      hasIpfsGateway: kNftIpfsGateways.isNotEmpty,
    );
  } else {
    final resolved = resolveTokenUri(
      image,
      ipfsGateways: kNftIpfsGateways,
      arweaveGateways: kNftArweaveGateways,
    );
    if (resolved.kind == ResolvedTokenUriKind.http && resolved.urls.isNotEmpty) {
      imageUrl = resolved.urls.first;
    } else {
      imageReason = 'Zunia cannot turn this token\'s image reference into a '
          'URL it may fetch: ${resolved.reason ?? 'unsupported reference'}.';
    }
  }

  return NftTokenDetail(
    token: token,
    collection: collection,
    imageUrl: imageUrl,
    imageReason: imageReason,
    metadataSource: source,
    metadataReason: metadataReason,
  );
});

/* -------------------------------------------------------------------------- *
 * ICS721 configuration
 * -------------------------------------------------------------------------- */

/// The cw-ics721 bridge and channel for one direction, or the reason there is
/// none.
///
/// Both halves are deployment data. There is no fallback and no candidate list:
/// `send_nft` hands the token to whatever address is named here, and a wrong
/// one escrows it where nothing can release it.
@immutable
class Ics721Route {
  const Ics721Route({this.bridgeContract, this.channelId, this.reason});

  final String? bridgeContract;
  final String? channelId;

  /// Null only when [ready].
  final String? reason;

  bool get ready => bridgeContract != null && channelId != null;
}

/// Resolve the configured ICS721 route for a directed chain pair.
Ics721Route ics721RouteFor({
  required String sourceChainId,
  required String destChainId,
  String? sourceChainName,
  String? destChainName,
}) {
  final from = sourceChainName ?? sourceChainId;
  final to = destChainName ?? destChainId;
  final bridge = kIcs721Bridges[sourceChainId];
  if (bridge == null || bridge.isEmpty) {
    return Ics721Route(
      reason: 'This build has no cw-ics721 bridge contract for $from. Sending '
          'an NFT across chains hands it to that contract for safekeeping, so '
          'Zunia will not guess the address: a wrong one escrows the token '
          'where nothing can release it.',
    );
  }
  final channel = kIcs721Channels[ics721ChannelKey(sourceChainId, destChainId)];
  if (channel == null || channel.isEmpty) {
    return Ics721Route(
      bridgeContract: bridge,
      reason: 'This build has no ICS721 channel from $from to $to. ICS721 runs '
          'on its own port, so a normal IBC transfer channel cannot be reused '
          'and Zunia will not substitute one.',
    );
  }
  return Ics721Route(bridgeContract: bridge, channelId: channel);
}

/// Chains this wallet could send an NFT to over ICS721 from [sourceChainId].
List<String> ics721DestinationsFrom(String sourceChainId) {
  final prefix = '$sourceChainId>';
  return [
    for (final key in kIcs721Channels.keys)
      if (key.startsWith(prefix)) key.substring(prefix.length),
  ];
}
