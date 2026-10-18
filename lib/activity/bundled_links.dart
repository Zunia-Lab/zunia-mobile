/// Explorer links and Zunia's swap-fee treasuries, from the data the
/// extension compiles in (`assets/data/interchain.json`,
/// `assets/data/swap-fee.json`).
///
/// Both are read-only facts for display: an explorer template turns a hash
/// into a link, and a treasury address lets history read a swap's fee as
/// "Zunia fee" instead of a send to a stranger. A chain missing from the
/// explorer table keeps its hash as selectable text; a guessed domain would be
/// worse than none.
library;

import 'dart:convert';

import 'package:bech32/bech32.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:zunia_mobile/chains/chain_catalog.dart';

Map<String, String> _explorers = const {};
Map<String, String> _treasuries = const {};
Map<String, String>? _validTreasuries;
bool _loaded = false;

/// Reads both assets once. Never throws: without them, hashes stay text and
/// no send reads as a fee.
Future<void> loadBundledLinks() async {
  if (_loaded) return;
  try {
    final interchain = jsonDecode(await rootBundle.loadString('assets/data/interchain.json'));
    final fees = jsonDecode(await rootBundle.loadString('assets/data/swap-fee.json'));
    setBundledLinks(
      explorers: _stringMap(interchain is Map ? interchain['explorerTxUrls'] : null),
      treasuries: _stringMap(fees is Map ? fees['recipients'] : null),
    );
  } on Object {
    _loaded = true;
  }
}

Map<String, String> _stringMap(Object? raw) => raw is Map
    ? {
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is String) key: value,
      }
    : const {};

@visibleForTesting
void setBundledLinks({
  Map<String, String> explorers = const {},
  Map<String, String> treasuries = const {},
}) {
  _explorers = explorers;
  _treasuries = treasuries;
  _validTreasuries = null;
  _loaded = true;
}

/// Explorer URL for a hash, or null when no explorer is known for the chain.
String? explorerTxUrl(String chainId, String txHash) {
  final template = _explorers[chainId];
  if (template == null || txHash.isEmpty) return null;
  return template.replaceAll('{hash}', Uri.encodeComponent(txHash));
}

/// Treasury addresses that pass the extension's own check: a lowercase bech32
/// address under the chain's catalog prefix. Anything else reads as an
/// ordinary send.
Map<String, String> get swapFeeRecipients {
  final cached = _validTreasuries;
  if (cached != null) return cached;
  final out = <String, String>{};
  for (final MapEntry(:key, :value) in _treasuries.entries) {
    if (swapFeeRecipientProblem(key, value) == null) out[key] = value;
  }
  // Only cached once the catalog could vouch for the prefixes.
  if (ChainCatalog.isLoaded) _validTreasuries = out;
  return out;
}

/// Why [address] cannot be [chainId]'s treasury, or null when it can.
String? swapFeeRecipientProblem(String chainId, String address) {
  final entry = ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;
  if (entry == null) return '$chainId is not a chain this release bundles.';
  if (address != address.toLowerCase()) return '$address is not in lowercase.';
  try {
    final decoded = const Bech32Codec().decode(address, address.length);
    if (decoded.hrp != entry.bech32Prefix) {
      return '$address carries the prefix ${decoded.hrp}, not ${entry.bech32Prefix}.';
    }
  } on Object {
    return '$address is not a valid bech32 address.';
  }
  return null;
}
