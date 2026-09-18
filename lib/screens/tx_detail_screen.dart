import 'package:flutter/material.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Transaction detail for one activity row.
class TxDetailScreen extends StatelessWidget {
  const TxDetailScreen({super.key, required this.item});

  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Transaction',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: s.glass,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ZuniaTxDetail(
                    hash: item.hash,
                    status: item.success ? 'success' : 'failed',
                    chainLabel: item.chainId,
                    messages: [
                      (type: item.kind.name, summary: '${item.title} · ${item.subtitle}'),
                    ],
                    fees: const [(label: 'Fee', value: '—')],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
