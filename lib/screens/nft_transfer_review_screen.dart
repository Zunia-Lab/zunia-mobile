/// Step two: what exactly is being signed.
///
/// A CW721 transfer reaches the chain as a `MsgExecuteContract`, which to a
/// naive wallet is an opaque blob and to a user is the words "Execute
/// contract". That is not informed consent, so this screen decodes the message
/// it is about to sign — including the doubly-base64'd ICS721 `IbcOutgoingMsg`
/// — with [inspectNftExecute] and states which collectible leaves, from which
/// collection, to whom. Anything it cannot account for blocks the signature
/// rather than being waved through, exactly as the swap review screen does with
/// an unreadable memo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/services/wallet_tx_service.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/transfer_sent_sheet.dart';
import 'package:zunia_ui/zunia_ui.dart';

class NftTransferReviewScreen extends ConsumerStatefulWidget {
  const NftTransferReviewScreen({
    super.key,
    required this.chainId,
    required this.collectionAddress,
    required this.tokenId,
    required this.recipient,
    this.collectionName,
    this.destChainId,
    this.bridgeContract,
    this.channelId,
  });

  final String chainId;
  final String collectionAddress;
  final String tokenId;
  final String recipient;
  final String? collectionName;

  /// Null for a same-chain `transfer_nft`.
  final String? destChainId;
  final String? bridgeContract;
  final String? channelId;

  bool get crossChain => destChainId != null && destChainId != chainId;

  @override
  ConsumerState<NftTransferReviewScreen> createState() =>
      _NftTransferReviewScreenState();
}

