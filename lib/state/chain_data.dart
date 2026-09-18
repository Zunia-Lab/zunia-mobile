/// Riverpod wiring on top of [ChainClient].
///
/// Every family here returns empty data rather than throwing when live reads
/// are off, so screens render their "reads are off" state instead of an error.
library;

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

final chainClientProvider = Provider<ChainClient>((ref) {
  final client = ChainClient(
    enabled: ref.watch(preferencesProvider.select((p) => p.liveReads)),
  );
  ref.onDispose(client.close);
  return client;
});

/// What [balancesProvider] hands to screens: the chains that answered, plus
/// the reason for each chain that is missing.
///
/// A chain whose read failed is absent from the map instead of present with
/// zeros. Every screen already renders an absent chain as '—', while a zero
/// reads as "this account is empty" - a claim the wallet cannot make when the
/// endpoint never answered. It stays a plain `Map<String, ChainBalance>` so
/// screens that only need the numbers are unaffected; [failures] rides along
/// for the screens that must show why a number is missing.
class BalanceReads extends UnmodifiableMapView<String, ChainBalance> {
  BalanceReads(super.values, this.failures);

  /// Keyed by chain id, for chains absent from this map.
  final Map<String, ChainReadFailure> failures;

  static final BalanceReads empty = BalanceReads(const {}, const {});
}

/// Balances for every enabled chain of the active account.
final balancesProvider = FutureProvider<Map<String, ChainBalance>>((ref) async {
  final client = ref.watch(chainClientProvider);
  final accounts = ref.watch(chainAccountsProvider);
  if (accounts.isEmpty) return BalanceReads.empty;
  if (!client.enabled) {
    return BalanceReads(const {}, {
      for (final a in accounts)
        a.chain.chainId:
            const ChainReadFailure(ChainReadFailureKind.readsDisabled),
    });
  }

  final entries = await Future.wait(
    accounts.map(
      (a) async =>
          MapEntry(a.chain.chainId, await client.balance(a.chain, a.address)),
    ),
  );

  final values = <String, ChainBalance>{};
  final failures = <String, ChainReadFailure>{};
  for (final entry in entries) {
    switch (entry.value) {
      case BalanceLoaded(:final balance):
        values[entry.key] = balance;
      case BalanceUnavailable(:final failure):
        failures[entry.key] = failure;
    }
  }
  return BalanceReads(values, failures);
});

/// Why a chain is missing from [balancesProvider], keyed by chain id.
///
/// Empty while the read is still in flight - "not read yet" is the provider's
/// loading state, not a failure.
final balanceFailuresProvider =
    Provider<Map<String, ChainReadFailure>>((ref) {
  final reads = ref.watch(balancesProvider).valueOrNull;
  return reads is BalanceReads ? reads.failures : const {};
});

ChainEntry? _chain(String chainId) =>
    ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;

String? _addressFor(Ref ref, String chainId) {
  for (final account in ref.watch(chainAccountsProvider)) {
    if (account.chain.chainId == chainId) return account.address;
  }
  return null;
}

final validatorsProvider =
    FutureProvider.family<List<ValidatorInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  if (chain == null) return const [];
  return ref.watch(chainClientProvider).validators(chain);
});

final delegationsProvider =
    FutureProvider.family<List<DelegationInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  return ref.watch(chainClientProvider).delegations(chain, address);
});

final unbondingProvider =
    FutureProvider.family<List<UnbondingInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  return ref.watch(chainClientProvider).unbonding(chain, address);
});

final proposalsProvider =
    FutureProvider.family<List<ProposalInfo>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  if (chain == null) return const [];
  return ref.watch(chainClientProvider).proposals(chain);
});

final activityProvider =
    FutureProvider.family<List<ActivityItem>, String>((ref, chainId) async {
  final chain = _chain(chainId);
  final address = _addressFor(ref, chainId);
  if (chain == null || address == null) return const [];
  return ref.watch(chainClientProvider).activity(chain, address);
});

/// Activity merged across every enabled chain, newest first.
final allActivityProvider = FutureProvider<List<ActivityItem>>((ref) async {
  final client = ref.watch(chainClientProvider);
  final accounts = ref.watch(chainAccountsProvider);
  if (!client.enabled || accounts.isEmpty) return const [];

  final batches = await Future.wait(
    accounts.map((a) => client.activity(a.chain, a.address, limit: 10)),
  );
  final merged = batches.expand((b) => b).toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return merged;
});
