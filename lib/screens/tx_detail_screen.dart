/// One transaction, read from its chain: what it did, what it cost, whether
/// the chain took it, and for an IBC transfer, where its packets went.
///
/// The fee is the one the transaction paid (`auth_info.fee`), the hash links
/// to the explorer the chain registry names, a refusal is put in plain words
/// with the chain's own text kept, and a swap's Zunia fee is its own line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/activity/bundled_links.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/packet_status_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/transfers/packet_walk.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/widgets/activity_row.dart';
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// `chainId|hash` → the transaction as the chain reports it.
final txDetailProvider = FutureProvider.autoDispose.family<TxDetailInfo?, String>((ref, key) async {
  final split = key.indexOf('|');
  final chainId = key.substring(0, split);
  final hash = key.substring(split + 1);
  final chain = ChainCatalog.instance.find(chainId);
  if (chain == null) return null;
  await loadBundledLinks();
  final address = ref.watch(chainAccountsProvider).where((a) => a.chain.chainId == chainId).firstOrNull?.address ?? '';
  return ref.watch(chainClientProvider).txDetail(chain, hash, address, feeRecipients: swapFeeRecipients);
});

/// `chainId|hash` → where the transaction's packets went.
final packetWalkProvider = FutureProvider.autoDispose.family<PacketWalk?, String>((ref, key) async {
  final detail = await ref.watch(txDetailProvider(key).future);
  if (detail == null || detail.packets.isEmpty) return null;
  return walkSentPackets(
    chainId: detail.chainId,
    txHash: detail.hash,
    packets: detail.packets,
    channels: ref.watch(channelServiceProvider),
    resolve: ref.watch(lcdResolverProvider),
  );
});

class TxDetailScreen extends ConsumerWidget {
  const TxDetailScreen({super.key, required this.item});

  final ActivityItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final hidden = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final key = '${item.chainId}|${item.hash}';
    final detail = ref.watch(txDetailProvider(key));
    final chain = ChainCatalog.isLoaded ? ChainCatalog.instance.find(item.chainId) : null;
    final chainName = chain?.chainName ?? item.chainId;
    final info = detail.valueOrNull;
    final success = info?.success ?? item.success;
    final url = explorerTxUrl(item.chainId, item.hash);
    final amount = activityAmountText(item, variant: TokenAmountVariant.confirm, hidden: hidden);
    final kind = zuniaActivityKind(item.kind);
    final presentation = zuniaActivityPresentation(context, kind: kind, success: success);
    final when = info?.timestamp ?? item.timestamp;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Transaction',
          onBack: () => Navigator.of(context).pop(),
          body: RefreshIndicator.adaptive(
            onRefresh: () async {
              ref.invalidate(txDetailProvider(key));
              ref.invalidate(packetWalkProvider(key));
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: presentation.bg,
                      border: Border.all(color: presentation.border),
                    ),
                    child: Text(presentation.icon,
                        style: TextStyle(color: presentation.fg, fontSize: 24, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(item.title,
                    textAlign: TextAlign.center,
                    style: zuniaSans(fontSize: 18, fontWeight: FontWeight.w500, color: s.fg)),
                if (amount != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    amount,
                    textAlign: TextAlign.center,
                    style: zuniaSans(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.6,
                      color: zuniaActivityAmountColor(context, kind: kind, success: success, amount: amount),
                      tabular: const FontFeature.tabularFigures(),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '$chainName · ${_dateLabel(when)}',
                  textAlign: TextAlign.center,
                  style: zuniaMono(fontSize: 11, color: s.fgMuted),
                ),
                const SizedBox(height: 16),
                if (!success)
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.danger,
                    title: '$chainName did not accept it',
                    body: explainChainError(info?.error ?? 'The chain reports this transaction as failed.'),
                  ),
                if (detail.isLoading && info == null) const _DetailSkeleton(),
                if (detail.hasError)
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.warning,
                    title: 'Details unavailable',
                    body: detail.error is ChainReadException
                        ? '$chainName did not answer. ${(detail.error! as ChainReadException).failure.message}'
                        : '$chainName did not answer. Pull to try again.',
                  ),
                if (!detail.isLoading && !detail.hasError && info == null)
                  ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    title: 'Not on this node',
                    body: 'The node does not have this transaction. Public nodes prune old ones, so it may '
                        'only be on a block explorer.',
                  ),
                const SizedBox(height: 8),
                ZuniaListSection(
                  children: [
                    ZuniaListTile(
                      title: 'Status',
                      value: success ? (info == null ? 'Confirmed' : 'Success') : 'Failed',
                    ),
                    ZuniaListTile(title: 'Network', value: chainName),
                    ZuniaListTile(
                      title: 'Hash',
                      subtitle: truncateAddress(item.hash, left: 10, right: 10),
                      trailing: Icon(Icons.copy_rounded, size: 18, color: s.accent),
                      onTap: () => copyWithFeedback(context, item.hash, 'Transaction hash'),
                    ),
                    if (info?.height != null) ZuniaListTile(title: 'Block', value: info!.height),
                    if (info != null) ZuniaListTile(title: 'Fee', value: _feeText(info, hidden)),
                    for (final fee in info?.zuniaFees ?? const <DescribedMessage>[])
                      ZuniaListTile(
                        title: 'Zunia fee',
                        value: hidden
                            ? maskedAmount
                            : formatTokenAmount(
                                (fee.amount ?? '0').replaceFirst('-', ''),
                                AmountScale(
                                  decimals: fee.decimals,
                                  decimalsKnown: fee.decimalsKnown,
                                  ticker: fee.symbol,
                                  denom: fee.denom ?? '',
                                  unknown: fee.unknownCoin,
                                ),
                                TokenAmountVariant.confirm,
                                unit: true,
                              ),
                      ),
                    if (info?.gasUsed != null)
                      ZuniaListTile(title: 'Gas', value: '${info!.gasUsed} of ${info.gasWanted ?? '?'}'),
                    if (info != null && info.memo.isNotEmpty) ZuniaListTile(title: 'Memo', subtitle: info.memo),
                    if (item.from != null && item.from!.isNotEmpty)
                      ZuniaListTile(
                        title: 'From',
                        subtitle: truncateAddress(item.from!, left: 12, right: 8),
                        onTap: () => copyWithFeedback(context, item.from!, 'Address'),
                      ),
                    if (item.to != null && item.to!.isNotEmpty)
                      ZuniaListTile(
                        title: 'To',
                        subtitle: truncateAddress(item.to!, left: 12, right: 8),
                        onTap: () => copyWithFeedback(context, item.to!, 'Address'),
                      ),
                  ],
                ),
                if (info != null && info.messages.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const ZuniaSectionLabel('Messages'),
                  const SizedBox(height: 6),
                  for (final message in info.messages)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: s.glass2,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(message.type, style: zuniaMono(fontSize: 10, color: s.fgMuted)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              hidden && message.described.amount != null ? message.described.title : message.described.summary,
                              style: zuniaSans(fontSize: 13, height: 1.4, color: s.fg),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (info != null && info.packets.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _IbcSteps(walkKey: key, sourceChainId: item.chainId, txHash: item.hash),
                ],
              ],
            ),
          ),
          footer: url == null
              ? null
              : ZuniaButton(
                  label: 'View on explorer',
                  variant: ZuniaButtonVariant.secondary,
                  leading: const Icon(Icons.open_in_new_rounded),
                  onPressed: () => openExternal(context, url),
                ),
        ),
      ),
    );
  }

  static String _feeText(TxDetailInfo info, bool hidden) {
    if (hidden) return maskedAmount;
    if (info.fee.isEmpty) return 'No fee';
    return info.fee
        .map((coin) => formatTokenAmount(coin.amount, coin.scale, TokenAmountVariant.confirm, unit: true))
        .join(' + ');
  }

  static String _dateLabel(DateTime when) {
    if (when.millisecondsSinceEpoch == 0) return 'undated';
    final local = when.toLocal();
    final date = '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return '$date ${clockLabel(local)}';
  }
}

