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

  bool get isTestnet => network == 'testnet';

  double get averageGasPrice => gasPriceStep?['average'] ?? 0.025;

  /// Shape the FFI kernel expects for derivation.
  String toChainJson() => jsonEncode({
        'chainId': chainId,
        'bech32Prefix': bech32Prefix,
        'coinType': coinType,
      });

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
