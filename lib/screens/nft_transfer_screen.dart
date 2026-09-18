/// Step one of moving a collectible: where it is going.
///
/// Same-chain is a CW721 `transfer_nft`. Cross-chain is ICS721: a `send_nft`
/// that hands the token to a bridge contract, which escrows it and asks the
/// destination to mint a voucher. The two are different enough that the
/// difference is stated on this screen and again on the review screen, before
/// anything is signed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/nft_transfer_review_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/widgets/address_field_actions.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_ui/zunia_ui.dart';

class NftTransferScreen extends ConsumerStatefulWidget {
  const NftTransferScreen({
    super.key,
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
    required this.crossChain,
    this.collectionName,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;

  /// True for ICS721. Chosen on the detail screen, not toggled here, so the
  /// warning copy on both screens always matches the message being built.
  final bool crossChain;

  final String? collectionName;

  @override
  ConsumerState<NftTransferScreen> createState() => _NftTransferScreenState();
}

class _NftTransferScreenState extends ConsumerState<NftTransferScreen> {
  final _recipient = TextEditingController();
  String? _destChainId;

  @override
  void dispose() {
    _recipient.dispose();
    super.dispose();
  }

  /// An enabled account's own entry first, then the catalog.
  ///
  /// A destination the wallet has no address on is still a valid ICS721
  /// destination — the recipient is typed by hand — so the catalog is the
  /// fallback rather than the only source.
  ChainEntry? _entryFor(List<ChainAccount> accounts, String chainId) {
    for (final account in accounts) {
      if (account.chain.chainId == chainId) return account.chain;
    }
    return ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(
          title: 'Scan address',
          extractAddress: true,
        ),
      ),
    );
    if (!mounted || raw == null) return;
    setState(() => _recipient.text = extractBech32Address(raw) ?? raw);
  }

