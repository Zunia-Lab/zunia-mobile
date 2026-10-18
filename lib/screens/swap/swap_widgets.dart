/// Pieces the swap form and its confirm card share: a token's mark with the
/// chain it sits on, the price countdown, and one labelled fact.
library;

import 'package:flutter/material.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// A token's logo with a small badge of the chain it is held on (or delivered
/// to), so `USDC.n on Osmosis` and `USDC.n on Noble` never look alike.
class SwapTokenMark extends StatelessWidget {
  const SwapTokenMark({
    super.key,
    required this.identity,
    this.chainIconUrl,
    this.size = 32,
  });

  final SwapTokenIdentity identity;
  final String? chainIconUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final badge = size * 0.46;
    final ownCoin = identity.originChainId == identity.chainId;
    return Semantics(
      label: '${identity.ticker} on ${identity.chainName}',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        width: size + 2,
        height: size + 2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ZuniaTokenLogo(
              symbol: identity.ticker,
              iconUrl: identity.logoUrl,
              size: size,
              verified: identity.proven && size >= 28 && ownCoin,
            ),
            if (!ownCoin)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: badge,
                  height: badge,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: s.surface, width: 1.5),
                  ),
                  child: ZuniaAvatar(
                    imageUrl: chainIconUrl,
                    fallback: identity.chainName,
                    size: badge - 3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// How long the shown price stays current, and a way to fetch a new one now.
class SwapQuoteClock extends StatelessWidget {
  const SwapQuoteClock({
    super.key,
    required this.secondsLeft,
    required this.refreshing,
    required this.onRefresh,
    this.confirm = false,
  });

  final int secondsLeft;
  final bool refreshing;
  final VoidCallback? onRefresh;

  /// On the confirm card the price does not move on its own.
  final bool confirm;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final expired = secondsLeft <= 0;
    final text = refreshing
        ? 'Updating the price…'
        : expired
        ? confirm
              ? 'Price expired. Refresh it to sign.'
              : 'Price expired'
        : confirm
        ? 'Price valid for ${secondsLeft}s'
        : 'Price updates in ${secondsLeft}s';
    return Row(
      children: [
        if (refreshing) ...[
          const ZuniaActivityIndicator(size: 12),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Semantics(
            liveRegion: expired,
            child: Text(
              text,
              style: zuniaMono(
                fontSize: 11,
                color: expired && !refreshing ? s.warning : s.fgMuted,
              ),
            ),
          ),
        ),
        Semantics(
          container: true,
          button: true,
          label: 'Refresh the price',
          excludeSemantics: true,
          child: TextButton(
            onPressed: refreshing ? null : onRefresh,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foregroundColor: s.accent,
            ),
            child: Text(
              'Refresh',
              style: zuniaMono(fontSize: 11, color: s.accent),
            ),
          ),
        ),
      ],
    );
  }
}

/// One value in the swap's terms: the label on the left, the value (and a
/// line about it) on the right, wrapping rather than overflowing at 320dp.
class SwapFact extends StatelessWidget {
  const SwapFact({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.trailing,
    this.emphasise = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? note;
  final Widget? trailing;
  final bool emphasise;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      container: true,
      label: note == null ? '$label: $value' : '$label: $value. $note',
      excludeSemantics: trailing == null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Text(
                label,
                style: zuniaSans(fontSize: 13, color: s.fgMuted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    textAlign: TextAlign.right,
                    style: zuniaMono(
                      fontSize: 12.5,
                      fontWeight: emphasise ? FontWeight.w500 : FontWeight.w400,
                      color: valueColor ?? s.fg,
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      note!,
                      textAlign: TextAlign.right,
                      style: zuniaSans(
                        fontSize: 11,
                        height: 1.35,
                        color: s.fgDim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A shimmer-free placeholder line for a number that is on its way.
class SwapSkeletonLine extends StatelessWidget {
  const SwapSkeletonLine({super.key, this.width = 120, this.height = 12});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: ZuniaSkeleton(width: width, height: height),
  );
}