class _NftTransferReviewScreenState
    extends ConsumerState<NftTransferReviewScreen> {
  bool _signing = false;
  String? _error;
  bool _showRaw = false;

  NftTransferRequest _request(String sender) => NftTransferRequest(
        chainId: widget.chainId,
        collectionAddress: widget.collectionAddress,
        tokenId: widget.tokenId,
        sender: sender,
        recipient: widget.recipient,
        destChainId: widget.destChainId,
        channelId: widget.channelId,
        bridgeContract: widget.bridgeContract,
      );

  /// Build the execute message, or the reason it cannot be built.
  ///
  /// Every refusal here is one of the engine's, not this screen's: a chain
  /// without CosmWasm, an address on the wrong chain, an unconfigured bridge.
  ({NftExecute? execute, String? error}) _build({
    required ChainInfo chain,
    required ChainInfo? destChain,
    required String sender,
  }) {
    try {
      return (
        execute: buildNftTransferMsg(
          chain,
          _request(sender),
          destChain: destChain,
          // Only ever true after nftChainSupportProvider established CosmWasm,
          // which this screen checks before calling.
          allowUnknownFeatures: true,
        ),
        error: null,
      );
    } on InterchainError catch (error) {
      return (execute: null, error: error.message);
    }
  }

  Future<void> _signAndBroadcast(
    NftExecute reviewed,
    NftExecuteInspection inspection,
    ChainInfo chainInfo,
    ChainInfo? destChain,
    ChainAccount account,
  ) async {
    final phrase = ref.read(phraseProvider);
    final wallet = ref.read(walletProvider).active;
    final chain = account.chain;
    if (phrase == null || wallet == null) {
      setState(() => _error = 'Unlock the wallet to sign.');
      return;
    }

    setState(() {
      _signing = true;
      _error = null;
    });

    try {
      // Rebuilt rather than reused: an ICS721 timeout is relative to now, and a
      // message built when the screen opened would carry a deadline that has
      // been ticking down while it was read. Everything else must be identical
      // to what was reviewed, and the comparison below refuses to sign if it
      // is not.
      final rebuilt = _build(
        chain: chainInfo,
        destChain: destChain,
        sender: account.address,
      );
      final execute = rebuilt.execute;
      if (execute == null) {
        setState(() {
          _signing = false;
          _error = rebuilt.error ?? 'This transfer could not be rebuilt.';
        });
        return;
      }
      final recheck = inspectNftExecute(execute);
      if (!_sameIntent(inspection, recheck)) {
        setState(() {
          _signing = false;
          _error = 'The message changed between review and signing, so nothing '
              'was signed. Go back and start again.';
        });
        return;
      }

      final hash = await WalletTxService.instance.signAndBroadcast(
        phrase: phrase,
        chain: chain,
        signerAddress: account.address,
        accountIndex: wallet.index,
        msgs: [
          msgExecuteContract(
            sender: execute.sender,
            contract: execute.contract,
            msg: execute.msg,
          ),
        ],
      );
      if (!mounted) return;
      if (widget.crossChain) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => NftBridgeSentScreen(
              txHash: hash,
              sourceChainName: chain.chainName,
              destChainName: destChain?.chainName ?? widget.destChainId ?? '',
              bridgeContract: execute.contract,
              inspection: recheck,
            ),
          ),
        );
      } else {
        // The same confirmation the wallet already uses after a send, so a
        // collectible transfer ends where every other transfer ends.
        await showTransferSent(
          context,
          txHash: hash,
          title: 'Collectible sent',
        );
        if (mounted) Navigator.of(context).pop();
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _signing = false;
        _error = '$error';
      });
    }
  }

  /// True when two decodings describe the same movement.
  ///
  /// The ICS721 timeout is deliberately excluded: it is the one field that is
  /// meant to differ between the reviewed message and the signed one.
  bool _sameIntent(NftExecuteInspection a, NftExecuteInspection b) =>
      a.kind == b.kind &&
      a.collectionAddress == b.collectionAddress &&
      a.tokenId == b.tokenId &&
      a.recipient == b.recipient &&
      a.receivingContract == b.receivingContract &&
      a.channelId == b.channelId;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final registry = ref.watch(interchainRegistryProvider);
    final support = ref.watch(nftChainSupportProvider(widget.chainId));
    final chainInfo = registry.get(widget.chainId);
    final destChain = widget.destChainId == null
        ? null
        : registry.get(widget.destChainId!);
    ChainAccount? account;
    for (final row in ref.watch(chainAccountsProvider)) {
      if (row.chain.chainId == widget.chainId) account = row;
    }
    // The account's own catalog entry, not a fresh catalog lookup: this is the
    // entry the signing address was derived from, so the fee shown here and the
    // fee the tx layer pays come from the same row.
    final entry = account?.chain;

    if (chainInfo == null || entry == null || account == null) {
      return _shell(
        context,
        body: ZuniaEmptyState(
          title: 'This chain is not available',
          description: 'Zunia has no usable entry or address for '
              '${widget.chainId}, so it cannot build a transfer there.',
        ),
      );
    }

    // A chain whose CosmWasm support is unknown never gets a signature: the
    // execute would be built against a guess.
    final supportBlock = support.when(
      data: (value) => value.usable ? null : value.reason,
      loading: () => 'Checking whether ${chainInfo.chainName} runs CosmWasm…',
      error: (error, _) =>
          'Could not establish whether ${chainInfo.chainName} runs CosmWasm.',
    );

    final built = supportBlock != null
        ? (execute: null, error: null)
        : _build(
            chain: chainInfo,
            destChain: destChain,
            sender: account.address,
          );
    final execute = built.execute;
    final inspection = execute == null ? null : inspectNftExecute(
          execute,
          collectionName: widget.collectionName,
          destChainName: destChain?.chainName,
        );

    // Two independent gates. The first is "could we build it"; the second is
    // "can we say what it does". Both must pass.
    final unreadable = inspection == null || !inspection.readable;
    final expectedKind = widget.crossChain
        ? NftExecuteKind.ics721Transfer
        : NftExecuteKind.transferNft;
    final mismatched = inspection != null && inspection.kind != expectedKind;

    final fee = execute == null
        ? null
        : estimateFee(
            gasLimit: defaultGasFor([
              msgExecuteContract(
                sender: execute.sender,
                contract: execute.contract,
                msg: execute.msg,
              ),
            ]),
            gasPrice: entry.averageGasPrice,
            denom: entry.feeMinimalDenom.isEmpty
                ? entry.coinMinimalDenom
                : entry.feeMinimalDenom,
          );
    final feeLabel = fee == null || fee.amount.isEmpty
        ? null
        : '≈ ${formatBaseUnitsExact(
            fee.amount.first.amount,
            decimals: entry.feeDecimals,
            maxFractionDigits: 6,
          )} ${entry.feeDenom}';

    // A locked wallet cannot sign, so the button says so instead of failing
    // after the tap.
    final locked = ref.watch(phraseProvider) == null;

    final blocked = supportBlock ??
        built.error ??
        (locked ? 'Unlock the wallet to sign this transfer.' : null) ??
        (unreadable
            ? 'Zunia could not decode the message it would sign, so it will '
                'not sign it.'
            : mismatched
                ? 'The decoded message is not the transfer this screen '
                    'described, so nothing will be signed.'
                : null);

    return _shell(
      context,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        children: [
          const ZuniaSectionLabel('What this signs'),
          const SizedBox(height: 8),
          ZuniaCallout(
            tone: unreadable || mismatched
                ? ZuniaCalloutTone.danger
                : ZuniaCalloutTone.info,
            title: unreadable
                ? 'Zunia cannot read this message'
                : 'Decoded on device',
            body: inspection?.summary ??
                built.error ??
                supportBlock ??
                'The contract call could not be built, so nothing here can say '
                    'what it would do.',
          ),
          for (final warning in inspection?.warnings ?? const <String>[]) ...[
            const SizedBox(height: 8),
            ZuniaCallout(tone: ZuniaCalloutTone.warning, body: warning),
          ],

          const SizedBox(height: 18),
          const ZuniaSectionLabel('Message'),
          const SizedBox(height: 10),
          // ZuniaFeeSummary rather than key-value rows: its label column flexes,
          // and at 320dp a label plus a bech32 address does not fit on one line
          // without it.
          ZuniaFeeSummary(
            rows: [
              const ZuniaFeeRow(label: 'Type', value: 'MsgExecuteContract'),
              ZuniaFeeRow(label: 'Action', value: execute?.action),
              ZuniaFeeRow(
                label: 'Executed on',
                value: execute == null
                    ? null
                    : truncateAddress(execute.contract, left: 10),
                hint: 'the CW721 collection',
              ),
              ZuniaFeeRow(label: 'Token id', value: inspection?.tokenId),
              ZuniaFeeRow(
                label: widget.crossChain ? 'Receives voucher' : 'New owner',
                value: inspection?.recipient == null
                    ? null
                    : truncateAddress(inspection!.recipient!),
              ),
              if (widget.crossChain) ...[
                ZuniaFeeRow(
                  label: 'Bridge contract',
                  value: inspection?.receivingContract == null
                      ? null
                      : truncateAddress(
                          inspection!.receivingContract!,
                          left: 10,
                        ),
                  hint: 'holds the collectible while the voucher exists',
                ),
                ZuniaFeeRow(label: 'Channel', value: inspection?.channelId),
                ZuniaFeeRow(
                  label: 'Destination',
                  value: destChain?.chainName ?? widget.destChainId,
                ),
              ],
              ZuniaFeeRow(
                label: 'Network fee',
                value: feeLabel,
                hint: 'paid on ${chainInfo.chainName} only, at a gas limit of '
                    '$kNftTransferGasLimit',
                emphasise: true,
              ),
            ],
          ),

          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showRaw = !_showRaw),
              child: Text(
                _showRaw ? 'Hide the raw message' : 'Show the raw message',
                style: zuniaMono(fontSize: 11, color: s.info),
              ),
            ),
          ),
          if (_showRaw && execute != null) ...[
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: s.glass,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                execute.msgJson,
                style: zuniaMono(fontSize: 10, height: 1.5, color: s.fg),
              ),
            ),
            if (inspection?.innerMsg != null) ...[
              const SizedBox(height: 8),
              Text(
                'The base64 above decodes to:',
                style: zuniaMono(fontSize: 10, color: s.fgDim),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: s.glass,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  '${inspection!.innerMsg}',
                  style: zuniaMono(fontSize: 10, height: 1.5, color: s.fg),
                ),
              ),
            ],
          ],

          if (_error != null) ...[
            const SizedBox(height: 16),
            ZuniaCallout(
              tone: ZuniaCalloutTone.danger,
              title: 'Not broadcast',
              body: _error!,
            ),
          ],
        ],
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZuniaButton(
            label: 'Sign and broadcast',
            size: ZuniaButtonSize.lg,
            loading: _signing,
            onPressed: blocked != null || _signing || execute == null
                ? null
                : () => _signAndBroadcast(
                      execute,
                      inspection!,
                      chainInfo,
                      destChain,
                      account!,
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
          title: 'Review transfer',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '2 / 2',
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

/// What happened after an ICS721 send, and what the wallet cannot tell you.
///
/// Deliberately not the packet tracker. `tracking.dart` follows ICS20 transfer
/// packets — it parses `FungibleTokenPacketData` and matches on the `transfer`
/// port — and an ICS721 packet is neither: it carries
/// `NonFungibleTokenPacketData` on the bridge contract's own `wasm.<address>`
/// port. Pointing the tracker at it would produce a progress bar that means
/// nothing, so this screen says what is known and stops there.
class NftBridgeSentScreen extends StatelessWidget {
  const NftBridgeSentScreen({
    super.key,
    required this.txHash,
    required this.sourceChainName,
    required this.destChainName,
    required this.bridgeContract,
    required this.inspection,
  });

  final String txHash;
  final String sourceChainName;
  final String destChainName;
  final String bridgeContract;
  final NftExecuteInspection inspection;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Sent to the bridge',
          onBack: () => Navigator.of(context)
              .popUntil((route) => route.isFirst),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'Broadcast on $sourceChainName',
                body: 'The node accepted the transaction. Token '
                    '${inspection.tokenId ?? ''} was handed to the bridge '
                    'contract, which holds it while the voucher exists on '
                    '$destChainName.',
              ),
              const SizedBox(height: 14),
              const ZuniaSectionLabel('Transaction'),
              const SizedBox(height: 8),
              SelectableText(
                txHash,
                style: zuniaMono(fontSize: 11, height: 1.5, color: s.fg),
              ),
              const SizedBox(height: 6),
              Text(
                // Same rule as the packet status screen: no explorer is
                // configured, and a made-up domain is worse than no link.
                'Zunia has no explorer configured for these chains, so the '
                'hash is here to copy rather than to open.',
                style: zuniaSans(fontSize: 12, height: 1.5, color: s.fgMuted),
              ),
              const SizedBox(height: 18),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Zunia is not watching this packet',
                body: 'The wallet can follow ordinary IBC token transfers hop '
                    'by hop, but an ICS721 packet moves on the bridge '
                    'contract\'s own port with a different payload, and Zunia '
                    'has no reader for it yet. Check the destination chain for '
                    'the voucher rather than waiting here.',
              ),
              const SizedBox(height: 14),
              ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'Getting it back',
                body: 'Sending the voucher on $destChainName back over the '
                    'same channel burns it and releases the original from '
                    '${truncateAddress(bridgeContract, left: 10)} on '
                    '$sourceChainName.',
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Done',
            size: ZuniaButtonSize.lg,
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ),
      ),
    );
  }
}
