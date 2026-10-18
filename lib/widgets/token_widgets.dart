/// How a token is drawn wherever it appears: its logo with the chain it sits
/// on as a badge, its ticker with the issuer suffix muted, and a skeleton row.
///
/// Everything comes from the token's identity; no widget here turns a denom
/// into text on its own. A seal is drawn only for a proven identity, and a
/// chain logo is never used as a token's logo.
library;

import 'package:flutter/material.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// The token's logo, with the holding chain's logo as a badge when the token
/// is not that chain's own (USDC.n on Osmosis wears an Osmosis badge).
class TokenAvatar extends StatelessWidget {
  const TokenAvatar({
    super.key,
    required this.identity,
    this.size = 36,
    this.showLocation = true,
  });

  final TokenIdentity identity;
  final double size;

  /// False under a header that already names the chain.
  final bool showLocation;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final held = ChainCatalog.isLoaded ? ChainCatalog.instance.find(identity.heldOnChainId) : null;
    final badge = showLocation &&
        held != null &&
        identity.originChainId != identity.heldOnChainId &&
        identity.kind != TokenKind.native;
    final logo = ZuniaTokenLogo(
      symbol: identity.family.isEmpty ? identity.ticker : identity.family,
      iconUrl: identity.logoUrl,
      size: size,
      verified: identity.proven && !badge,
    );
    if (!badge) return ExcludeSemantics(child: logo);
    final badgeSize = size * 0.46;
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            logo,
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(color: s.surface, shape: BoxShape.circle),
                child: ZuniaTokenLogo(
                  symbol: held.chainName,
                  iconUrl: held.iconUrl,
                  size: badgeSize,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A ticker with its issuer suffix muted: `USDC` then `.n`, `IBC` then `·498A`.
/// The suffix is never cut: when the line is too narrow the family gives way.
class TokenTicker extends StatelessWidget {
  const TokenTicker({
    super.key,
    required this.ticker,
    required this.family,
    this.style,
  });

  TokenTicker.of(TokenIdentity identity, {Key? key, TextStyle? style})
      : this(key: key, ticker: identity.ticker, family: identity.family, style: style);

  final String ticker;
  final String family;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final base = style ??
        zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, letterSpacing: -0.2, color: s.fg);
    final split = family.isNotEmpty && ticker.startsWith(family) && ticker.length > family.length
        ? family.length
        : _splitAt(ticker);
    final head = ticker.substring(0, split);
    final tail = ticker.substring(split);
    return Semantics(
      label: ticker,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(head, maxLines: 1, overflow: TextOverflow.ellipsis, style: base),
          ),
          if (tail.isNotEmpty)
            Text(tail, maxLines: 1, style: base.copyWith(color: s.fgMuted)),
        ],
      ),
    );
  }

  static int _splitAt(String ticker) {
    final dot = ticker.indexOf(RegExp('[.·]'));
    return dot <= 0 ? ticker.length : dot;
  }
}

/// A placeholder row while balances load: never a spinner for a list.
class AssetRowSkeleton extends StatelessWidget {
  const AssetRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: s.stateHover, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ZuniaSkeleton(width: 72, height: 11),
                SizedBox(height: 7),
                ZuniaSkeleton(width: 120, height: 9),
              ],
            ),
          ),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ZuniaSkeleton(width: 56, height: 11),
              SizedBox(height: 7),
              ZuniaSkeleton(width: 40, height: 9),
            ],
          ),
        ],
      ),
    );
  }
}

/// A list of [count] skeleton rows, announced once to assistive tech.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.count = 4, this.label = 'Loading'});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        liveRegion: true,
        child: ExcludeSemantics(
          child: Column(children: [for (var i = 0; i < count; i++) const AssetRowSkeleton()]),
        ),
      );
}
