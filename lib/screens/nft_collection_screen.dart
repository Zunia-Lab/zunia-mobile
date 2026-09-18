/// The NFT gallery for one chain.
///
/// [NftGalleryView] is the body, so the Home tab's NFTs segment and the pushed
/// [NftCollectionScreen] show exactly the same thing rather than two views that
/// drift.
///
/// The screen's job is to never let a gallery imply something nobody checked.
/// CosmWasm has no chain-wide index of NFTs by owner, so "we asked five
/// collections and you hold nothing in them", "we had no address to ask about",
/// "this chain cannot run CW721 at all" and "we could not tell" are four
/// different sentences, and each of them is on screen instead of an empty grid.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/screens/nft_detail_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen gallery with its own chain picker.
class NftCollectionScreen extends ConsumerStatefulWidget {
  const NftCollectionScreen({super.key, this.chainId});

  final String? chainId;

  @override
  ConsumerState<NftCollectionScreen> createState() =>
      _NftCollectionScreenState();
}

class _NftCollectionScreenState extends ConsumerState<NftCollectionScreen> {
  late String? _chainId = widget.chainId;

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(chainAccountsProvider);
    if (accounts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Collectibles',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'No networks enabled',
              description:
                  'Enable a chain before looking for what this wallet holds on '
                  'it.',
            ),
          ),
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Collectibles',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ChainPicker(
                value: chainId,
                onChanged: (value) => setState(() => _chainId = value),
              ),
              const SizedBox(height: 16),
              NftGalleryView(chainId: chainId),
            ],
          ),
        ),
      ),
    );
  }
}

/// The gallery body: media switch, discovery honesty, grid, issues, and the
/// "add a collection address" escape hatch.
class NftGalleryView extends ConsumerStatefulWidget {
  const NftGalleryView({super.key, required this.chainId});

  final String chainId;

  @override
  ConsumerState<NftGalleryView> createState() => _NftGalleryViewState();
}

