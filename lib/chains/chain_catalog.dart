import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One registry row. Generated into `assets/chains/catalog.json` by
/// `zunia-extension/scripts/generate-chain-catalog.mjs`, so the extension and
/// the app always agree on chain ids, prefixes and endpoints.
class ChainEntry {
  const ChainEntry({
    required this.chainId,
    required this.chainName,
    required this.bech32Prefix,
    required this.coinType,
    required this.network,
    required this.coinDenom,
    required this.coinMinimalDenom,
    required this.coinDecimals,
    required this.feeDenom,
    required this.feeMinimalDenom,
    required this.feeDecimals,
    this.gasPriceStep,
    this.rpc,
    this.rest,
    this.iconUrl,
    this.features,
    this.registrySlug,
    this.inCosmosRegistry = false,
    this.logoSlugs,
    this.currencies = const [],
    this.ethPubKeyTypeUrl,
    this.coinGeckoId,
  });

  factory ChainEntry.fromJson(Map<String, dynamic> json) {
    final gas = json['gasPriceStep'] as Map<String, dynamic>?;
    return ChainEntry(
      chainId: json['chainId'] as String,
      chainName: json['chainName'] as String? ?? json['chainId'] as String,
      bech32Prefix: json['bech32Prefix'] as String,
      coinType: (json['coinType'] as num?)?.toInt() ?? 118,
      network: json['network'] as String? ?? 'mainnet',
      coinDenom: json['coinDenom'] as String? ?? '',
      coinMinimalDenom: json['coinMinimalDenom'] as String? ?? '',
      coinDecimals: (json['coinDecimals'] as num?)?.toInt() ?? 6,
      feeDenom: json['feeDenom'] as String? ?? '',
      feeMinimalDenom: json['feeMinimalDenom'] as String? ?? '',
      feeDecimals: (json['feeDecimals'] as num?)?.toInt() ?? 6,
      gasPriceStep: gas == null
          ? null
          : {
              for (final e in gas.entries) e.key: (e.value as num).toDouble(),
            },
      rpc: json['rpc'] as String?,
      rest: json['rest'] as String?,
      iconUrl: json['iconUrl'] as String?,
      // Null when the key is absent, never []: "nobody told us" and "this
      // chain declares no capabilities" are different facts, and only the
      // second may be used to rule a chain out. The generator currently drops
      // this array, so null is the common case today.
      features: json['features'] is List
          ? [
              for (final value in json['features'] as List)
                if (value is String) value,
            ]
          : null,
      registrySlug: json['registrySlug'] as String?,
      inCosmosRegistry: json['inCosmosRegistry'] == true,
      logoSlugs: json['logoSlugs'] is List
          ? [
              for (final value in json['logoSlugs'] as List)
                if (value is String) value,
            ]
          : null,
      currencies: json['currencies'] is List
          ? [
              for (final value in json['currencies'] as List)
                if (value is Map<String, dynamic>) ChainCurrency.fromJson(value),
            ]
          : const [],
      ethPubKeyTypeUrl: json['ethPubKeyTypeUrl'] as String?,
      coinGeckoId: json['coinGeckoId'] as String?,
    );
  }

  final String chainId;
  final String chainName;
  final String bech32Prefix;
  final int coinType;
  final String network;
  final String coinDenom;
  final String coinMinimalDenom;
  final int coinDecimals;
  final String feeDenom;
  final String feeMinimalDenom;
  final int feeDecimals;
  final Map<String, double>? gasPriceStep;
  final String? rpc;
  final String? rest;
  final String? iconUrl;

  /// Registry capability flags, e.g. `['cosmwasm']`.
  ///
  /// Gates the whole NFT surface: only a chain that runs CosmWasm can hold a
  /// CW721 token. Null means the catalog did not carry the array — see
  /// `zunia-extension/scripts/generate-chain-catalog.mjs`, which drops it — and
  /// the app then asks the chain rather than assuming either answer.
  final List<String>? features;

  /// Official cosmos/chain-registry `chain_name` when this chain_id is listed.
  final String? registrySlug;

  /// True when `chainId` is in the official cosmos/chain-registry.
  final bool inCosmosRegistry;

