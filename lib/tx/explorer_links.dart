/// Block explorer links for a transaction, from the extension's own table
/// (`explorerTxUrls` in assets/data/interchain.json, synced from extension
/// 0.1.5). A chain the table does not list gets no link: a guessed explorer
/// domain would be worse than none.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

Map<String, String>? _templates;

@visibleForTesting
set debugExplorerTemplates(Map<String, String>? value) => _templates = value;

Future<Map<String, String>> _load() async {
  try {
    final raw = await rootBundle.loadString('assets/data/interchain.json');
    final decoded = jsonDecode(raw);
    final table = decoded is Map ? decoded['explorerTxUrls'] : null;
    if (table is! Map) return const {};
    return {
      for (final entry in table.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).startsWith('https://') &&
            (entry.value as String).contains('{hash}'))
          entry.key as String: entry.value as String,
    };
  } on Object {
    return const {};
  }
}

/// The explorer page for [hash] on [chainId], or null when none is known.
Future<Uri?> explorerTxUrl(String chainId, String hash) async {
  final templates = _templates ??= await _load();
  final template = templates[chainId];
  if (template == null || hash.isEmpty) return null;
  return Uri.tryParse(template.replaceAll('{hash}', Uri.encodeComponent(hash)));
}
