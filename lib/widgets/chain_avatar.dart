import 'package:flutter/material.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Registry logo for a chain, falling back to its ticker when the icon is
/// missing or the device is offline.
class ChainAvatar extends StatelessWidget {
  const ChainAvatar({
    super.key,
    required this.chain,
    this.size = 32,
    this.selected = false,
  });

  final ChainEntry chain;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final ticker = chain.coinDenom.isNotEmpty
        ? chain.coinDenom
        : chain.chainName;
    final fallback = Text(
      ticker.length >= 3
          ? ticker.substring(0, 3).toUpperCase()
          : ticker.toUpperCase(),
      style: zuniaMono(fontSize: size * 0.28, color: s.fgMuted),
    );

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: s.stateHover,
        border: selected
            ? Border.all(color: s.accent, width: 1.5)
            : null,
      ),
      child: chain.iconUrl == null
          ? fallback
          : Image.network(
              chain.iconUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
