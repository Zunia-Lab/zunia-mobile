/// Planning one cross-chain transfer (no swap).
///
/// The same engine the swap screen uses, with swapping turned off: discover the
/// channels, work out whether the token should unwind rather than wrap again,
/// and compose the one transfer the user signs — plus a packet-forward memo when
/// no direct channel exists. The screen that used to hand-roll all of this now
/// only renders what comes back.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/interchain_config.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/denom.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';
import 'package:zunia_mobile/services/interchain/registry.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';

/// What the cross-send screen renders.
@immutable
class TransferPlanState {
  const TransferPlanState({
    this.planning = false,
    this.candidate,
    this.options = const [],
    this.warnings = const [],
    this.blockedReason,
    this.planError,
    this.denomAdvice,
    this.memoInspection,
  });

  final bool planning;
  final RoutePlanCandidate? candidate;

  /// Channels discovered for the first hop. Empty is a normal state on a chain
  /// with a slow or partial LCD, and is exactly when the manual field matters.
  final List<IbcChannelOption> options;

  final List<String> warnings;

  /// Why there is nothing to review yet. Always specific.
  final String? blockedReason;

  final String? planError;
  final DenomRecommendation? denomAdvice;

  /// What the memo will do. Empty-memo transfers report `MemoKind.empty`.
  final MemoInspection? memoInspection;

  bool get ready => candidate != null && blockedReason == null && planError == null;
}

/// Plans a cross-chain transfer. One instance per recipient screen.
class TransferPlanController extends StateNotifier<TransferPlanState> {
  TransferPlanController(this._ref) : super(const TransferPlanState());

  final Ref _ref;
  /// Channels the user typed, keyed by hop index.
  ///
  /// The chain pair rides along because an override has two jobs: replacing the
  /// channel the search picked, and being the edge when discovery found nothing
  /// at all. Only the second job needs the pair, and it is the job that matters
  /// on a chain whose endpoint cannot list its channels.
  final Map<int, RouteHopOverride> _overrides = {};
  int _generation = 0;

  String? overrideFor(int hopIndex) => _overrides[hopIndex]?.channelId;

  void setOverride(
    int hopIndex,
    String channelId, {
    String? fromChainId,
    String? toChainId,
  }) {
    final normalized = normalizeChannelId(channelId);
    if (normalized.isEmpty) {
      _overrides.remove(hopIndex);
      return;
    }
    _overrides[hopIndex] = RouteHopOverride(
      hopIndex: hopIndex,
      channelId: normalized,
      fromChainId: fromChainId,
      toChainId: toChainId,
    );
  }

