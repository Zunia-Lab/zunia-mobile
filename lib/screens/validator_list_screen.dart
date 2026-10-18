import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/screens/validator_detail_screen.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/ui/facts.dart';
import 'package:zunia_mobile/ui/option_sheet.dart';
import 'package:zunia_mobile/widgets/validator_avatar.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum ValidatorSort { power, commission, name, myStake }

extension ValidatorSortLabel on ValidatorSort {
  String get label => switch (this) {
        ValidatorSort.power => 'Voting power',
        ValidatorSort.commission => 'Lowest commission',
        ValidatorSort.name => 'Name',
        ValidatorSort.myStake => 'Your stake',
      };
}

/// Order and filter the bonded set. Pure, for the list and its tests.
List<StakingValidator> arrangeValidators(
  List<StakingValidator> rows, {
  String query = '',
  ValidatorSort sort = ValidatorSort.power,
  Map<String, BigInt> myStake = const {},
}) {
  final out = rows.where((v) => v.matches(query)).toList();
  int byPower(StakingValidator a, StakingValidator b) =>
      b.tokens.compareTo(a.tokens);
  switch (sort) {
    case ValidatorSort.power:
      out.sort(byPower);
    case ValidatorSort.commission:
      out.sort((a, b) {
        final c = a.commission.compareTo(b.commission);
        return c != 0 ? c : byPower(a, b);
      });
    case ValidatorSort.name:
      out.sort(
        (a, b) => a.moniker.toLowerCase().compareTo(b.moniker.toLowerCase()),
      );
    case ValidatorSort.myStake:
      out.sort((a, b) {
        final c = (myStake[b.operatorAddress] ?? BigInt.zero)
            .compareTo(myStake[a.operatorAddress] ?? BigInt.zero);
        return c != 0 ? c : byPower(a, b);
      });
  }
  return out;
}

/// The bonded validators of one network: search, sort, open one to stake.
class ValidatorListScreen extends ConsumerStatefulWidget {
  const ValidatorListScreen({super.key, required this.chainId});

  final String chainId;

  @override
  ConsumerState<ValidatorListScreen> createState() =>
      _ValidatorListScreenState();
}

class _ValidatorListScreenState extends ConsumerState<ValidatorListScreen> {
  final _search = TextEditingController();
  String _query = '';
  ValidatorSort _sort = ValidatorSort.power;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickSort() async {
    final next = await pickOption<ValidatorSort>(
      context,
      title: 'Sort validators',
      selected: _sort,
      options: [
        for (final sort in ValidatorSort.values) (value: sort, label: sort.label),
      ],
    );
    if (next != null && mounted) setState(() => _sort = next);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = catalogChain(widget.chainId);
    final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
    final hide = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
    final validators =
        live ? ref.watch(stakingValidatorsProvider(widget.chainId)) : null;
    final positions = live
        ? ref.watch(stakingPositionsProvider(widget.chainId)).valueOrNull
        : null;
    final myStake = {
      for (final p in positions ?? const <StakingPosition>[])
        p.validatorAddress: p.amount,
    };

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: chain == null ? 'Stake' : 'Stake on ${chain.chainName}',
          onBack: () => Navigator.of(context).maybePop(),
          trailing: Semantics(
            button: true,
            label: 'Sort: ${_sort.label}',
            child: IconButton(
              tooltip: 'Sort',
              onPressed: _pickSort,
              icon: Icon(Icons.sort_rounded, color: s.fg),
            ),
          ),
          body: chain == null
              ? const ZuniaEmptyState(title: 'Unknown network')
              : !live
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: ZuniaCallout(
                        title: 'Live reads are off',
                        body: 'The validator set comes from the network\'s '
                            'public endpoint. Turn live reads on in '
                            'Preferences to load it.',
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                          child: ZuniaSearchField(
                            controller: _search,
                            hintText: 'Search name or address',
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                          child: Text(
                            'Sorted by ${_sort.label.toLowerCase()}. Spreading '
                            'stake beyond the largest validators keeps the '
                            'network harder to capture.',
                            style: zuniaSans(fontSize: 12, color: s.fgDim),
                          ),
                        ),
                        Expanded(
                          child: validators!.when(
                            skipLoadingOnRefresh: true,
                            loading: () => const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: ListSkeleton(
                                rows: 8,
                                label: 'Loading validators',
                              ),
                            ),
                            error: (e, _) => ZuniaEmptyState(
                              title: 'Could not load validators',
                              description: e is ChainReadError
                                  ? e.userMessage
                                  : 'The endpoint did not answer.',
                              action: ZuniaButton(
                                label: 'Try again',
                                size: ZuniaButtonSize.sm,
                                variant: ZuniaButtonVariant.secondary,
                                onPressed: () => ref.invalidate(
                                  stakingValidatorsProvider(widget.chainId),
                                ),
                              ),
                            ),
                            data: (rows) {
                              final shown = arrangeValidators(
                                rows,
                                query: _query,
                                sort: _sort,
                                myStake: myStake,
                              );
                              if (rows.isEmpty) {
                                return const ZuniaEmptyState(
                                  title: 'No validator set',
                                  description: 'The endpoint did not return '
                                      'a bonded validator set.',
                                );
                              }
                              if (shown.isEmpty) {
                                return ZuniaEmptyState(
                                  title: 'No match',
                                  description: 'No validator matches '
                                      '“${_query.trim()}”.',
                                );
                              }
                              return ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 4, 12, 32),
                                itemCount: shown.length,
                                itemBuilder: (_, i) => _ValidatorRow(
                                  chain: chain,
                                  validator: shown[i],
                                  rank: rows.indexOf(shown[i]) + 1,
                                  stake: myStake[shown[i].operatorAddress],
                                  hide: hide,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ValidatorDetailScreen(
                                        chainId: widget.chainId,
                                        operatorAddress:
                                            shown[i].operatorAddress,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}

class _ValidatorRow extends StatelessWidget {
  const _ValidatorRow({
    required this.chain,
    required this.validator,
    required this.rank,
    required this.stake,
    required this.hide,
    required this.onTap,
  });

  final ChainEntry chain;
  final StakingValidator validator;
  final int rank;
  final BigInt? stake;
  final bool hide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final v = validator;
    final held = stake != null && stake! > BigInt.zero;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '$rank',
                  style: zuniaMono(fontSize: 11, color: s.fgDim),
                ),
              ),
              CachedValidatorAvatar(
                chainId: chain.chainId,
                chainName: chain.chainName,
                operatorAddress: v.operatorAddress,
                identity: v.identity,
                moniker: v.moniker,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            v.moniker,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: s.fg,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        StakingBadge(v.bondState),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${percent(v.commission, digits: v.commission < 0.1 ? 1 : 0)} '
                      'commission · ${percent(v.votingPower, digits: 2)} power',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                    ),
                  ],
                ),
              ),
              if (held) ...[
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      hide ? '••••' : stakeAmount(stake!, chain, digits: 2),
                      style: zuniaMono(fontSize: 12.5, color: s.fg),
                    ),
                    Text(
                      'yours',
                      style: zuniaMono(fontSize: 10, color: s.fgDim),
                    ),
                  ],
                ),
              ],
              if (ZuniaPlatform.isCupertino(context)) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: s.fgFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