class _IbcSteps extends ConsumerWidget {
  const _IbcSteps({required this.walkKey, required this.sourceChainId, required this.txHash});

  final String walkKey;
  final String sourceChainId;
  final String txHash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walk = ref.watch(packetWalkProvider(walkKey));
    final registry = ref.read(interchainRegistryProvider);
    final value = walk.valueOrNull;
    return ZuniaPacketTracker(
      title: 'IBC steps',
      hops: [
        for (final hop in value?.hops ?? const <WalkedHop>[])
          ZuniaPacketTrackerHop(
            chainId: hop.chainId,
            chainName: registry.get(hop.chainId)?.chainName,
            counterpartyChainId: hop.counterpartyChainId,
            counterpartyChainName:
                hop.counterpartyChainId == null ? null : registry.get(hop.counterpartyChainId!)?.chainName,
            channelId: hop.channelId,
            port: hop.port,
            sequence: hop.sequence,
            sendTxHash: hop.sendTxHash,
            receiveTxHash: hop.receiveTxHash,
            error: hop.error,
            status: switch (hop.status) {
              PacketStatus.pending => ZuniaPacketHopStatus.pending,
              PacketStatus.relayed => ZuniaPacketHopStatus.relayed,
              PacketStatus.received => ZuniaPacketHopStatus.received,
              PacketStatus.acknowledged => ZuniaPacketHopStatus.acknowledged,
              PacketStatus.timeout => ZuniaPacketHopStatus.timeout,
              PacketStatus.failed => ZuniaPacketHopStatus.failed,
              PacketStatus.unknown => ZuniaPacketHopStatus.unknown,
            },
          ),
      ],
      sourceTxHash: txHash,
      sourceChainId: sourceChainId,
      failure: trackerFailure(value?.failure),
      txUrl: explorerTxUrl,
      onOpenTx: (url) => openExternal(context, url),
      onCopyTxHash: (hash) => copyWithFeedback(context, hash, 'Transaction hash'),
      loading: walk.isLoading,
      error: walk.hasError
          ? (walk.error is InterchainError && (walk.error! as InterchainError).code == InterchainErrorCode.readsDisabled
              ? 'Live reads are off, so the packets cannot be followed.'
              : 'Could not read where the packets went.')
          : null,
      onRefresh: () => ref.invalidate(packetWalkProvider(walkKey)),
      compact: MediaQuery.sizeOf(context).width < 360,
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ZuniaSkeleton(height: 14),
            SizedBox(height: 10),
            ZuniaSkeleton(height: 14),
            SizedBox(height: 10),
            ZuniaSkeleton(height: 14),
          ],
        ),
      );
}
