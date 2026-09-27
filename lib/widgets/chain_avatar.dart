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
    final ticker = chain.coinDenom.isNotEmpty
        ? chain.coinDenom
        : chain.chainName;
    return ZuniaTokenLogo(
      symbol: ticker,
      iconUrl: chain.iconUrl,
      size: size,
      verified: chain.inCosmosRegistry,
      selected: selected,
    );
  }
}