class _NftGalleryViewState extends ConsumerState<NftGalleryView> {
  final _address = TextEditingController();
  String? _addError;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    // After the first frame, so the provider is not written to during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didUpdateWidget(NftGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chainId != widget.chainId) _refresh();
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.read(nftGalleryProvider(widget.chainId).notifier).refresh();
  }

  Future<void> _addCollection() async {
    final value = _address.text.trim();
    final chain = ref.read(chainAccountsProvider).where(
          (a) => a.chain.chainId == widget.chainId,
        );
    final prefix = chain.isEmpty ? null : chain.first.chain.bech32Prefix;
    if (value.isEmpty) {
      setState(() => _addError = 'Paste a CW721 contract address first.');
      return;
    }
    // Checked against this chain's prefix rather than a generic bech32 shape:
    // an address from another chain is well-formed and would produce a
    // confusing "contract rejected the query" a screen later.
    if (prefix != null && !addressHasPrefix(value, prefix)) {
      setState(() => _addError =
          'That address is not on this chain: it does not start with '
          '"${prefix}1", so no contract here can have it.');
      return;
    }
    setState(() {
      _adding = true;
      _addError = null;
    });
    final added = await ref
        .read(nftUserCollectionsProvider)
        .add(widget.chainId, value);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _addError = added ? null : 'That collection is already on the list.';
      if (added) _address.clear();
    });
    if (added) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final state = ref.watch(nftGalleryProvider(widget.chainId));
    final prefs = ref.watch(preferencesProvider);
    final store = ref.watch(nftUserCollectionsProvider);
    final userContracts = store.forChain(widget.chainId);
    final mediaBlocked = nftMediaBlockedReason(
      liveReads: prefs.liveReads,
      mediaEnabled: prefs.nftMedia,
      hasIpfsGateway: kNftIpfsGateways.isNotEmpty,
    );

    // Media is only truly on when both switches allow it; the grid must not
    // build an Image widget otherwise, because a hidden one still fetches.
    final mediaOn = prefs.liveReads && prefs.nftMedia;

    final items = [
      for (final item in state.items)
        ZuniaNftCardItem(
          tokenId: item.tokenId,
          name: item.token?.name,
          collectionAddress: item.collectionAddress,
          collectionName: item.collectionName,
          // The chain id is already in the screen's chrome; repeating it on
          // every card at 320dp costs a line for nothing.
          imageUrl: mediaOn ? _imageUrlFor(item) : null,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ZuniaCheckbox(
          value: prefs.nftMedia,
          onChanged: (value) =>
              ref.read(preferencesProvider.notifier).setNftMedia(value),
          label: 'Show artwork',
          description: kZuniaNftMediaPrivacyNote,
        ),
        if (mediaBlocked != null && prefs.nftMedia) ...[
          const SizedBox(height: 8),
          ZuniaCallout(
            tone: ZuniaCalloutTone.info,
            title: 'Artwork is still off',
            body: mediaBlocked,
          ),
          if (!prefs.liveReads) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ZuniaButton(
                label: 'Open Settings',
                size: ZuniaButtonSize.sm,
                variant: ZuniaButtonVariant.secondary,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),

        // The grid renders the four "nothing to show" states through
        // unsupportedReason / error / empty rather than one shared blank.
        ZuniaNftGrid(
          items: items,
          loadMedia: mediaOn,
          loading: state.busy,
          unsupportedReason:
              state.status == NftGalleryStatus.unsupported ? state.reason : null,
          error: state.status == NftGalleryStatus.failed ? state.reason : null,
          onRetry: state.status == NftGalleryStatus.failed ? _refresh : null,
          emptyTitle: _emptyTitle(state.status),
          emptyDescription: state.reason ??
              'Nothing has been read for this address on this chain yet.',
          onSelect: (item) {
            final address = item.collectionAddress;
            if (address == null) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => NftDetailScreen(
                  chainId: widget.chainId,
                  collectionAddress: address,
                  tokenId: item.tokenId,
                ),
              ),
            );
          },
        ),

        if (state.status == NftGalleryStatus.loaded) ...[
          const SizedBox(height: 12),
          Text(
            _coverageLine(state),
            style: zuniaMono(fontSize: 10.5, height: 1.5, color: s.fgMuted),
          ),
        ],
        if (state.limitation != null &&
            state.status != NftGalleryStatus.unsupported &&
            state.status != NftGalleryStatus.nothingToQuery) ...[
          const SizedBox(height: 12),
          ZuniaCallout(
            tone: ZuniaCalloutTone.info,
            title: 'This list is not complete',
            body: state.limitation!,
          ),
        ],
        if (state.detailBudgetSpent) ...[
          const SizedBox(height: 12),
          ZuniaCallout(
            tone: ZuniaCalloutTone.info,
            title: 'Some cards have no detail yet',
            body: 'Every token found is listed, but names and artwork were '
                'only read for the first $kNftTokenDetailBudget. Open a card '
                'to read the rest of its detail.',
          ),
        ],
        for (final issue in state.issues) ...[
          const SizedBox(height: 12),
          ZuniaCallout(
            tone: ZuniaCalloutTone.warning,
            title: issue.contractAddress == null
                ? 'An index could not be read'
                : 'A collection could not be read',
            body: issue.contractAddress == null
                ? issue.message
                : '${truncateAddress(issue.contractAddress!)}: '
                    '${issue.message}',
          ),
        ],

        const SizedBox(height: 20),
        const ZuniaSectionLabel('Add a collection'),
        const SizedBox(height: 8),
        Text(
          'CosmWasm has no chain-wide list of NFTs by owner, so Zunia can only '
          'ask contracts it has an address for. Paste one and it is checked '
          'for this address and remembered.',
          style: zuniaSans(fontSize: 12, height: 1.5, color: s.fgMuted),
        ),
        const SizedBox(height: 10),
        ZuniaInput(
          controller: _address,
          label: 'CW721 CONTRACT ADDRESS',
          hint: 'e.g. addr_safro1…',
          errorText: _addError,
          onSubmitted: (_) => _addCollection(),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: ZuniaButton(
            label: 'Check this collection',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            loading: _adding,
            onPressed: _adding ? null : _addCollection,
          ),
        ),
        if (userContracts.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            'ADDED BY YOU',
            style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim),
          ),
          const SizedBox(height: 6),
          for (final address in userContracts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      truncateAddress(address, left: 12, right: 6),
                      style: zuniaMono(fontSize: 11, color: s.fgMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: 'Stop checking collection $address',
                    child: TextButton(
                      onPressed: () async {
                        await ref
                            .read(nftUserCollectionsProvider)
                            .remove(widget.chainId, address);
                        _refresh();
                      },
                      child: Text(
                        'Remove',
                        style: zuniaMono(fontSize: 11, color: s.info),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (kNftKnownCollections[widget.chainId] != null) ...[
          const SizedBox(height: 8),
          Text(
            'This build also ships '
            '${kNftKnownCollections[widget.chainId]!.length} '
            'collection${kNftKnownCollections[widget.chainId]!.length == 1 ? '' : 's'} '
            'for this chain.',
            style: zuniaMono(fontSize: 10.5, color: s.fgDim),
          ),
        ],
      ],
    );
  }

  /// Only ever a URL the engine resolved. A card never guesses a gateway.
  String? _imageUrlFor(NftGalleryItem item) {
    final image = item.token?.imageUri;
    if (image == null) return null;
    final resolved = resolveTokenUri(
      image,
      ipfsGateways: kNftIpfsGateways,
      arweaveGateways: kNftArweaveGateways,
    );
    if (resolved.kind != ResolvedTokenUriKind.http) return null;
    return resolved.urls.isEmpty ? null : resolved.urls.first;
  }

  String _emptyTitle(NftGalleryStatus status) => switch (status) {
        NftGalleryStatus.empty => 'Nothing in the collections checked',
        NftGalleryStatus.nothingToQuery => 'Nothing was checked',
        NftGalleryStatus.readsDisabled => 'Nothing was read',
        NftGalleryStatus.noEndpoint => 'This chain cannot be read',
        NftGalleryStatus.noAccount => 'No address on this chain',
        NftGalleryStatus.supportUnknown => 'Zunia cannot tell yet',
        NftGalleryStatus.loading => 'Looking…',
        _ => 'Nothing to show yet',
      };

  String _coverageLine(NftGalleryState state) {
    final where = state.complete
        ? 'An indexer answered, so this covers every collection it knows of.'
        : 'Read from ${state.contractsQueried} '
            '${state.contractsQueried == 1 ? 'collection' : 'collections'} '
            'Zunia knows about.';
    final paths = state.sources
        .map((source) => switch (source) {
              NftDiscoverySource.known => 'shipped list',
              NftDiscoverySource.user => 'addresses you added',
              NftDiscoverySource.indexer => 'indexer',
            })
        .join(', ');
    return paths.isEmpty ? where : '$where Source: $paths.';
  }
}
