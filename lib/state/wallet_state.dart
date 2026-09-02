/// Non-secret wallet metadata plus the derived addresses for the unlocked session.
///
/// The recovery phrase lives only in [phraseProvider] for as long as the app is
/// unlocked. Everything persisted here (account names, indices, which chains are
/// enabled) is safe to keep in plain SharedPreferences.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';

@immutable
class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.index,
  });

  factory WalletAccount.fromJson(Map<String, dynamic> json) => WalletAccount(
        id: json['id'] as String,
        name: json['name'] as String,
        index: (json['index'] as num).toInt(),
      );

  final String id;
  final String name;

  /// BIP-44 account index; the derivation path segment that makes this account
  /// distinct from its siblings under the same phrase.
  final int index;

  String get initial => name.trim().isEmpty ? 'W' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'index': index};

  WalletAccount copyWith({String? name}) =>
      WalletAccount(id: id, name: name ?? this.name, index: index);
}

@immutable
class WalletData {
  const WalletData({
    this.accounts = const [],
    this.activeId,
    this.enabledChainIds = const ['safrochain-1'],
    this.loaded = false,
  });

  final List<WalletAccount> accounts;
  final String? activeId;
  final List<String> enabledChainIds;
  final bool loaded;

  WalletAccount? get active {
    if (accounts.isEmpty) return null;
    for (final a in accounts) {
      if (a.id == activeId) return a;
    }
    return accounts.first;
  }

  WalletData copyWith({
    List<WalletAccount>? accounts,
    String? activeId,
    List<String>? enabledChainIds,
    bool? loaded,
  }) {
    return WalletData(
      accounts: accounts ?? this.accounts,
      activeId: activeId ?? this.activeId,
      enabledChainIds: enabledChainIds ?? this.enabledChainIds,
      loaded: loaded ?? this.loaded,
    );
  }
}

const _kAccounts = 'zunia.wallet.accounts';
const _kActive = 'zunia.wallet.activeAccount';
const _kChains = 'zunia.wallet.enabledChains';

class WalletController extends StateNotifier<WalletData> {
  WalletController() : super(const WalletData()) {
    _restore();
  }

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final rawAccounts = store.getString(_kAccounts);
    final accounts = rawAccounts == null
        ? <WalletAccount>[]
        : (jsonDecode(rawAccounts) as List<dynamic>)
            .map((e) => WalletAccount.fromJson(e as Map<String, dynamic>))
            .toList();
    state = WalletData(
      accounts: accounts,
      activeId: store.getString(_kActive),
      enabledChainIds:
          store.getStringList(_kChains) ?? const ['safrochain-1'],
      loaded: true,
    );
  }

  Future<void> _persist(WalletData next) async {
    state = next;
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kAccounts,
      jsonEncode(next.accounts.map((a) => a.toJson()).toList()),
    );
    if (next.activeId != null) await store.setString(_kActive, next.activeId!);
    await store.setStringList(_kChains, next.enabledChainIds);
  }

  /// Called once when a vault is created or restored.
  Future<void> initialise({
    required String walletName,
    required List<String> enabledChainIds,
  }) async {
    final account = WalletAccount(
      id: 'acct-0',
      name: walletName.trim().isEmpty ? 'Main' : walletName.trim(),
      index: 0,
    );
    await _persist(
      WalletData(
        accounts: [account],
        activeId: account.id,
        enabledChainIds:
            enabledChainIds.isEmpty ? const ['safrochain-1'] : enabledChainIds,
        loaded: true,
      ),
    );
  }

  Future<void> addAccount(String name) async {
    final nextIndex = state.accounts.isEmpty
        ? 0
        : state.accounts.map((a) => a.index).reduce((a, b) => a > b ? a : b) + 1;
    final account = WalletAccount(
      id: 'acct-$nextIndex',
      name: name.trim().isEmpty ? 'Account ${nextIndex + 1}' : name.trim(),
      index: nextIndex,
    );
    await _persist(
      state.copyWith(
        accounts: [...state.accounts, account],
        activeId: account.id,
      ),
    );
  }

  Future<void> renameAccount(String id, String name) async {
    await _persist(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            if (a.id == id) a.copyWith(name: name) else a,
        ],
      ),
    );
  }

  Future<void> selectAccount(String id) async {
    await _persist(state.copyWith(activeId: id));
  }

  Future<void> setEnabledChains(List<String> chainIds) async {
    await _persist(
      state.copyWith(
        enabledChainIds: chainIds.isEmpty ? const ['safrochain-1'] : chainIds,
      ),
    );
  }

  Future<void> toggleChain(String chainId) async {
    final next = [...state.enabledChainIds];
    if (!next.remove(chainId)) next.add(chainId);
    await setEnabledChains(next);
  }

  Future<void> clear() async {
    final store = await SharedPreferences.getInstance();
    await store.remove(_kAccounts);
    await store.remove(_kActive);
    await store.remove(_kChains);
    state = const WalletData(loaded: true);
  }
}

final walletProvider =
    StateNotifierProvider<WalletController, WalletData>(
  (ref) => WalletController(),
);

/// Recovery phrase for the unlocked session. Null while locked; never persisted.
final phraseProvider = StateProvider<String?>((ref) => null);

@immutable
class ChainAccount {
  const ChainAccount({required this.chain, required this.address});

  final ChainEntry chain;
  final String address;
}

/// Address per enabled chain for the active account.
final chainAccountsProvider = Provider<List<ChainAccount>>((ref) {
  final phrase = ref.watch(phraseProvider);
  final wallet = ref.watch(walletProvider);
  final account = wallet.active;
  if (phrase == null || account == null || !ChainCatalog.isLoaded) {
    return const [];
  }

  final catalog = ChainCatalog.instance;
  final kernel = WalletKernel.instance;
  final out = <ChainAccount>[];
  for (final chainId in wallet.enabledChainIds) {
    final chain = catalog.find(chainId);
    if (chain == null) continue;
    try {
      final derived = kernel.deriveAddress(
        phrase: phrase,
        chain: chain,
        accountIndex: account.index,
      );
      out.add(ChainAccount(chain: chain, address: derived.address));
    } catch (_) {
      // A single unusable chain entry should not blank the whole list.
    }
  }
  return out;
});

/// Primary address shown in headers: the first enabled chain, pinned order.
final primaryAddressProvider = Provider<String?>((ref) {
  final accounts = ref.watch(chainAccountsProvider);
  return accounts.isEmpty ? null : accounts.first.address;
});
