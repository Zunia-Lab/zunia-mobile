/// The swap's deployment data and Zunia's commission, read from the files the
/// extension release ships (`assets/data/interchain.json`, `swap-fee.json`).
///
/// Both are copied verbatim from extension 0.1.5 by
/// `scripts/sync-extension-data.mjs` and never edited here: the app charges
/// exactly the commission that release charges and checks the same contract
/// candidates. Nothing here is fetched or overridden at run time; a build
/// swaps on what it was released with.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// `assets/data/interchain.json`: where swaps execute and how cautiously.
@immutable
class SwapConfig {
  const SwapConfig({
    required this.venueChainId,
    required this.xcsContractCandidates,
    required this.routerEndpoints,
    required this.defaultSlippagePercent,
    required this.slippagePresets,
    required this.highSlippagePercent,
    required this.maxSlippagePercent,
    required this.packetTimeoutMinutes,
    required this.maxRouteHops,
    required this.quoteTtl,
    required this.explorerTxUrls,
  });

  /// The chain the crosschain-swaps contract and the pools run on.
  final String venueChainId;

  /// Crosschain-swaps addresses, highest confidence first. Unverified: each is
  /// checked on chain before any swap control is enabled.
  final List<String> xcsContractCandidates;

  /// SQS router hosts, in priority order.
  final List<String> routerEndpoints;

  /// On the 0-100 scale the swaprouter reads, not a 0-1 fraction.
  final double defaultSlippagePercent;
  final List<double> slippagePresets;

  /// Above this the settings warn; it is not a limit.
  final double highSlippagePercent;

  /// Refused outright: a tolerance this wide protects nothing.
  final double maxSlippagePercent;

  final int packetTimeoutMinutes;
  final int maxRouteHops;

  /// How long a price counts as current.
  final Duration quoteTtl;

  /// `{hash}` templates by chain id.
  final Map<String, String> explorerTxUrls;

  /// The explorer page for [txHash] on [chainId], or null when this release
  /// names no explorer there: a guessed domain is worse than none.
  String? explorerTxUrl(String chainId, String txHash) {
    final template = explorerTxUrls[chainId];
    if (template == null) return null;
    return template.replaceAll('{hash}', Uri.encodeComponent(txHash));
  }

  /// Parse the shipped document. Throws [FormatException] on a field this
  /// build cannot read: a swap configured from a half-read file is worse than
  /// no swap.
  factory SwapConfig.fromJson(Map<String, Object?> json) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('interchain.json: $key is not a string');
      }
      return value;
    }

    double number(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite) {
        throw FormatException('interchain.json: $key is not a number');
      }
      return value.toDouble();
    }

    List<String> strings(String key) {
      final value = json[key];
      if (value is! List || value.any((e) => e is! String)) {
        throw FormatException('interchain.json: $key is not a list of strings');
      }
      return List.unmodifiable(value.cast<String>());
    }

    final presets = json['slippagePresets'];
    if (presets is! List || presets.any((e) => e is! num)) {
      throw const FormatException('interchain.json: slippagePresets');
    }
    final explorers = json['explorerTxUrls'];
    return SwapConfig(
      venueChainId: text('swapVenueChainId'),
      xcsContractCandidates: strings('xcsContractCandidates'),
      routerEndpoints: strings('swapRouterEndpoints'),
      defaultSlippagePercent: number('defaultSlippagePercent'),
      slippagePresets: List.unmodifiable(
        presets.cast<num>().map((e) => e.toDouble()),
      ),
      highSlippagePercent: number('highSlippagePercent'),
      maxSlippagePercent: number('maxSlippagePercent'),
      packetTimeoutMinutes: number('packetTimeoutMinutes').toInt(),
      maxRouteHops: number('maxRouteHops').toInt(),
      quoteTtl: Duration(milliseconds: number('quoteTtlMs').toInt()),
      explorerTxUrls: explorers is Map
          ? Map.unmodifiable({
              for (final e in explorers.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            })
          : const {},
    );
  }
}

/// `assets/data/swap-fee.json`: Zunia's commission.
///
/// Decided by the owner: 0.5% of the amount sold, taken in the same
/// transaction as the swap, in the token sold, paid to the Zunia treasury on
/// the chain that signs. A chain absent from [recipients] charges nothing and
/// signs exactly what it signed before the commission existed.
@immutable
class SwapFeeConfig {
  const SwapFeeConfig({required this.bps, required this.recipients});

  /// Basis points of the amount sold: 50 is 0.5%.
  final int bps;

  /// Treasury address by chain id, verbatim from the release.
  final Map<String, String> recipients;

  factory SwapFeeConfig.fromJson(Map<String, Object?> json) {
    final bps = json['bps'];
    final recipients = json['recipients'];
    if (bps is! int) throw const FormatException('swap-fee.json: bps');
    if (recipients is! Map) {
      throw const FormatException('swap-fee.json: recipients');
    }
    return SwapFeeConfig(
      bps: bps,
      recipients: Map.unmodifiable({
        for (final e in recipients.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      }),
    );
  }
}

/// Read both files from [bundle].
Future<(SwapConfig, SwapFeeConfig)> loadSwapConfig(AssetBundle bundle) async {
  final interchain = jsonDecode(
    await bundle.loadString('assets/data/interchain.json'),
  );
  final fee = jsonDecode(await bundle.loadString('assets/data/swap-fee.json'));
  if (interchain is! Map<String, Object?> || fee is! Map<String, Object?>) {
    throw const FormatException('assets/data: not a JSON object');
  }
  return (SwapConfig.fromJson(interchain), SwapFeeConfig.fromJson(fee));
}
