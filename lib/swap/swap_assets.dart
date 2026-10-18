/// The swap screen's two lists: what the wallet can sell, and what it can buy
/// and where that will be delivered.
///
/// Port of zunia-extension 0.1.5 `lib/swap-assets.ts`. Every row is one exact
/// bank denom on one chain, named by its identity (`swap_tokens.dart`). The
/// ticker says what the token is and never where it is; the row's chain is
/// where the coin is held (sell) or delivered (buy). Signing reads [chainId]
/// and [denom] and nothing else here. A delivery row's denom is the token
/// table's hash-verified `originDenom` (exact case), never a catalog string.
library;

import 'package:flutter/foundation.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/swap/osmosis_assets.dart';
import 'package:zunia_mobile/swap/swap_path.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';
import 'package:zunia_mobile/swap/xcs_routes.dart';

/// One denom the wallet holds on one chain.
@immutable
class HeldToken {
  const HeldToken(this.denom, this.amount);

  final String denom;

  /// Base units, digits only.
  final String amount;
}

/// An enabled chain and this wallet's address on it.
@immutable
class SwapChain {
  const SwapChain(this.entry, this.address);

  final ChainEntry entry;
  final String address;

  String get chainId => entry.chainId;
}

/// One row of either list: a denom on a chain, with what it is and whether it
/// can be picked.
@immutable
class SwapAsset {
  const SwapAsset({
    required this.identity,
    required this.amount,
    required this.held,
    required this.chainIconUrl,
    this.executable = Executable.unknown,
    this.disabledReason,
    this.searchOnly = false,
  });

  /// What the token is, carrying this row's exponent.
  final SwapTokenIdentity identity;

  /// Base units held; zero for a row the wallet does not hold.
  final BigInt amount;

  /// The wallet holds a non-zero amount of this denom on this chain.
  final bool held;

  /// The location chain's logo, for the badge. Never the token's logo.
  final String? chainIconUrl;

  /// The route table's answer for the current From.
  final Executable executable;

  /// Why the row cannot be picked; null when it can.
  final String? disabledReason;

  /// Listed only by a search, with its reason: every row that cannot be picked.
  final bool searchOnly;

  /// `${chainId}:${denom}`.
  String get key => identity.key;

  /// Held on (sell) or delivered on (buy). Signed as is.
  String get chainId => identity.chainId;
  String get chainName => identity.chainName;

  /// The exact bank denom on [chainId]. Signed as is.
  String get denom => identity.denom;
  String get ticker => identity.ticker;
  int get decimals => identity.decimals;

  /// False when nothing proves the exponent: only Max is allowed.
  bool get decimalsKnown => identity.decimalsKnown;
  bool get testnet => identity.testnet;

  GateSide get gateSide => GateSide(
    key: key,
    chainId: chainId,
    denom: denom,
    identity: identity,
    testnet: testnet,
  );

  SwapAsset gated(Gate gate) => SwapAsset(
    identity: identity,
    amount: amount,
    held: held,
    chainIconUrl: chainIconUrl,
    executable: gate.executable,
    disabledReason: gate.disabledReason,
    searchOnly: gate.disabledReason != null,
  );

  /// Every name a search should find.
  Iterable<String> get keywords sync* {
    yield identity.ticker;
    yield identity.family;
    yield identity.name;
    yield chainName;
    if (identity.originChainName != null) yield identity.originChainName!;
    yield denom;
    yield* identity.aliases;
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return keywords.any((word) => word.toLowerCase().contains(q));
  }
}

final RegExp _positiveAmount = RegExp(r'^0*[1-9]\d*$');

/// The exponent a typed amount is converted with, or null when nothing proves
/// one. SQS's figure for the asset's Osmosis denom is a further witness: when
/// it disagrees, a typed amount could be signed at the wrong scale.
SwapTokenIdentity _withExponent(
  SwapTokenIdentity identity,
  Map<String, int> listed,
) {
  if (!identity.decimalsKnown) return identity;
  final venue = identity.chainId == kOsmosisChainId
      ? identity.denom
      : identity.osmosisDenom;
  final sqs = venue == null ? null : listed[venue];
  if (sqs == null || sqs == identity.decimals) return identity;
  return identity.withDecimals(null);
}

SwapAsset _row(
  SwapTokenBook book,
  Map<String, int> listed, {
  required String chainId,
  required String denom,
  required BigInt amount,
  required bool held,
  String? chainIconUrl,
}) {
  final identity = _withExponent(book.identityOf(chainId, denom), listed);
  return SwapAsset(
    identity: identity,
    amount: amount,
    held: held,
    chainIconUrl: chainIconUrl,
  );
}

Map<String, int> _listedDecimals(List<OsmosisAsset> osmosis) => {
  for (final asset in osmosis) asset.denom: asset.decimals,
};

/// Everything the wallet can sell: one row per non-zero balance, per chain
/// and exact bank denom, in the order of [chains] and then of each balance.
List<SwapAsset> sellOptions(
  List<SwapChain> chains,
  Map<String, List<HeldToken>> holdings,
  SwapTokenBook book, {
  List<OsmosisAsset> osmosis = const [],
}) {
  final listed = _listedDecimals(osmosis);
  final out = <SwapAsset>[];
  final seen = <String>{};
  for (final chain in chains) {
    for (final token in holdings[chain.chainId] ?? const <HeldToken>[]) {
      if (token.denom.isEmpty || !_positiveAmount.hasMatch(token.amount)) {
        continue;
      }
      if (!seen.add('${chain.chainId}:${token.denom}')) continue;
      out.add(
        _row(
          book,
          listed,
          chainId: chain.chainId,
          denom: token.denom,
          amount: BigInt.parse(token.amount),
          held: true,
          chainIconUrl: chain.entry.iconUrl,
        ),
      );
    }
  }
  return out;
}

