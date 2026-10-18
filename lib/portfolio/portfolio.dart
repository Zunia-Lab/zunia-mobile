/// Home's asset rows, their prices and the portfolio total.
///
/// Port of `zunia-extension/lib/home-assets.ts` and `lib/portfolio.ts`
/// (0.1.5). One row per denom on an enabled chain: the chain's staking coin
/// always (a zero one too, so a network with no balance is still findable),
/// plus every other non-zero bank balance, each named by its token identity.
///
/// A row is priced through its identity only. The price map quotes each
/// chain's own coin, so a token takes a chain's price only when it is exactly
/// that coin ([priceChainOf]): ATOM on Osmosis takes the Hub's price, USDC.n
/// anywhere takes Noble's, USDC.axl takes nobody's. A token whose decimals are
/// unknown is never valued: its amount cannot be scaled. Unpriced holdings are
/// left out of the total and counted, never guessed.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';

/// How Home groups a row: the chain's staking coin, then IBC, factory, other.
enum AssetGroupKind { native, ibc, factory, other }

@immutable
class HomeAsset {
  const HomeAsset({
    required this.key,
    required this.chain,
    required this.denom,
    required this.amount,
    required this.amountKnown,
    required this.identity,
    required this.group,
    required this.subtitle,
    required this.fiatValue,
    required this.change24h,
    this.metadataName,
  });

  /// `chainId:denom`.
  final String key;
  final ChainEntry chain;
  final String denom;

  /// Base units. '0' with [amountKnown] false when the chain was not read.
  final String amount;

  /// The chain's balance was read: [amount] is a fact.
  final bool amountKnown;

  /// What the row shows: ticker, badge, decimals.
  final TokenIdentity identity;
  final AssetGroupKind group;

  /// `Noble USDC · on Osmosis`, `Native on Injective`.
  final String subtitle;

  /// Fiat value, or null when no trusted price applies.
  final double? fiatValue;
  final double? change24h;

  /// The chain's metadata name for a token nothing else names.
  final String? metadataName;

  bool get staking => group == AssetGroupKind.native;

  /// A positive integer balance.
  bool get held => amountKnown && RegExp(r'^\d*[1-9]\d*$').hasMatch(amount);

  AmountScale get scale => AmountScale.of(identity);
}

/* -------------------------------------------------------------------------- *
 * Words
 * -------------------------------------------------------------------------- */

/// A row's subtitle when it stands alone: what it is and where it sits.
String assetSubtitle(TokenIdentity identity) => tokenText(identity, TokenTextVariant.row);

/// A row's subtitle under a header that already names the chain.
String? groupedSubtitle(TokenIdentity identity) {
  if (identity.provenance == TokenProvenance.unknown) {
    return 'Unknown origin · ${shortDenom(identity.denom)}';
  }
  final home = identity.originChainId == identity.heldOnChainId;
  final staking = ChainCatalog.isLoaded
      ? ChainCatalog.instance.find(identity.heldOnChainId)?.coinMinimalDenom
      : null;
  if (home && identity.denom == staking) return null;
  return identity.name;
}

/* -------------------------------------------------------------------------- *
 * Prices
 * -------------------------------------------------------------------------- */

/// Whether [denom] is the coin [entry]'s price quotes. The fee coin counts only
/// when the catalog gives it the same price id (AtomOne's PHOTON is not ATONE).
bool _quotes(ChainEntry entry, String denom) {
  if (denom == entry.coinMinimalDenom) return true;
  if (denom != entry.feeMinimalDenom) return false;
  for (final currency in currenciesOf(entry)) {
    if (currency.coinMinimalDenom != denom) continue;
    return currency.coinGeckoId != null && currency.coinGeckoId == entry.coinGeckoId;
  }
  return false;
}

/// The chain whose spot price is [identity]'s, or null when no trusted price
/// applies:
/// - the holding chain's staking coin takes the holding chain's price;
/// - any other token takes its origin chain's price only when the identity is
///   proven and its exact origin denom is the coin that price quotes;
/// - nothing else is priced, and never when the decimals are unknown.
String? priceChainOf(TokenIdentity identity, {Set<String> exchangePriced = const {}}) {
  if (!identity.decimalsKnown) return null;
  final holding = ChainCatalog.isLoaded ? ChainCatalog.instance.find(identity.heldOnChainId) : null;
  if (holding != null && identity.denom == holding.coinMinimalDenom) return identity.heldOnChainId;
  final originChainId = identity.originChainId;
  final originDenom = identity.originDenom;
  if (!identity.proven || originChainId == null || originDenom == null) return null;
  final origin = ChainCatalog.isLoaded ? ChainCatalog.instance.find(originChainId) : null;
  if (origin == null) return null;
  final geckoId = origin.coinGeckoId;
  if (geckoId == null) {
    // Priced from an exchange market (SAF): only the chain's own coin.
    return exchangePriced.contains(originChainId) && originDenom == origin.coinMinimalDenom
        ? originChainId
        : null;
  }
  if (identity.coinGeckoId != null && identity.coinGeckoId != geckoId) return null;
  return _quotes(origin, originDenom) ? originChainId : null;
}

