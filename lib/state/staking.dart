/// Riverpod wiring for staking, and the messages Stake, Unstake and Claim
/// sign.
///
/// The providers throw [ChainReadError] when a read fails, so a screen can say
/// "the endpoint did not answer" instead of "you have no stake". With live
/// reads off they return nothing and the screens show that state first.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

/// One read client for staking, governance and notices, gated on live reads.
final chainReaderProvider = Provider<ChainReader>((ref) {
  final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
  return ChainReader(readsAllowed: () => live);
});

final stakingClientProvider = Provider<StakingClient>(
  (ref) => StakingClient(ref.watch(chainReaderProvider)),
);

ChainEntry? catalogChain(String chainId) =>
    ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null;

/// The active account's address on [chainId], when that chain is enabled.
String? activeAddressOn(Ref ref, String chainId) {
  for (final account in ref.watch(chainAccountsProvider)) {
    if (account.chain.chainId == chainId) return account.address;
  }
  return null;
}

ChainEntry _requireChain(String chainId) {
  final chain = catalogChain(chainId);
  if (chain == null) {
    throw ChainReadError(ChainReadErrorKind.noEndpoint, '$chainId is unknown');
  }
  return chain;
}

/// The bonded set of a chain, strongest first.
final stakingValidatorsProvider =
    FutureProvider.family<List<StakingValidator>, String>((ref, chainId) async {
  final client = ref.watch(stakingClientProvider);
  final chain = _requireChain(chainId);
  return client.validators(chain);
});

/// Validators by operator address, from the bonded set. Waiting for the set
/// (which the Earn tab loads anyway) saves one validator read per position;
/// when the set will not load, positions still load with addresses for names.
Future<Map<String, StakingValidator>> _knownValidators(
  Ref ref,
  String chainId,
) async {
  try {
    final rows = await ref.watch(stakingValidatorsProvider(chainId).future);
    return {for (final v in rows) v.operatorAddress: v};
  } on Object {
    return const {};
  }
}

/// The active account's delegations on [chainId], largest first.
final stakingPositionsProvider =
    FutureProvider.family<List<StakingPosition>, String>((ref, chainId) async {
  final client = ref.watch(stakingClientProvider);
  final address = activeAddressOn(ref, chainId);
  final chain = _requireChain(chainId);
  if (address == null) return const [];
  final known = await _knownValidators(ref, chainId);
  return client.positions(chain, address, known: known);
});

/// The active account's unbonding entries on [chainId], soonest first.
final stakingUnbondingProvider =
    FutureProvider.family<List<UnbondingEntry>, String>((ref, chainId) async {
  final client = ref.watch(stakingClientProvider);
  final address = activeAddressOn(ref, chainId);
  final chain = _requireChain(chainId);
  if (address == null) return const [];
  final known = await _knownValidators(ref, chainId);
  return client.unbonding(chain, address, known: known);
});

final stakingParamsProvider =
    FutureProvider.family<StakingParams, String>((ref, chainId) async {
  return ref.watch(stakingClientProvider).params(_requireChain(chainId));
});

/// Null when the APR cannot be worked out honestly for this chain.
final stakingAprProvider =
    FutureProvider.family<AprEstimate?, String>((ref, chainId) async {
  final client = ref.watch(stakingClientProvider);
  final chain = _requireChain(chainId);
  String? bondDenom;
  try {
    bondDenom = (await ref.watch(stakingParamsProvider(chainId).future)).bondDenom;
  } on Object {
    bondDenom = null;
  }
  return client.apr(chain, bondDenom: bondDenom);
});

/// One validator, from the loaded set or read on its own.
final stakingValidatorProvider = FutureProvider.family<StakingValidator,
    ({String chainId, String operator})>((ref, key) async {
  final known = ref
      .watch(stakingValidatorsProvider(key.chainId))
      .valueOrNull
      ?.where((v) => v.operatorAddress == key.operator)
      .firstOrNull;
  if (known != null) return known;
  return ref
      .watch(stakingClientProvider)
      .validator(_requireChain(key.chainId), key.operator);
});

/// Re-read everything staking shows for [chainId], after a transaction or a
/// pull to refresh.
void refreshStaking(WidgetRef ref, String chainId) {
  ref.invalidate(stakingPositionsProvider(chainId));
  ref.invalidate(stakingUnbondingProvider(chainId));
  ref.invalidate(stakingValidatorsProvider(chainId));
}

/* -------------------------------------------------------------------------- *
 * Messages
 * -------------------------------------------------------------------------- */

/// Rewards claimed per transaction at most. One message per validator; a few
/// dozen in one transaction can run past a node's gas cap or a block's, and a
/// failed claim costs the whole fee, so a long list goes in several.
const maxClaimsPerTx = 20;

List<TxMsg> stakeMsgs({
  required String delegator,
  required String validator,
  required String denom,
  required BigInt amount,
}) {
  if (amount <= BigInt.zero) throw ArgumentError('Stake a positive amount');
  return [
    TxMsg.delegate(
      delegator: delegator,
      validator: validator,
      amount: TxCoin(denom, amount.toString()),
    ),
  ];
}

List<TxMsg> unstakeMsgs({
  required String delegator,
  required String validator,
  required String denom,
  required BigInt amount,
}) {
  if (amount <= BigInt.zero) throw ArgumentError('Unstake a positive amount');
  return [
    TxMsg.undelegate(
      delegator: delegator,
      validator: validator,
      amount: TxCoin(denom, amount.toString()),
    ),
  ];
}

/// Positions with something to claim, largest reward first, split into
/// transactions of at most [maxPerTx] messages. A position whose rewards are
/// unknown or zero is left out: withdrawing nothing still costs gas.
List<List<TxMsg>> claimMsgBatches({
  required String delegator,
  required List<StakingPosition> positions,
  int maxPerTx = maxClaimsPerTx,
}) {
  final claimable = positions
      .where((p) => (p.rewards ?? BigInt.zero) > BigInt.zero)
      .toList()
    ..sort((a, b) => b.rewards!.compareTo(a.rewards!));
  final batches = <List<TxMsg>>[];
  for (var i = 0; i < claimable.length; i += maxPerTx) {
    batches.add([
      for (final p in claimable.skip(i).take(maxPerTx))
        TxMsg.withdrawReward(
          delegator: delegator,
          validator: p.validatorAddress,
        ),
    ]);
  }
  return batches;
}

/// Total rewards across [positions] that can be claimed; null when any
/// position's rewards are unknown, since a partial sum would understate it.
BigInt? claimableTotal(List<StakingPosition> positions) {
  var total = BigInt.zero;
  for (final p in positions) {
    final r = p.rewards;
    if (r == null) return null;
    total += r;
  }
  return total;
}

/// What to hold back from a MAX stake for the fee, when the fee is paid in
/// the coin being staked. A guess before simulation, so it is generous: the
/// fallback gas at the high price.
BigInt feeReserveFor(ChainEntry chain) {
  final feeDenom = chain.feeMinimalDenom.isEmpty
      ? chain.coinMinimalDenom
      : chain.feeMinimalDenom;
  if (feeDenom != chain.coinMinimalDenom) return BigInt.zero;
  final fee = TxEngine.feeFor(chain, fallbackGasLimit, FeeSpeed.high);
  if (fee.amount.isEmpty) return BigInt.zero;
  return BigInt.tryParse(fee.amount.first.amount) ?? BigInt.zero;
}

/// The most that can be staked from [available], after [reserve].
BigInt maxStakeable(BigInt available, BigInt reserve) {
  final max = available - reserve;
  return max > BigInt.zero ? max : BigInt.zero;
}
