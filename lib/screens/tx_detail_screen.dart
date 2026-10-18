/// One transaction, read from its chain: what it did, what it cost, whether
/// the chain took it, and for an IBC transfer, where its packets went.
///
/// The fee is the one the transaction paid (`auth_info.fee`), the hash links
/// to the explorer the chain registry names, a refusal is put in plain words
/// with the chain's own text kept, and a swap's Zunia fee is its own line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
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
import 'package:zunia_mobile/widgets/chain_avatar.dart';
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

    final statusLabel = !success ? 'Failed' : (info == null ? 'Confirmed' : 'Success');
    final tone = success ? s.success : s.danger;

    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
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
              // Sections are inset on their own (iOS grouped rows); the rest
              // takes the same 16 pt margin through [_inset].
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 28),
              children: [
                // The headline: what happened, how much, whether it went through.
                _inset(Container(
                  padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: s.surfaceRaisedGradient,
                    border: Border.all(color: s.line),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: presentation.bg,
                          border: Border.all(color: presentation.border, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: presentation.fg.withValues(alpha: 0.25 * s.bloom),
                              blurRadius: 24,
                            ),
                          ],
                        ),
                        child: Text(
                          presentation.icon,
                          style: TextStyle(color: presentation.fg, fontSize: 26, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        item.title,
                        textAlign: TextAlign.center,
                        style: zuniaSans(fontSize: 17, fontWeight: FontWeight.w500, color: s.fgMuted),
                      ),
                      if (amount != null) ...[
                        const SizedBox(height: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            amount,
                            textAlign: TextAlign.center,
                            style: zuniaSans(
                              fontSize: 32,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -1,
                              color: zuniaActivityAmountColor(context, kind: kind, success: success, amount: amount),
                              tabular: const FontFeature.tabularFigures(),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _Chip(
                            color: tone,
                            fill: success ? s.successFill : s.dangerFill,
                            icon: success ? Icons.check_circle_rounded : Icons.error_rounded,
                            label: statusLabel,
                          ),
                          _Chip(
                            color: s.fgMuted,
                            fill: s.glass,
                            leading: chain == null ? null : ChainAvatar(chain: chain, size: 16),
                            label: chainName,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _dateLabel(when),
                        style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                      ),
                    ],
                  ),
                )),
                const SizedBox(height: 14),
                if (!success) ...[
                  _inset(ZuniaCallout(
                    tone: ZuniaCalloutTone.danger,
                    title: '$chainName did not accept it',
                    body: explainChainError(info?.error ?? 'The chain reports this transaction as failed.'),
                  )),
                  const SizedBox(height: 12),
                ],
                if (detail.isLoading && info == null) _inset(const _DetailSkeleton()),
                if (detail.hasError) ...[
                  _inset(ZuniaCallout(
                    tone: ZuniaCalloutTone.warning,
                    title: 'Details unavailable',
                    body: detail.error is ChainReadException
                        ? '$chainName did not answer. ${(detail.error! as ChainReadException).failure.message}'
                        : '$chainName did not answer. Pull to try again.',
                  )),
                  const SizedBox(height: 12),
                ],
                if (!detail.isLoading && !detail.hasError && info == null) ...[
                  _inset(const ZuniaCallout(
                    tone: ZuniaCalloutTone.info,
                    title: 'Not on this node',
                    body: 'The node does not have this transaction. Public nodes prune old ones, so it may '
                        'only be on a block explorer.',
                  )),
                  const SizedBox(height: 12),
                ],
                // Who sent to whom, one tap to copy each side.
                if ((item.from ?? '').isNotEmpty || (item.to ?? '').isNotEmpty) ...[
                  _inset(_Parties(from: item.from, to: item.to)),
                  const SizedBox(height: 14),
                ],
                ZuniaListSection(
                  header: 'Details',
                  children: [
                    ZuniaListTile(
                      title: 'Hash',
                      subtitle: truncateAddress(item.hash, left: 12, right: 10),
                      leading: Icons.tag_rounded,
                      trailing: Icon(Icons.copy_rounded, size: 18, color: s.fgMuted),
                      onTap: () => copyWithFeedback(context, item.hash, 'Transaction hash'),
                    ),
                    if (info?.height != null)
                      ZuniaListTile(title: 'Block', leading: Icons.view_in_ar_outlined, value: info!.height),
                    if (info != null)
                      ZuniaListTile(
                        title: 'Network fee',
                        leading: Icons.local_gas_station_outlined,
                        value: _feeText(info, hidden),
                      ),
                    for (final fee in info?.zuniaFees ?? const <DescribedMessage>[])
                      ZuniaListTile(
                        title: 'Zunia fee',
                        leading: Icons.percent_rounded,
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
                      ZuniaListTile(
                        title: 'Gas',
                        leading: Icons.speed_rounded,
                        subtitle: '${info!.gasUsed} used of ${info.gasWanted ?? '?'}',
                        trailing: _GasBar(used: info.gasUsed, wanted: info.gasWanted),
                      ),
                    if (info != null && info.memo.isNotEmpty)
                      ZuniaListTile(title: 'Memo', leading: Icons.notes_rounded, subtitle: info.memo),
                  ],
                ),
                if (info != null && info.messages.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ZuniaListSection(
                    header: info.messages.length == 1 ? 'Message' : '${info.messages.length} messages',
                    children: [
                      for (final message in info.messages)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                hidden && message.described.amount != null
                                    ? message.described.title
                                    : message.described.summary,
                                style: zuniaSans(fontSize: 14.5, height: 1.4, color: s.fg),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: s.glass2,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(message.type, style: zuniaMono(fontSize: 10.5, color: s.fgMuted)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                if (info != null && info.packets.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _inset(_IbcSteps(walkKey: key, sourceChainId: item.chainId, txHash: item.hash)),
                ],
              ],
            ),
          ),
          footer: Row(
            children: [
              if (url != null) ...[
                Expanded(
                  child: ZuniaButton(
                    label: 'Explorer',
                    variant: ZuniaButtonVariant.secondary,
                    leading: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => openExternal(context, url),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: ZuniaButton(
                  label: 'Share',
                  variant: ZuniaButtonVariant.secondary,
                  leading: Icon(ZuniaPlatform.isCupertino(context) ? Icons.ios_share_rounded : Icons.share_rounded),
                  onPressed: () => _share(context, url ?? item.hash),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _inset(Widget child) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child);

  static Future<void> _share(BuildContext context, String text) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
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

class _Chip extends StatelessWidget {
  const _Chip({required this.color, required this.fill, required this.label, this.icon, this.leading});

  final Color color;
  final Color fill;
  final String label;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 15, color: color),
            ?leading,
            const SizedBox(width: 6),
            Text(label, style: zuniaSans(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
          ],
        ),
      );
}

/// From and To, each a tappable block that copies the address.
class _Parties extends StatelessWidget {
  const _Parties({this.from, this.to});

  final String? from;
  final String? to;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    Widget side(String label, String? address) {
      final value = (address ?? '').isEmpty ? '—' : truncateAddress(address!, left: 8, right: 6);
      return Expanded(
        child: Material(
          color: s.glass,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: (address ?? '').isEmpty ? null : () => copyWithFeedback(context, address!, 'Address'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: zuniaMono(fontSize: 10.5, letterSpacing: 1.1, color: s.fgDim)),
                  const SizedBox(height: 6),
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: zuniaMono(fontSize: 12.5, color: s.fg)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        side('FROM', from),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.arrow_forward_rounded, size: 18, color: s.fgMuted),
        ),
        side('TO', to),
      ],
    );
  }
}

/// How much of the gas limit the transaction used.
class _GasBar extends StatelessWidget {
  const _GasBar({required this.used, this.wanted});

  final String? used;
  final String? wanted;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final u = double.tryParse(used ?? '');
    final w = double.tryParse(wanted ?? '');
    if (u == null || w == null || w <= 0) return const SizedBox.shrink();
    final ratio = (u / w).clamp(0.0, 1.0);
    return SizedBox(
      width: 56,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: ratio,
          minHeight: 6,
          backgroundColor: s.glass2,
          color: ratio > 0.95 ? s.warning : s.accent,
        ),
      ),
    );
  }
}