  /// Cosmostation / registry directory names for validator moniker images.
  final List<String>? logoSlugs;

  /// Every currency the registry lists for the chain, native coin first.
  final List<ChainCurrency> currencies;

  /// Protobuf type URL of an `ethsecp256k1` key when it is not Ethermint's,
  /// e.g. Injective's.
  final String? ethPubKeyTypeUrl;

  /// CoinGecko id of the native coin, when it has one.
  final String? coinGeckoId;

  /// Addresses are keccak-derived, Ethereum style (Evmos, Injective, ...).
  bool get usesEthAddress => features?.contains('eth-address-gen') ?? false;

  /// The chain verifies keccak256 sign bytes rather than SHA-256.
  bool get usesEthKeySign => features?.contains('eth-key-sign') ?? false;

  bool get isTestnet => network == 'testnet';

  double get averageGasPrice => gasPriceStep?['average'] ?? 0.025;

  /// The chain document the kernel derives and signs with.
  ///
  /// The kernel parses it as a Keplr `ChainInfo` and refuses anything missing
  /// `chainName`, `rpc`, `rest`, `bip44`, `bech32Config` or `feeCurrencies`.
  /// `features` decides the address scheme and the signing hash, so it is
  /// passed through whole. Mirrors the extension's `chainJsonFor`
  /// (zunia-extension/lib/chains.ts) field for field, which is what makes one
  /// phrase give the same addresses in both.
  String toChainJson() {
    final fee = {
      'coinDenom': feeDenom.isEmpty ? coinDenom : feeDenom,
      'coinMinimalDenom': feeMinimalDenom.isEmpty ? coinMinimalDenom : feeMinimalDenom,
      'coinDecimals': feeMinimalDenom.isEmpty ? coinDecimals : feeDecimals,
      'gasPriceStep': gasPriceStep ?? const {'low': 0.01, 'average': 0.025, 'high': 0.04},
    };
    return jsonEncode({
      'chainId': chainId,
      'chainName': chainName,
      'rpc': _kernelEndpoint(rpc),
      'rest': _kernelEndpoint(rest),
      'bip44': {'coinType': coinType},
      'bech32Config': {'bech32PrefixAccAddr': bech32Prefix},
      'currencies': [
        {
          'coinDenom': coinDenom,
          'coinMinimalDenom': coinMinimalDenom,
          'coinDecimals': coinDecimals,
        },
      ],
      'feeCurrencies': [fee],
      'features': features ?? const <String>[],
      if (ethPubKeyTypeUrl != null) 'ethPubKeyTypeUrl': ethPubKeyTypeUrl,
      'bech32Prefix': bech32Prefix,
      'coinType': coinType,
    });
  }

  /// `ChainInfo::validate` accepts https or loopback. The kernel never dials
  /// these; the wallet's own LCD calls use [rest] directly.
  static String _kernelEndpoint(String? url) {
    if (url != null &&
        (url.startsWith('https://') ||
            url.startsWith('http://localhost') ||
            url.startsWith('http://127.0.0.1') ||
            url.startsWith('http://0.0.0.0'))) {
      return url;
    }
    return 'https://rpc.invalid';
  }

  Map<String, dynamic> toJson() => {
        'chainId': chainId,
        'chainName': chainName,
        'bech32Prefix': bech32Prefix,
        'coinType': coinType,
        'network': network,
        'coinDenom': coinDenom,
        'coinMinimalDenom': coinMinimalDenom,
        'coinDecimals': coinDecimals,
        'feeDenom': feeDenom,
        'feeMinimalDenom': feeMinimalDenom,
        'feeDecimals': feeDecimals,
        if (gasPriceStep != null) 'gasPriceStep': gasPriceStep,
        if (rpc != null) 'rpc': rpc,
        if (rest != null) 'rest': rest,
        if (iconUrl != null) 'iconUrl': iconUrl,
        if (features != null) 'features': features,
        if (registrySlug != null) 'registrySlug': registrySlug,
        'inCosmosRegistry': inCosmosRegistry,
        if (logoSlugs != null) 'logoSlugs': logoSlugs,
        if (currencies.isNotEmpty)
          'currencies': [for (final c in currencies) c.toJson()],
        if (ethPubKeyTypeUrl != null) 'ethPubKeyTypeUrl': ethPubKeyTypeUrl,
        if (coinGeckoId != null) 'coinGeckoId': coinGeckoId,
      };

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return chainName.toLowerCase().contains(q) ||
        chainId.toLowerCase().contains(q) ||
        bech32Prefix.toLowerCase().contains(q) ||
        coinDenom.toLowerCase().contains(q);
  }
}

