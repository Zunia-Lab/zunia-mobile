/// The bundled data every swap decision reads: the deployment config, the fee
/// policy and the token book, loaded once from `assets/data`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/swap/swap_config.dart';
import 'package:zunia_mobile/swap/swap_fee.dart';
import 'package:zunia_mobile/swap/swap_tokens.dart';

@immutable
class SwapData {
  const SwapData({
    required this.config,
    required this.fees,
    required this.book,
    required this.catalog,
  });

  final SwapConfig config;
  final SwapFeePolicy fees;
  final SwapTokenBook book;

  /// The bundled chain catalog (the user's own chains are never issuers).
  final List<ChainEntry> catalog;

  String get venueChainId => config.venueChainId;

  /// Load everything from [bundle], against the loaded chain catalog.
  static Future<SwapData> load(AssetBundle bundle) async {
    final catalog = ChainCatalog.isLoaded
        ? ChainCatalog.instance
        : await ChainCatalog.load();
    final (config, fee) = await loadSwapConfig(bundle);
    final book = await SwapTokenBook.load(
      bundle,
      catalog: catalog.registryOnly,
      custom: catalog.customOnly,
    );
    return SwapData(
      config: config,
      fees: SwapFeePolicy.fromConfig(fee),
      book: book,
      catalog: catalog.registryOnly,
    );
  }
}

/// Loaded once per process; tests override it with data they loaded first.
final swapDataProvider = FutureProvider<SwapData>(
  (ref) => SwapData.load(rootBundle),
);
