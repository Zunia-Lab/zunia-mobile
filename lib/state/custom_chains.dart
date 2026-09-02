/// User-added chains, persisted locally and merged into [ChainCatalog] so the
/// rest of the app cannot tell them apart from registry rows.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';

const _kCustomChains = 'zunia.chains.custom';

class CustomChainsController extends StateNotifier<List<ChainEntry>> {
  CustomChainsController() : super(const []) {
    _restore();
  }

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kCustomChains);
    if (raw == null) return;
    final rows = (jsonDecode(raw) as List<dynamic>)
        .map((e) => ChainEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    state = rows;
    if (ChainCatalog.isLoaded) ChainCatalog.instance.setCustom(rows);
  }

  Future<void> _persist(List<ChainEntry> rows) async {
    state = rows;
    if (ChainCatalog.isLoaded) ChainCatalog.instance.setCustom(rows);
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kCustomChains,
      jsonEncode(rows.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> add(ChainEntry entry) =>
      _persist([...state.where((e) => e.chainId != entry.chainId), entry]);

  Future<void> remove(String chainId) =>
      _persist(state.where((e) => e.chainId != chainId).toList());
}

final customChainsProvider =
    StateNotifierProvider<CustomChainsController, List<ChainEntry>>(
  (ref) => CustomChainsController(),
);
