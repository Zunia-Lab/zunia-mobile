import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/add_chain_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Post-setup network management: one switch per chain, searchable across the
/// whole registry.
class NetworksScreen extends ConsumerStatefulWidget {
  const NetworksScreen({super.key});

  @override
  ConsumerState<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends ConsumerState<NetworksScreen> {
  final _search = TextEditingController();
  String _query = '';
  String _filter = 'mainnet';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final enabled = ref.watch(walletProvider).enabledChainIds.toSet();
    final rows = ChainCatalog.isLoaded
        ? ChainCatalog.instance.search(_query, filter: _filter)
        : const <ChainEntry>[];

    return Scaffold(
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Networks',
          onBack: () => Navigator.of(context).pop(),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified, size: 14, color: const Color(0xFFF2913B)),
              const SizedBox(width: 6),
              Text(
                'registry verified',
                style: zuniaMono(fontSize: 10, color: s.fgDim),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
                child: Column(
                  children: [
                    ZuniaSearchField(
                      controller: _search,
                      hintText: 'Search ${rows.length}+ chains',
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 13),
                    ZuniaSegmented<String>(
                      value: _filter,
                      onChanged: (v) => setState(() => _filter = v),
                      options: const {
                        'mainnet': 'Mainnet',
                        'testnet': 'Testnet',
                        'all': 'All',
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                  itemCount: rows.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    if (i == rows.length) {
                      return _AddChainTile(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AddChainScreen(),
                          ),
                        ),
                      );
                    }
                    final chain = rows[i];
                    return ZuniaNetworkOptionCard(
                      name: chain.chainName,
                      chainId: chain.chainId,
                      symbol:
                          chain.coinDenom.isEmpty ? null : chain.coinDenom,
                      iconUrl: chain.iconUrl,
                      testnet: chain.isTestnet,
                      control: ZuniaNetworkControl.toggle,
                      selected: enabled.contains(chain.chainId),
                      onToggle: () => ref
                          .read(walletProvider.notifier)
                          .toggleChain(chain.chainId),
                    );
                  },
                ),
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Done',
            size: ZuniaButtonSize.lg,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}

class _AddChainTile extends StatelessWidget {
  const _AddChainTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: s.lineStrong, radius: 14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: s.lineStrong),
                ),
                child: Icon(Icons.add, size: 18, color: s.fgMuted),
              ),
              const SizedBox(width: 12),
              Text(
                'Add chain manually',
                style: zuniaMono(fontSize: 12, color: s.fgMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ),
      );
    final metrics = path.computeMetrics();
    const dash = 4.0;
    const gap = 3.0;
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
