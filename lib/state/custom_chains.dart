/// User-added chains, persisted locally and merged into [ChainCatalog] so the
/// rest of the app cannot tell them apart from registry rows.
///
/// Stable API for other workstreams (the dApp browser's
/// `experimentalSuggestChain` in particular):
///
/// ```dart
/// final notifier = ref.read(customChainsProvider.notifier);
/// final entry = await notifier.addSuggested(chainInfoJson); // site's ChainInfo
/// final same  = await notifier.addDraft(draft);             // typed by a person
/// await notifier.add(chainEntry);                            // already-built row
/// await notifier.remove(chainId);
/// ```
///
/// Every add validates (https endpoints, prefix, denom, decimals, no registry
/// chain id), persists, and puts the chain in [ChainCatalog] before the future
/// completes, so a caller can enable the chain or derive an address on it
/// straight away. They throw [ChainDraftError] with a sentence fit to show.
/// None of them enables the chain: that stays the caller's decision
/// (`walletProvider.notifier.setEnabledChains`), because a site suggesting a
/// chain is not the user choosing to see it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/chains/chain_draft.dart';

export 'package:zunia_mobile/chains/chain_draft.dart'
    show ChainDraftError, CustomChainDraft, draftFromSuggestedChain;

const _kCustomChains = 'zunia.chains.custom';

/// Chain ids the bundled registry carries. Custom rows may never use one.
bool registryHasChainId(String chainId) =>
    ChainCatalog.isLoaded &&
    ChainCatalog.instance.registryOnly.any((c) => c.chainId == chainId);

/// The saved rows, in the order they were added.
///
/// A row whose chain id the registry now carries is dropped: it can only be
/// left over from a build that did not check, and keeping it would let a
/// user-typed endpoint shadow the registry's for that chain.
Future<List<ChainEntry>> readStoredCustomChains() async {
  final store = await SharedPreferences.getInstance();
  final raw = store.getString(_kCustomChains);
  if (raw == null) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final rows = <ChainEntry>[];
    final seen = <String>{};
    for (final value in decoded) {
      if (value is! Map) continue;
      try {
        final entry = ChainEntry.fromJson(value.cast<String, dynamic>());
        if (registryHasChainId(entry.chainId) || !seen.add(entry.chainId)) {
          continue;
        }
        rows.add(entry);
      } on Object {
        // One unreadable row must not cost the user the others.
      }
    }
    return rows;
  } on FormatException {
    return const [];
  }
}

/// Load saved custom chains into [ChainCatalog]. `main` calls this before the
/// first frame, after [ChainCatalog.load], so an address on a custom chain
/// derives on the very first build after a restart. Before this existed the
/// saved rows were only read when Add network was opened, so every custom
/// chain vanished from the wallet on restart.
Future<List<ChainEntry>> hydrateCustomChains() async {
  final rows = await readStoredCustomChains();
  if (ChainCatalog.isLoaded) ChainCatalog.instance.setCustom(rows);
  return rows;
}

class CustomChainsController extends StateNotifier<List<ChainEntry>> {
  CustomChainsController()
      : super(
          ChainCatalog.isLoaded
              ? ChainCatalog.instance.customOnly
              : const <ChainEntry>[],
        ) {
    _ready = _restore();
  }

  late final Future<void> _ready;

  /// Writes, one after another: each starts from the list the previous one
  /// left, so two adds in flight cannot drop each other's row.
  Future<void> _queue = Future<void>.value();

  /// Completes once the saved rows are loaded.
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    final rows = await readStoredCustomChains();
    if (!mounted) return;
    // The restore runs before any write can (writes await it), so this never
    // overwrites a chain added in the meantime. It used to race: an `add`
    // that landed before the read finished was replaced by the stored list.
    state = rows;
    if (ChainCatalog.isLoaded) ChainCatalog.instance.setCustom(rows);
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final next = _queue.then((_) => _ready).then((_) => task());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _persist(List<ChainEntry> rows) async {
    state = rows;
    if (ChainCatalog.isLoaded) ChainCatalog.instance.setCustom(rows);
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kCustomChains,
      jsonEncode([for (final row in rows) row.toJson()]),
    );
  }

  /// Validate and save a chain. Replaces an earlier custom row with the same
  /// chain id; refuses a registry chain id.
  Future<ChainEntry> addDraft(CustomChainDraft draft) async {
    final clean = validateCustomChainDraft(
      draft,
      isRegistryChainId: registryHasChainId,
    );
    return _store(clean.toEntry());
  }

  /// A site's `experimentalSuggestChain` payload (Keplr `ChainInfo`),
  /// validated exactly like a chain typed in by hand.
  Future<ChainEntry> addSuggested(Object? chainInfo) async =>
      addDraft(draftFromSuggestedChain(chainInfo));

  /// Save an already-built row. It goes through the same validation as a
  /// draft; only the fields a draft carries are kept from it.
  Future<ChainEntry> add(ChainEntry entry) async {
    final step = entry.gasPriceStep;
    return addDraft(
      CustomChainDraft(
        chainName: entry.chainName,
        chainId: entry.chainId,
        rpc: entry.rpc ?? '',
        rest: entry.rest ?? '',
        bech32Prefix: entry.bech32Prefix,
        coinType: entry.coinType,
        coinDenom: entry.coinDenom,
        coinMinimalDenom: entry.coinMinimalDenom,
        coinDecimals: entry.coinDecimals,
        gasPrice: step?['average'] ?? step?['low'] ?? defaultCustomGasPrice,
        testnet: entry.isTestnet,
      ),
    );
  }

  Future<ChainEntry> _store(ChainEntry entry) => _serial(() async {
        await _persist([
          ...state.where((e) => e.chainId != entry.chainId),
          entry,
        ]);
        return entry;
      });

  /// Forget a custom chain. Disabling it is the caller's job.
  Future<void> remove(String chainId) => _serial(
        () => _persist(state.where((e) => e.chainId != chainId).toList()),
      );

  bool isCustom(String chainId) => state.any((e) => e.chainId == chainId);
}

final customChainsProvider =
    StateNotifierProvider<CustomChainsController, List<ChainEntry>>(
  (ref) => CustomChainsController(),
);