  /// Filtered to the destination's prefix, which for a cross-chain send is the
  /// other chain: a contact on the source chain is the wrong answer here.
  Future<void> _pickBook(String? prefix) async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AddressBookScreen(pickMode: true, prefixFilter: prefix),
      ),
    );
    if (!mounted || address == null) return;
    setState(() => _recipient.text = address);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);
    final source = accounts
        .where((a) => a.chain.chainId == widget.chainId)
        .firstOrNull;

    if (source == null) {
      return _shell(
        context,
        body: ZuniaEmptyState(
          title: 'No address on this chain',
          description: 'This wallet has no address on ${widget.chainId}, so it '
              'cannot sign a transfer there.',
        ),
      );
    }

    // Only chains this build has an ICS721 channel for. Anything else would be
    // a destination the wallet cannot actually reach.
    final destinations = widget.crossChain
        ? [
            for (final chainId in ics721DestinationsFrom(widget.chainId))
              _entryFor(accounts, chainId),
          ].whereType<ChainEntry>().toList()
        : const <ChainEntry>[];

    final destChainId = widget.crossChain
        ? (destinations.any((c) => c.chainId == _destChainId)
            ? _destChainId!
            : (destinations.isEmpty ? null : destinations.first.chainId))
        : widget.chainId;
    final destChain = destChainId == null
        ? null
        : destinations
                .where((c) => c.chainId == destChainId)
                .firstOrNull ??
            (destChainId == widget.chainId ? source.chain : null);

    final route = widget.crossChain && destChainId != null
        ? ics721RouteFor(
            sourceChainId: widget.chainId,
            destChainId: destChainId,
            sourceChainName: source.chain.chainName,
            destChainName: destChain?.chainName,
          )
        : null;

    final recipient = _recipient.text.trim();
    final expectedPrefix = destChain?.bech32Prefix;
    final String? recipientError;
    if (recipient.isEmpty) {
      recipientError = null;
    } else if (expectedPrefix == null) {
      recipientError = null;
    } else if (!addressHasPrefix(recipient, expectedPrefix)) {
      // The prefix is checked against the *destination*, which for ICS721 is
      // the other chain. Sending to a well-formed address on the wrong chain
      // loses the token and the mistake is invisible on review.
      recipientError =
          'Not an address on ${destChain!.chainName}: it must start with '
          '"${expectedPrefix}1". A collectible sent to an address on the wrong '
          'chain cannot be recovered.';
    } else if (!widget.crossChain && recipient == source.address) {
      recipientError = 'That is this wallet\'s own address on this chain.';
    } else {
      recipientError = null;
    }

    final blocked = widget.crossChain && destinations.isEmpty
        ? 'This build has no ICS721 channel out of ${source.chain.chainName}.'
        : route != null && !route.ready
            ? route.reason
            : recipient.isEmpty
                ? 'Enter the address that should receive this collectible.'
                // Not the field's own message repeated: it is already on
                // screen next to the input, and saying it twice reads as two
                // separate problems.
                : recipientError == null
                    ? null
                    : 'Fix the recipient address above.';

    return _shell(
      context,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        children: [
          ZuniaCard(
            tone: ZuniaCardTone.glass,
            padding: const EdgeInsets.all(14),
            radius: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SENDING',
                  style: zuniaMono(
                    fontSize: 9.5,
                    letterSpacing: 1.3,
                    color: s.fgDim,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  zuniaNftTitle(widget.tokenId, widget.collectionName),
                  style: zuniaSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: s.fg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${truncateAddress(widget.collectionAddress, left: 10)} · '
                  'token ${widget.tokenId}',
                  style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (widget.crossChain) ...[
            Text(
              'To network',
              style: zuniaMono(fontSize: 10, color: s.fgDim),
            ),
            const SizedBox(height: 8),
            if (destinations.isEmpty)
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'No ICS721 route configured',
                body: 'ICS721 runs on its own port, so an ordinary IBC '
                    'transfer channel cannot be reused for a collectible and '
                    'Zunia will not substitute one.',
              )
            else
              ChainPicker(
                value: destChainId!,
                chains: destinations,
                onChanged: (value) => setState(() => _destChainId = value),
              ),
            const SizedBox(height: 14),
            const ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: 'The other chain mints a voucher',
              body: ics721VoucherWarning,
            ),
            if (route != null && route.ready) ...[
              const SizedBox(height: 12),
              ZuniaFeeSummary(
                rows: [
                  ZuniaFeeRow(
                    label: 'Bridge contract',
                    value: truncateAddress(route.bridgeContract!, left: 10),
                    hint: 'takes custody of the collectible on '
                        '${source.chain.chainName}',
                  ),
                  ZuniaFeeRow(label: 'Channel', value: route.channelId),
                ],
              ),
            ],
            if (route != null && !route.ready) ...[
              const SizedBox(height: 12),
              ZuniaCallout(
                tone: ZuniaCalloutTone.danger,
                title: 'Cross-chain send is off',
                body: route.reason!,
              ),
            ],
            const SizedBox(height: 16),
          ],

          ZuniaInput(
            controller: _recipient,
            label: 'RECIPIENT ADDRESS',
            hint: expectedPrefix == null ? 'address' : '${expectedPrefix}1…',
            errorText: recipientError,
            onChanged: (_) => setState(() {}),
            trailing: AddressFieldActions(
              onScan: () => _scanQr(),
              onBook: () => _pickBook(expectedPrefix),
            ),
          ),
          const SizedBox(height: 14),
          ZuniaCallout(
            tone: ZuniaCalloutTone.info,
            title: widget.crossChain ? 'One signature, here' : 'One signature',
            body: widget.crossChain
                ? 'You sign a single contract call on '
                    '${source.chain.chainName} and pay its fee in '
                    '${source.chain.feeDenom}. The bridge does the rest inside '
                    'packet processing.'
                : 'You sign a single contract call on '
                    '${source.chain.chainName} and pay its fee in '
                    '${source.chain.feeDenom}. The transfer is final once it '
                    'is included.',
          ),
        ],
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZuniaButton(
            label: 'Review transfer',
            size: ZuniaButtonSize.lg,
            onPressed: blocked != null || destChainId == null
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => NftTransferReviewScreen(
                          chainId: widget.chainId,
                          collectionAddress: widget.collectionAddress,
                          tokenId: widget.tokenId,
                          collectionName: widget.collectionName,
                          recipient: recipient,
                          destChainId:
                              widget.crossChain ? destChainId : null,
                          bridgeContract: route?.bridgeContract,
                          channelId: route?.channelId,
                        ),
                      ),
                    ),
          ),
          if (blocked != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                blocked,
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shell(BuildContext context, {required Widget body, Widget? footer}) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: widget.crossChain ? 'Send to another chain' : 'Transfer',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '1 / 2',
            style: zuniaMono(
              fontSize: 11,
              color: ZuniaSemanticsExt.of(context).fgDim,
            ),
          ),
          body: body,
          footer: footer,
        ),
      ),
    );
  }
}