  Future<void> plan({
    required String sourceChainId,
    required String destChainId,
    required String inputDenom,
    required String amountBaseUnits,
    required String sender,
    required String recipient,
    String? phrase,
    int accountIndex = 0,
  }) async {
    final generation = ++_generation;
    void publish(TransferPlanState next) {
      if (_generation == generation && mounted) state = next;
    }

    if (recipient.isEmpty) {
      publish(const TransferPlanState(
        blockedReason: 'Enter a recipient address.',
      ));
      return;
    }
    if (BigInt.tryParse(amountBaseUnits) == null ||
        BigInt.parse(amountBaseUnits) == BigInt.zero) {
      publish(const TransferPlanState(
        blockedReason: 'Enter an amount greater than zero.',
      ));
      return;
    }

    publish(const TransferPlanState(planning: true));

    final registry = _ref.read(interchainRegistryProvider);
    final channels = _ref.read(channelServiceProvider);
    final routes = _ref.read(routeRegistryProvider);
    final capabilities = _ref.read(chainCapabilityCacheProvider);

    List<IbcChannelOption> options = const [];
    try {
      options = await channels.findIbcChannels(sourceChainId, destChainId);
      await routes.remember([
        for (final option in options)
          ChannelRoute(
            sourceChainId: sourceChainId,
            destChainId: destChainId,
            channelId: option.channelId,
            counterpartyChannelId: option.counterpartyChannelId,
            verifiedAt: DateTime.now().millisecondsSinceEpoch,
            source: ChannelRouteSource.discovered,
          ),
      ]);
    } on InterchainError {
      // Discovery failing is not fatal: a seed row or a hand-typed channel is
      // enough to plan, and the plan says the channel is unverified.
    }

    await capabilities.probe(sourceChainId);

    DenomRecommendation? advice;
    try {
      advice = await recommendDenom(
        _ref.read(denomContextProvider),
        sourceChainId,
        destChainId,
        inputDenom,
        destinationReceiveChannelId:
            options.isEmpty ? null : options.first.counterpartyChannelId,
      );
    } on InterchainError {
      advice = null;
    }

    final deps = RoutePlannerDeps(
      registry: registry,
      channels: createChannelDirectory(routes.links()),
      capabilities: capabilities.lookup,
      resolveDenom: (chain, denom) =>
          _ref.read(denomResolverProvider).resolve(chain.chainId, denom),
    );
    final request = RouteRequest(
      sourceChainId: sourceChainId,
      destChainId: destChainId,
      inputDenom: inputDenom,
      amount: amountBaseUnits,
      sender: sender,
      recipient: recipient,
      timeoutMinutes: kPacketTimeoutMinutes,
    );

    RoutePlanResult result;
    try {
      result = await planRoute(
        request,
        deps,
        PlanRouteOptions(overrides: _overrideList()),
      );
      final intermediates = _intermediateReceivers(
        result,
        sourceChainId: sourceChainId,
        destChainId: destChainId,
        phrase: phrase,
        accountIndex: accountIndex,
      );
      if (intermediates.isNotEmpty) {
        result = await planRoute(
          request,
          deps,
          PlanRouteOptions(
            overrides: _overrideList(),
            intermediateReceivers: intermediates,
          ),
        );
      }
    } on InterchainError catch (error) {
      publish(TransferPlanState(
        options: options,
        denomAdvice: advice,
        planError: error.message,
      ));
      return;
    }

    final candidate = result.best;
    if (candidate == null) {
      publish(TransferPlanState(
        options: options,
        denomAdvice: advice,
        warnings: result.warnings,
        blockedReason: result.warnings.isEmpty
            ? 'No channel path between these chains could be found.'
            : result.warnings.first,
      ));
      return;
    }

    if (candidate.receiver == pfmIntermediateReceiver) {
      publish(TransferPlanState(
        candidate: candidate,
        options: options,
        denomAdvice: advice,
        warnings: [...result.warnings, ...candidate.plan.warnings],
        blockedReason: 'This route passes through a chain the wallet has no '
            'address for, so the first packet has nowhere safe to land. Choose '
            'a direct channel, or unlock the wallet.',
      ));
      return;
    }

    publish(TransferPlanState(
      candidate: candidate,
      options: options,
      denomAdvice: advice,
      warnings: [...result.warnings, ...candidate.plan.warnings],
      memoInspection:
          validateMemo(candidate.plan.memo, receiver: candidate.receiver),
    ));
  }

  List<RouteHopOverride> _overrideList() => _overrides.values.toList();

  Map<String, String> _intermediateReceivers(
    RoutePlanResult result, {
    required String sourceChainId,
    required String destChainId,
    String? phrase,
    required int accountIndex,
  }) {
    if (phrase == null || !ChainCatalog.isLoaded) return const {};
    final wanted = <String>{};
    for (final candidate in result.candidates) {
      for (final hop in candidate.plan.hops) {
        final chainId = hop.counterpartyChainId;
        if (chainId == null) continue;
        if (chainId == sourceChainId || chainId == destChainId) continue;
        wanted.add(chainId);
      }
    }
    final out = <String, String>{};
    for (final chainId in wanted) {
      final chain = ChainCatalog.instance.find(chainId);
      if (chain == null) continue;
      try {
        out[chainId] = WalletKernel.instance
            .deriveAddress(
              phrase: phrase,
              chain: chain,
              accountIndex: accountIndex,
            )
            .address;
      } on Object {
        // A chain whose address cannot be derived is left out; the planner then
        // warns and the screen blocks rather than addressing a packet to "pfm".
      }
    }
    return out;
  }
}

final transferPlanControllerProvider = StateNotifierProvider.autoDispose<
    TransferPlanController, TransferPlanState>(
  (ref) => TransferPlanController(ref),
);
