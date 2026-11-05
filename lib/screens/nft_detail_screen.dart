/// One token: what it is, who holds it, where its artwork would come from, and
/// the two ways it can leave.
///
/// Both actions are disabled with their own sentence whenever the whole path
/// behind them does not work — a chain without CosmWasm, a token this wallet
/// does not own, a locked wallet, or an ICS721 bridge this build was not
/// configured with.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/nft_transfer_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

class NftDetailScreen extends ConsumerWidget {
  const NftDetailScreen({
    super.key,
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;

  NftTokenRef get _ref => NftTokenRef(
        chainId: chainId,
        collectionAddress: collectionAddress,
        tokenId: tokenId,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(nftTokenDetailProvider(_ref));
    final prefs = ref.watch(preferencesProvider);
    final mediaOn = prefs.liveReads && prefs.nftMedia;

    ChainAccount? account;
    for (final row in ref.watch(chainAccountsProvider)) {
      if (row.chain.chainId == chainId) account = row;
    }

    final value = detail.valueOrNull;
    final token = value?.token;
    final item = ZuniaNftCardItem(
      tokenId: tokenId,
      name: token?.name,
      collectionAddress: collectionAddress,
      collectionName: value?.collection?.name,
      chainId: chainId,
      imageUrl: mediaOn ? value?.imageUrl : null,
    );

    final owner = token?.owner;
    final isMine = owner != null && account != null && owner == account.address;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Collectible',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaNftDetail(
                item: item,
                description: token?.description,
                owner: owner,
                traits: [
                  for (final trait in token?.attributes ?? const [])
                    ZuniaNftTrait(
                      traitType: trait.traitType,
                      value: trait.value,
                      displayType: trait.displayType,
                    ),
                ],
                loadMedia: mediaOn,
                // Only offered when turning it on would actually fetch
                // something. With live reads off the button would do nothing,
                // and the callout below says so instead.
                onRequestMedia: prefs.liveReads && !prefs.nftMedia
                    ? () =>
                        ref.read(preferencesProvider.notifier).setNftMedia(true)
                    : null,
                tokenUri: token?.tokenUri,
                loading: detail.isLoading,
                error: detail.hasError ? _errorText(detail.error) : null,
              ),

              if (value?.imageReason != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _Note(value!.imageReason!)),
                    if (!prefs.liveReads) ...[
                      const SizedBox(width: 8),
                      ZuniaButton(
                        label: 'Open Settings',
                        size: ZuniaButtonSize.sm,
                        variant: ZuniaButtonVariant.secondary,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              if (value?.metadataReason != null) ...[
                const SizedBox(height: 8),
                _Note(value!.metadataReason!),
              ],
              if (value?.metadataSource == NftMetadataSource.remote) ...[
                const SizedBox(height: 8),
                const _Note('Some details come from the token\'s host.'),
              ],

              const SizedBox(height: 20),
              const ZuniaSectionLabel('On chain'),
              const SizedBox(height: 10),
              ZuniaFeeSummary(
                rows: [
                  ZuniaFeeRow(label: 'Network', value: chainId),
                  ZuniaFeeRow(
                    label: 'Collection',
                    value: truncateAddress(collectionAddress, left: 12),
                    hint: value?.collection?.symbol,
                  ),
                  ZuniaFeeRow(label: 'Token id', value: tokenId),
                  ZuniaFeeRow(
                    label: 'Owner',
                    // Null renders as "not available": an owner nobody read is
                    // not the same as this wallet.
                    value: owner == null
                        ? null
                        : '${truncateAddress(owner)}${isMine ? ' · you' : ''}',
                  ),
                  ZuniaFeeRow(
                    label: 'Tokens in collection',
                    value: value?.collection?.tokenCount?.toString(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _CopyRow(label: 'Collection address', value: collectionAddress),
              const SizedBox(height: 6),
              _CopyRow(label: 'Token id', value: tokenId),

              const SizedBox(height: 22),
              const ZuniaSectionLabel('Move this collectible'),
              const SizedBox(height: 10),
              _Actions(
                chainId: chainId,
                collectionAddress: collectionAddress,
                tokenId: tokenId,
                token: token,
                account: account,
                isMine: isMine,
                ownerKnown: owner != null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _errorText(Object? error) => error is InterchainError
      ? error.message
      : 'This token could not be read: $error';
}

/// Transfer and cross-chain transfer, each with the reason it is off.
class _Actions extends ConsumerWidget {
  const _Actions({
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
    required this.token,
    required this.account,
    required this.isMine,
    required this.ownerKnown,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;
  final NftToken? token;
  final ChainAccount? account;
  final bool isMine;
  final bool ownerKnown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final unlocked = ref.watch(phraseProvider) != null;
    final destinations = ics721DestinationsFrom(chainId);

    String? blocked;
    if (account == null) {
      blocked = 'No address on $chainId.';
    } else if (!unlocked) {
      blocked = 'Unlock the wallet to transfer.';
    } else if (!ownerKnown) {
      blocked = 'Owner unknown, so transfer is unavailable.';
    } else if (!isMine) {
      blocked = 'Held by another address.';
    }

    final crossBlocked = blocked ??
        (destinations.isEmpty
            ? 'No cross-chain route from $chainId yet.'
            : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Short labels on purpose: at 320dp a ZuniaButton's label row has
        // 240dp of usable width and does not ellipsise.
        ZuniaButton(
          label: 'Transfer here',
          size: ZuniaButtonSize.lg,
          onPressed: blocked != null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NftTransferScreen(
                        chainId: chainId,
                        collectionAddress: collectionAddress,
                        tokenId: tokenId,
                        collectionName: token?.name,
                        crossChain: false,
                      ),
                    ),
                  ),
        ),
        const SizedBox(height: 10),
        ZuniaButton(
          label: 'Send cross-chain',
          size: ZuniaButtonSize.lg,
          variant: ZuniaButtonVariant.secondary,
          onPressed: crossBlocked != null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NftTransferScreen(
                        chainId: chainId,
                        collectionAddress: collectionAddress,
                        tokenId: tokenId,
                        collectionName: token?.name,
                        crossChain: true,
                      ),
                    ),
                  ),
        ),
        if (blocked != null || crossBlocked != null) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              blocked ?? crossBlocked!,
              style: zuniaMono(fontSize: 10.5, height: 1.5, color: s.fgMuted),
            ),
          ),
        ],
      ],
    );
  }
}

/// A selectable identifier with a copy affordance.
class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: zuniaMono(
                  fontSize: 9.5,
                  letterSpacing: 1.3,
                  color: s.fgDim,
                ),
              ),
              const SizedBox(height: 3),
              SelectableText(
                value,
                style: zuniaMono(fontSize: 10.5, height: 1.5, color: s.fgMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          button: true,
          label: 'Copy $label',
          child: IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_all_outlined, size: 16, color: s.fgMuted),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text('$label copied')),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One quiet line under the artwork: a reason, not an alert.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Text(
      text,
      style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgMuted),
    );
  }
}