/* -------------------------------------------------------------------------- *
 * Rows
 * -------------------------------------------------------------------------- */

AssetGroupKind _groupOf(ChainEntry chain, TokenIdentity identity) {
  if (identity.denom == chain.coinMinimalDenom) return AssetGroupKind.native;
  return switch (identity.kind) {
    TokenKind.ibc => AssetGroupKind.ibc,
    TokenKind.factory => AssetGroupKind.factory,
    _ => AssetGroupKind.other,
  };
}

/// The chain's own coin as every chain-level figure shows it: the catalog's
/// ticker and exponent, so the row and the chain's page never disagree.
TokenIdentity nativeIdentity(ChainEntry chain) {
  final identity = identityOf(chain.chainId, chain.coinMinimalDenom);
  if (identity.decimals == chain.coinDecimals && identity.decimalsKnown) return identity;
  return identity.copyWith(decimals: chain.coinDecimals, decimalsKnown: true);
}

/// The identity a held row is shown with.
TokenIdentity rowIdentity(ChainEntry chain, HeldToken token) =>
    token.denom == chain.coinMinimalDenom
        ? nativeIdentity(chain)
        : heldTokenIdentity(chain.chainId, token.denom, metadataDecimals: token.metadataDecimals);

HomeAsset _asset(
  ChainEntry chain,
  String denom,
  String amount,
  bool known,
  TokenIdentity identity,
  PriceMap prices,
  Set<String> exchangePriced, {
  String? metadataName,
}) {
  final priceChain = priceChainOf(identity, exchangePriced: exchangePriced);
  final spot = priceChain == null ? null : prices[priceChain];
  return HomeAsset(
    key: '${chain.chainId}:$denom',
    chain: chain,
    denom: denom,
    amount: amount,
    amountKnown: known,
    identity: identity,
    group: _groupOf(chain, identity),
    subtitle: assetSubtitle(identity),
    fiatValue: spot == null || !known ? null : toWholeCoins(amount, identity.decimals) * spot.price,
    change24h: spot?.change24h,
    metadataName: metadataName,
  );
}

int _compareAssets(HomeAsset a, HomeAsset b) {
  final aZero = !a.held;
  final bZero = !b.held;
  if (aZero != bZero) return aZero ? 1 : -1;
  final af = a.fiatValue;
  final bf = b.fiatValue;
  if (af != null && bf != null && af != bf) return bf.compareTo(af);
  if (af != null && bf == null) return -1;
  if (af == null && bf != null) return 1;
  final kind = a.group.index - b.group.index;
  if (kind != 0) return kind;
  return a.identity.ticker.toLowerCase().compareTo(b.identity.ticker.toLowerCase());
}

/// Every enabled chain's coin, plus each non-zero IBC / factory / other
/// holding, best first.
List<HomeAsset> homeAssets(
  List<ChainEntry> chains,
  Map<String, ChainBalance> balances,
  PriceMap prices, {
  Set<String> exchangePriced = const {},
}) {
  final out = <HomeAsset>[];
  for (final chain in chains) {
    final balance = balances[chain.chainId];
    final native = nativeIdentity(chain);
    out.add(_asset(
      chain,
      chain.coinMinimalDenom,
      balance?.available ?? '0',
      balance != null,
      native,
      prices,
      exchangePriced,
    ));
    for (final token in balance?.tokens ?? const <HeldToken>[]) {
      if (token.denom == chain.coinMinimalDenom || token.amount == '0') continue;
      out.add(_asset(
        chain,
        token.denom,
        token.amount,
        true,
        rowIdentity(chain, token),
        prices,
        exchangePriced,
        metadataName: token.metadataName,
      ));
    }
  }
  out.sort(_compareAssets);
  return out;
}

@immutable
class HomeAssetGroup {
  const HomeAssetGroup({
    required this.chain,
    required this.assets,
    required this.fiatValue,
  });

  final ChainEntry chain;
  final List<HomeAsset> assets;
  final double? fiatValue;
}

/// Keep the enabled-chain order; drop empty groups.
List<HomeAssetGroup> groupHomeAssets(List<HomeAsset> assets, List<String> chainOrder) {
  final buckets = <String, List<HomeAsset>>{};
  for (final asset in assets) {
    buckets.putIfAbsent(asset.chain.chainId, () => []).add(asset);
  }
  final order = [...chainOrder, ...buckets.keys.where((id) => !chainOrder.contains(id))];
  return [
    for (final chainId in order)
      if (buckets[chainId] case final list? when list.isNotEmpty)
        HomeAssetGroup(
          chain: list.first.chain,
          assets: list,
          fiatValue: list.any((a) => a.fiatValue != null)
              ? list.fold<double>(0, (sum, a) => sum + (a.fiatValue ?? 0))
              : null,
        ),
  ];
}

