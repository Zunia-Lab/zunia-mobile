/// The one way to claim staking rewards, from the Earn tab, the Rewards
/// screen or a validator's page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/ui/tx_flow.dart';

/// Reviews and sends the first claim for [positions] on [chain]. Does nothing
/// when there is nothing to claim. Staking and balances are read again once
/// the claim settles, whatever its outcome.
Future<void> reviewClaim(
  BuildContext context,
  WidgetRef ref, {
  required ChainEntry chain,
  required String delegator,
  required List<StakingPosition> positions,
}) async {
  final plan = claimPlan(delegator: delegator, positions: positions);
  if (plan.isEmpty) return;
  final sameDenom = chain.feeMinimalDenom.isEmpty ||
      chain.feeMinimalDenom == chain.coinMinimalDenom;
  final included = plan.included;
  await showTxReview(
    context,
    TxIntent(
      title: 'Claim rewards',
      action: 'Sign claim',
      chain: chain,
      signer: delegator,
      msgs: plan.msgs,
      headlineLabel: 'You claim',
      headline: '≈ ${stakeAmount(plan.total, chain, digits: 6)}',
      headlineLine: included.length == 1
          ? 'From ${included.first.moniker} · ${chain.chainName}'
          : 'From ${included.length} validators · ${chain.chainName}',
      facts: included.length == 1
          ? const []
          : [
              for (final p in included)
                (label: p.moniker, value: stakeAmount(p.rewards!, chain, digits: 6)),
            ],
      notice: plan.remaining > 0
          ? 'This claims from the ${included.length} validators with the most '
              'rewards. Claim again for the other ${plan.remaining}: one '
              'transaction holding them all could run past the network\'s gas limit.'
          : null,
      gainBaseUnits: sameDenom ? plan.total : null,
      offerNotifications: true,
      result: const TxResultCopy(
        sending: 'Claiming rewards',
        done: 'Rewards claimed',
        failed: 'Claim failed',
        doneMessage: 'The rewards are in your available balance.',
      ),
      onSettled: () {
        refreshStaking(ref, chain.chainId);
        ref.invalidate(balancesProvider);
      },
    ),
  );
}
