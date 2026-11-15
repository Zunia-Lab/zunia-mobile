/// How a notification words a coin it did not create.
///
/// The moved denom's own identity names it, never the chain's coin: a user who
/// received 15 USDC on Safrochain was told "15 SAF", because every received
/// amount was written with the chain's symbol and decimals.
library;

import 'package:zunia_mobile/notifications/notices.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/util/amounts.dart';

final RegExp _digits = RegExp(r'^\d+$');

/// `15 USDC.inj (Injective USDC)` on Safrochain, `15 USDC.inj` on Injective,
/// `15 SAF` for the chain's own coin. When nothing proves the token's
/// decimals (a voucher not traced yet), base units and the short denom:
/// a guessed scale would put a wrong number in a notification.
///
/// [decimalsHint] and [symbolHint] are what the chain's own catalog entry
/// lists for the denom (its coin or one of its currencies, or bank metadata),
/// used only when no identity names the token.
String describeMovedCoin(
  String chainId,
  String denom,
  String amount, {
  int? decimalsHint,
  String? symbolHint,
}) {
  if (!_digits.hasMatch(amount)) return describeCoinRaw(chainId, MovedCoin(denom, amount));
  final identity = heldTokenIdentity(chainId, denom, metadataDecimals: decimalsHint);
  if (!identity.decimalsKnown) return describeCoinRaw(chainId, MovedCoin(denom, amount));
  final value = formatBaseUnitsExact(amount, decimals: identity.decimals, maxFractionDigits: 6);
  final hint = symbolHint?.trim() ?? '';
  final ticker =
      identity.provenance == TokenProvenance.unknown && hint.isNotEmpty ? hint : identity.ticker;
  return '$value $ticker${originNote(identity, chainId)}';
}

/// ` (Injective USDC)` for a token issued on another chain than [heldOn]; empty
/// for the chain's own tokens and for a token whose origin nothing proves.
String originNote(TokenIdentity identity, String heldOn) {
  final origin = identity.originChainId;
  if (origin == null || origin == heldOn) return '';
  final name = identity.name.trim();
  if (name.isNotEmpty && name != identity.ticker && name != 'Unknown token') return ' ($name)';
  final chain = identity.originChainName?.trim();
  return chain == null || chain.isEmpty ? '' : ' (from $chain)';
}

/// The `ibc/` vouchers among [denoms] that nothing names yet on [chainId]:
/// what has to be traced before a notification can say what arrived.
List<String> untracedVouchers(String chainId, Iterable<String> denoms) => [
  for (final denom in {...denoms})
    if (denom.startsWith('ibc/') &&
        identityOf(chainId, denom).provenance == TokenProvenance.unknown)
      denom,
];