/* -------------------------------------------------------------------------- *
 * Totals
 * -------------------------------------------------------------------------- */

@immutable
class ChainValue {
  const ChainValue({required this.chainId, required this.value, required this.change24h});
  final String chainId;
  final double? value;
  final double? change24h;
}

@immutable
class PortfolioTotals {
  const PortfolioTotals({
    required this.total,
    required this.staked,
    required this.claimable,
    required this.change24h,
    required this.pricedChains,
    required this.pricedAssets,
    required this.unpricedAssets,
    required this.byChain,
  });

  static const empty = PortfolioTotals(
    total: 0,
    staked: 0,
    claimable: 0,
    change24h: null,
    pricedChains: 0,
    pricedAssets: 0,
    unpricedAssets: 0,
    byChain: [],
  );

  /// Every priced row, plus what each priced chain stakes and has earned.
  final double total;
  final double staked;
  final double claimable;

  /// Value-weighted 24 h change across what is priced, or null.
  final double? change24h;

  /// Chains whose own coin has a price, held or not.
  final int pricedChains;

  /// Held assets in the total.
  final int pricedAssets;

  /// Held assets left out of the total because no trusted price applies.
  final int unpricedAssets;
  final List<ChainValue> byChain;

  bool get hasTotal => pricedChains > 0 || pricedAssets > 0;
}

/// Home's headline: the sum of the rows Home lists, plus what each chain
/// stakes and has earned at the chain's price. Staked and reward amounts the
/// chain could not read are left out, not counted as zero.
PortfolioTotals computePortfolio(
  List<ChainEntry> chains,
  Map<String, ChainBalance> balances,
  PriceMap prices,
  List<HomeAsset> assets,
) {
  final tally = <String, ({double value, double weighted, bool priced})>{};
  var total = 0.0;
  var staked = 0.0;
  var claimable = 0.0;
  var weighted = 0.0;
  var pricedChains = 0;
  var pricedAssets = 0;
  var unpricedAssets = 0;

  void add(String chainId, double value, double? change) {
    final entry = tally[chainId] ?? (value: 0.0, weighted: 0.0, priced: false);
    tally[chainId] = (
      value: entry.value + value,
      weighted: entry.weighted + value * (change ?? 0),
      priced: true,
    );
    total += value;
    weighted += value * (change ?? 0);
  }

  final stakingRows = <String, HomeAsset>{};
  for (final asset in assets) {
    if (asset.staking) {
      stakingRows[asset.chain.chainId] = asset;
      continue;
    }
    if (!asset.held) continue;
    if (asset.fiatValue == null) {
      unpricedAssets += 1;
      continue;
    }
    pricedAssets += 1;
    add(asset.chain.chainId, asset.fiatValue!, asset.change24h);
  }

  for (final chain in chains) {
    final balance = balances[chain.chainId];
    final spot = prices[chain.chainId];
    if (spot != null) pricedChains += 1;
    final row = stakingRows[chain.chainId];
    if (balance == null) {
      continue;
    }
    if (row != null && row.fiatValue != null) add(chain.chainId, row.fiatValue!, row.change24h);
    final stakedCoins = balance.stakingKnown ? toWholeCoins(balance.staked, chain.coinDecimals) : 0.0;
    final rewards = balance.rewardsKnown ? toWholeCoins(balance.rewards, chain.coinDecimals) : 0.0;
    final position = stakedCoins + rewards;
    if (spot != null && position != 0) {
      staked += stakedCoins * spot.price;
      claimable += rewards * spot.price;
      add(chain.chainId, position * spot.price, spot.change24h);
    }
    // The chain's coin is one asset, whether available, staked or earning.
    final held = (row?.held ?? false) || position > 0;
    if (held) {
      if ((row?.fiatValue != null) || (spot != null && position > 0)) {
        pricedAssets += 1;
      } else {
        unpricedAssets += 1;
      }
    }
  }

  final byChain = [
    for (final MapEntry(:key, :value) in tally.entries)
      ChainValue(
        chainId: key,
        value: value.priced ? value.value : null,
        change24h: value.priced && value.value > 0 ? value.weighted / value.value : null,
      ),
  ]..sort((a, b) => (b.value ?? -1).compareTo(a.value ?? -1));

  return PortfolioTotals(
    total: total,
    staked: staked,
    claimable: claimable,
    change24h: total > 0 ? weighted / total : null,
    pricedChains: pricedChains,
    pricedAssets: pricedAssets,
    unpricedAssets: unpricedAssets,
    byChain: byChain,
  );
}
