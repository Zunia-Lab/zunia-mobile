import 'package:flutter/material.dart';
import 'package:zunia_mobile/activity/activity_model.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_ui/zunia_ui.dart';

ZuniaActivityKind zuniaActivityKind(ActivityKind kind) => switch (kind) {
      ActivityKind.sent => ZuniaActivityKind.sent,
      ActivityKind.received => ZuniaActivityKind.received,
      ActivityKind.ibc => ZuniaActivityKind.ibc,
      ActivityKind.swap => ZuniaActivityKind.swap,
      ActivityKind.staking => ZuniaActivityKind.staking,
      ActivityKind.claim => ZuniaActivityKind.claim,
      ActivityKind.governance => ZuniaActivityKind.governance,
      ActivityKind.other => ZuniaActivityKind.other,
    };

/// `14:05`, local time.
String clockLabel(DateTime when) {
  final local = when.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

final RegExp _addressWord = RegExp(r'\b[a-z][a-z0-9]*1[02-9ac-hj-np-z]{20,}\b');

/// A subtitle with long addresses shortened, so the time after it stays.
String shortSubtitle(String text) => text.replaceAllMapped(
      _addressWord,
      (m) => truncateAddress(m[0]!, left: 10, right: 6),
    );

/// One history row: what happened, where and when, and what moved.
class ActivityRow extends StatelessWidget {
  const ActivityRow({
    super.key,
    required this.item,
    required this.hidden,
    required this.onTap,
    this.showChain = true,
  });

  final ActivityItem item;
  final bool hidden;
  final VoidCallback onTap;
  final bool showChain;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final kind = zuniaActivityKind(item.kind);
    final presentation = zuniaActivityPresentation(context, kind: kind, success: item.success);
    final amount = activityAmountText(item, hidden: hidden);
    final color = zuniaActivityAmountColor(context, kind: kind, success: item.success, amount: amount);
    final chain = ChainCatalog.isLoaded ? ChainCatalog.instance.find(item.chainId) : null;
    final parts = [
      if (showChain) chain?.chainName ?? item.chainId,
      shortSubtitle(item.subtitle),
      clockLabel(item.timestamp),
    ].where((p) => p.isNotEmpty);
    return Semantics(
      button: true,
      label: [
        item.title,
        if (!item.success) 'failed',
        ?amount,
        ...parts,
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: presentation.border),
                  color: presentation.bg,
                ),
                child: Text(
                  presentation.icon,
                  style: TextStyle(color: presentation.fg, fontSize: 15, height: 1, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, height: 1.2, color: s.fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      parts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (amount != null)
                      Text(
                        amount,
                        maxLines: 2,
                        textAlign: TextAlign.end,
                        style: zuniaSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: color,
                          tabular: const FontFeature.tabularFigures(),
                        ),
                      ),
                    if (!item.success)
                      Text('failed', style: zuniaMono(fontSize: 10, color: s.danger))
                    else if (item.zuniaFee)
                      Text('Zunia fee', style: zuniaMono(fontSize: 10, color: s.fgDim)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