/// Where an Osmosis voucher is delivered when it goes home: its issuer, as
/// the table's exact `originDenom`, over the registry's canonical channel.
/// Only for a voucher whose first hop lands on its listed origin, on a bundled
/// mainnet, and only when the issuer's identity names this voucher as its
/// Osmosis denom. Never for a CW20 origin.
({String chainId, String denom})? _deliveryOf(
  OsmosisAsset asset,
  SwapTokenBook book,
  Map<String, ChainEntry> catalog,
) {
  final row = asset.row;
  if (row.path.isEmpty ||
      row.channelId == null ||
      row.counterpartyChainId != row.originChainId) {
    return null;
  }
  if (row.originChainId == kOsmosisChainId ||
      RegExp(r'^cw20:', caseSensitive: false).hasMatch(row.originDenom)) {
    return null;
  }
  final entry = catalog[row.originChainId];
  if (entry == null ||
      entry.network != 'mainnet' ||
      book.isTestnetChain(row.originChainId)) {
    return null;
  }
  if (!book.isCanonicalChannel(
    kOsmosisChainId,
    row.originChainId,
    row.channelId!,
  )) {
    return null;
  }
  final identity = book.identityOf(row.originChainId, row.originDenom);
  if (!identity.known || identity.osmosisDenom != asset.denom) return null;
  return (chainId: row.originChainId, denom: row.originDenom);
}

int _compareText(String a, String b) => a.compareTo(b);

int _byTicker(SwapAsset a, SwapAsset b) {
  final ticker = _compareText(a.ticker.toLowerCase(), b.ticker.toLowerCase());
  if (ticker != 0) return ticker;
  int home(SwapAsset option) =>
      option.identity.originChainId == option.chainId ? 0 : 1;
  final step = home(a) - home(b);
  if (step != 0) return step;
  final chain = _compareText(
    a.chainName.toLowerCase(),
    b.chainName.toLowerCase(),
  );
  return chain != 0 ? chain : _compareText(a.key, b.key);
}

/// Held rows first (in balance order), then rows the contract can reach, then
/// the rest that can still be picked, then the ones that cannot.
List<SwapAsset> _ordered(List<SwapAsset> options) {
  final position = {for (var i = 0; i < options.length; i++) options[i].key: i};
  int group(SwapAsset option) => option.disabledReason != null
      ? 3
      : option.held
      ? 0
      : option.executable == Executable.yes
      ? 1
      : 2;
  final out = [...options];
  out.sort((a, b) {
    final step = group(a) - group(b);
    if (step != 0) return step;
    if (a.held != b.held) return a.held ? -1 : 1;
    if (a.held) return (position[a.key] ?? 0) - (position[b.key] ?? 0);
    return _byTicker(a, b);
  });
  return out;
}

/// Everything the wallet can ask a swap to deliver, one row per
/// `${chainId}:${denom}`, from four sources: the held balances; the staking
/// coin of every bundled chain on the From's network; the Osmosis rows of
/// [osmosis], delivered on Osmosis; each of those delivered home to its
/// issuer. Only the From's network is shown. A token nothing identifies is
/// offered only when held. Each row is gated against the From with the route
/// table; a row that cannot be picked carries its reason and is search-only.
List<SwapAsset> buyOptions(
  List<SwapChain> chains,
  Map<String, List<HeldToken>> holdings,
  SwapTokenBook book, {
  required List<ChainEntry> catalog,
  SwapAsset? from,
  List<OsmosisAsset> osmosis = const [],
  XcsRouteTable? routes,
}) {
  final listed = _listedDecimals(osmosis);
  final testnet = from?.testnet ?? false;
  final byChain = {for (final entry in catalog) entry.chainId: entry};
  final rows = <String, SwapAsset>{};
  void add(SwapAsset option) {
    if (rows.containsKey(option.key) || option.testnet != testnet) return;
    if (!option.held && !option.identity.known) return;
    rows[option.key] = option;
  }

  void addRow(String chainId, String denom) {
    if (rows.containsKey('$chainId:$denom')) return;
    add(
      _row(
        book,
        listed,
        chainId: chainId,
        denom: denom,
        amount: BigInt.zero,
        held: false,
        chainIconUrl: byChain[chainId]?.iconUrl,
      ),
    );
  }

  for (final option in sellOptions(chains, holdings, book, osmosis: osmosis)) {
    add(option);
  }
  for (final entry in catalog) {
    if (entry.isTestnet != testnet) continue;
    addRow(entry.chainId, entry.coinMinimalDenom);
  }
  if (!testnet) {
    for (final asset in osmosis) {
      addRow(kOsmosisChainId, asset.denom);
    }
    for (final asset in osmosis) {
      final delivery = _deliveryOf(asset, book, byChain);
      if (delivery != null) addRow(delivery.chainId, delivery.denom);
    }
  }

  final gateFrom = from?.gateSide;
  final gated = [
    for (final option in rows.values)
      option.gated(gateOption(gateFrom, option.gateSide, routes, book)),
  ];
  return _ordered(gated);
}

/// The To on screen. A row the user picked stays picked, even once the From
/// or the route table turns it off: its reason is then shown and nothing is
/// planned for it. With no pick, the first row that can be used.
SwapAsset? pickTo(List<SwapAsset> destinations, String? toKey) {
  if (toKey != null) {
    for (final asset in destinations) {
      if (asset.key == toKey) return asset;
    }
  }
  for (final asset in destinations) {
    if (asset.disabledReason == null) return asset;
  }
  return null;
}
