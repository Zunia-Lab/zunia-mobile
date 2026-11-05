/// The NFT gallery for one chain.
///
/// [NftGalleryView] is the body, so the Home tab's NFTs segment and the pushed
/// [NftCollectionScreen] show exactly the same thing rather than two views that
/// drift.
///
/// Gallery first: every "nothing to show" state is an icon, a short title, at
/// most one short line and the single useful action, never a paragraph.
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
              description: 'Enable a network to see its NFTs.',
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
  final _addKey = GlobalKey();
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

  void _refresh({bool force = false}) {
    if (!mounted) return;
    ref.read(nftGalleryProvider(widget.chainId).notifier).refresh(force: force);
  }

  /// Scrolls down to the add-a-collection field.
  void _focusAdd() {
    final ctx = _addKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );

  Future<void> _addCollection() async {
    final value = _address.text.trim();
    final chain = ref.read(chainAccountsProvider).where(
          (a) => a.chain.chainId == widget.chainId,
        );
    final prefix = chain.isEmpty ? null : chain.first.chain.bech32Prefix;
    if (value.isEmpty) {
      setState(() => _addError = 'Paste a contract address first.');
      return;
    }
    // Checked against this chain's prefix rather than a generic bech32 shape:
    // an address from another chain is well-formed and would produce a
    // confusing "contract rejected the query" a screen later.
    if (prefix != null && !addressHasPrefix(value, prefix)) {
      setState(() => _addError = 'Address must start with "${prefix}1".');
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
      _addError = added ? null : 'Already on your list.';
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

    final chain = ref
        .watch(chainAccountsProvider)
        .where((a) => a.chain.chainId == widget.chainId)
        .firstOrNull
        ?.chain;
    final chainName = chain?.chainName ?? widget.chainId;
    final status = state.status;
    final showEmpty = items.isEmpty &&
        !state.busy &&
        status != NftGalleryStatus.idle &&
        status != NftGalleryStatus.loading;
    final canRescan = status == NftGalleryStatus.loaded ||
        status == NftGalleryStatus.empty ||
        status == NftGalleryStatus.nothingToQuery;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ZuniaCheckbox(
          value: prefs.nftMedia,
          onChanged: (value) =>
              ref.read(preferencesProvider.notifier).setNftMedia(value),
          label: 'Show artwork',
          description: 'Images load from each token\'s host.',
        ),
        // The empty state for "live reads off" already says so and offers
        // Settings; repeating it here would be the same sentence twice.
        if (mediaBlocked != null &&
            prefs.nftMedia &&
            status != NftGalleryStatus.readsDisabled) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  mediaBlocked,
                  style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgMuted),
                ),
              ),
              if (!prefs.liveReads) ...[
                const SizedBox(width: 8),
                ZuniaButton(
                  label: 'Open Settings',
                  size: ZuniaButtonSize.sm,
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: _openSettings,
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 10),

        if (showEmpty)
          _emptyState(state, chainName)
        else
          ZuniaNftGrid(
            items: items,
            loadMedia: mediaOn,
            loading: state.busy || status == NftGalleryStatus.idle,
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

        if (status == NftGalleryStatus.loaded || canRescan) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: status == NftGalleryStatus.loaded
                    ? Text(
                        _coverageLine(state),
                        style: zuniaMono(
                          fontSize: 10.5,
                          height: 1.5,
                          color: s.fgMuted,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (canRescan)
                // A scan is reused for hours; a collection minted since then
                // should not need the user to wait that out.
                ZuniaButton(
                  label: 'Scan again',
                  size: ZuniaButtonSize.sm,
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: () => _refresh(force: true),
                ),
            ],
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

        const SizedBox(height: 24),
        ZuniaSectionLabel('Add a collection', key: _addKey),
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
            label: 'Check',
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
      ],
    );
  }

  /// Icon, short title, at most one line, and the one action that helps.
  Widget _emptyState(NftGalleryState state, String chainName) {
    final (title, description, action) = switch (state.status) {
      NftGalleryStatus.unsupported => (
          '$chainName doesn\'t support NFTs',
          null,
          null,
        ),
      NftGalleryStatus.readsDisabled => (
          'Live reads are off',
          'Turn them on in Settings to load NFTs.',
          ZuniaButton(
            label: 'Open Settings',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: _openSettings,
          ),
        ),
      NftGalleryStatus.noAccount => (
          'No address on $chainName',
          'Enable the network first.',
          null,
        ),
      NftGalleryStatus.failed ||
      NftGalleryStatus.noEndpoint =>
        (
          'Couldn\'t reach $chainName',
          state.reason,
          ZuniaButton(
            label: 'Try again',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: _refresh,
          ),
        ),
      NftGalleryStatus.supportUnknown => (
          'Couldn\'t check $chainName',
          state.reason,
          ZuniaButton(
            label: 'Try again',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: _refresh,
          ),
        ),
      _ => (
          'No NFTs yet',
          'Collectibles you own on $chainName show up here.',
          ZuniaButton(
            label: 'Add a collection',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: _focusAdd,
          ),
        ),
    };
    return ZuniaEmptyState(
      title: title,
      description: description,
      action: action,
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

  /// One subtle line: how much was checked, and how to widen it.
  String _coverageLine(NftGalleryState state) {
    if (state.complete) return 'Indexed collections';
    final n = state.contractsQueried;
    final checked = '$n ${n == 1 ? 'collection' : 'collections'} checked';
    return state.limitation == null
        ? checked
        : '$checked \u00b7 Add a missing one below';
  }
}