/// One currency of a chain, as the registry lists it.
class ChainCurrency {
  const ChainCurrency({
    required this.coinDenom,
    required this.coinMinimalDenom,
    required this.coinDecimals,
    this.coinGeckoId,
  });

  factory ChainCurrency.fromJson(Map<String, dynamic> json) => ChainCurrency(
        coinDenom: json['coinDenom'] as String? ?? '',
        coinMinimalDenom: json['coinMinimalDenom'] as String? ?? '',
        coinDecimals: (json['coinDecimals'] as num?)?.toInt() ?? 6,
        coinGeckoId: json['coinGeckoId'] as String?,
      );

  final String coinDenom;
  final String coinMinimalDenom;
  final int coinDecimals;
  final String? coinGeckoId;

  Map<String, dynamic> toJson() => {
        'coinDenom': coinDenom,
        'coinMinimalDenom': coinMinimalDenom,
        'coinDecimals': coinDecimals,
        if (coinGeckoId != null) 'coinGeckoId': coinGeckoId,
      };
}

/// Chains pinned to the top of every picker, in this order.
const pinnedChainIds = <String>['safrochain-1', 'cosmoshub-4', 'osmosis-1'];

/// Loaded once per process from the bundled asset, then held in memory.
class ChainCatalog {
  ChainCatalog._(this._entries, this._custom);

  static ChainCatalog? _instance;

  final List<ChainEntry> _entries;
  List<ChainEntry> _custom;

  static ChainCatalog get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('ChainCatalog.load() must run before first use');
    }
    return value;
  }

  static bool get isLoaded => _instance != null;

  static Future<ChainCatalog> load({
    List<ChainEntry> custom = const [],
  }) async {
    if (_instance != null) {
      _instance!._custom = custom;
      return _instance!;
    }
    final raw = await rootBundle.loadString('assets/chains/catalog.json');
    final rows = (jsonDecode(raw) as List<dynamic>)
        .map((e) => ChainEntry.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    _instance = ChainCatalog._(rows, custom);
    return _instance!;
  }

  void setCustom(List<ChainEntry> custom) => _custom = custom;

  /// Registry rows plus anything the user added by hand.
  List<ChainEntry> get all => [..._entries, ..._custom];

  List<ChainEntry> get registryOnly => List.unmodifiable(_entries);

  List<ChainEntry> get customOnly => List.unmodifiable(_custom);

  ChainEntry? find(String chainId) {
    for (final entry in _custom) {
      if (entry.chainId == chainId) return entry;
    }
    for (final entry in _entries) {
      if (entry.chainId == chainId) return entry;
    }
    return null;
  }

  /// Pinned first, then mainnets before testnets, then alphabetical.
  List<ChainEntry> sorted([List<ChainEntry>? source]) {
    final rows = [...(source ?? all)];
    rows.sort((a, b) {
      final ra = pinnedChainIds.indexOf(a.chainId);
      final rb = pinnedChainIds.indexOf(b.chainId);
      final ka = ra == -1 ? 1 << 30 : ra;
      final kb = rb == -1 ? 1 << 30 : rb;
      if (ka != kb) return ka - kb;
      if (a.network != b.network) return a.network == 'mainnet' ? -1 : 1;
      return a.chainName.toLowerCase().compareTo(b.chainName.toLowerCase());
    });
    return rows;
  }

  List<ChainEntry> search(String query, {String filter = 'mainnet'}) {
    return sorted(
      all
          .where((c) => filter == 'all' || c.network == filter)
          .where((c) => c.matches(query))
          .toList(),
    );
  }
}
