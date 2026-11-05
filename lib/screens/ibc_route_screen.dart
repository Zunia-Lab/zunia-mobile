/// Edit the route of a send to another chain: one channel per leg.
///
/// Discovery fails on chains with slow or partial endpoints, and a user who
/// knows the channel must still be able to send. Each channel typed here is
/// checked on the source chain and on the far side as it is typed; a definite
/// "no" (missing, closed, leading elsewhere) cannot be used, and one the far
/// side could not confirm is used with a warning on the review. The send is
/// then planned again with these legs pinned, and every channel on the path
/// is still checked on both chains, light clients included, before it can be
/// signed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/transfers/channel_verdict.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';
import 'package:zunia_ui/zunia_ui.dart';

class RouteEditorScreen extends ConsumerStatefulWidget {
  const RouteEditorScreen({
    super.key,
    required this.sourceChainId,
    required this.destChainId,
    required this.plan,
    required this.pins,
  });

  final String sourceChainId;
  final String destChainId;

  /// The route planned so far, whose legs are offered for editing.
  final RoutePlanView? plan;
  final List<ManualChannel> pins;

  @override
  ConsumerState<RouteEditorScreen> createState() => _RouteEditorScreenState();
}

class _RouteEditorScreenState extends ConsumerState<RouteEditorScreen> {
  late final Map<String, ManualChannel> _pins = {
    for (final pin in widget.pins) '${pin.fromChainId}>${pin.toChainId}': pin,
  };

  List<(String, String, String?)> get _legs {
    final hops = widget.plan?.hops ?? const <RouteHopView>[];
    final legs = [
      for (final hop in hops)
        if (hop.kind != RouteHopKind.swap && hop.counterpartyChainId != null)
          (hop.chainId, hop.counterpartyChainId!, hop.channelId.isEmpty ? null : hop.channelId),
    ];
    return legs.isEmpty ? [(widget.sourceChainId, widget.destChainId, null)] : legs;
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final planner = ref.read(transferPlannerProvider);
    final legs = _legs;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Edit route',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Text(
                'Zunia picks each channel from the chain registry and what it has checked. Enter a '
                'channel only if you know the route; it is checked on both chains before it is used.',
                style: zuniaSans(fontSize: 13, height: 1.45, color: s.fgMuted),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < legs.length; i++) ...[
                _LegField(
                  key: ValueKey('${legs[i].$1}>${legs[i].$2}'),
                  index: i,
                  count: legs.length,
                  fromChainId: legs[i].$1,
                  toChainId: legs[i].$2,
                  fromName: planner.chainName(legs[i].$1),
                  toName: planner.chainName(legs[i].$2),
                  planned: legs[i].$3,
                  initial: _pins['${legs[i].$1}>${legs[i].$2}'],
                  onChanged: (pin) => setState(() {
                    final key = '${legs[i].$1}>${legs[i].$2}';
                    if (pin == null) {
                      _pins.remove(key);
                    } else {
                      _pins[key] = pin;
                    }
                  }),
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaButton(
                label: 'Use this route',
                size: ZuniaButtonSize.lg,
                onPressed: () => Navigator.of(context).pop(_pins.values.toList()),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(const <ManualChannel>[]),
                child: const Text('Let Zunia choose'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegField extends ConsumerStatefulWidget {
  const _LegField({
    super.key,
    required this.index,
    required this.count,
    required this.fromChainId,
    required this.toChainId,
    required this.fromName,
    required this.toName,
    required this.planned,
    required this.initial,
    required this.onChanged,
  });

  final int index;
  final int count;
  final String fromChainId;
  final String toChainId;
  final String fromName;
  final String toName;
  final String? planned;
  final ManualChannel? initial;
  final ValueChanged<ManualChannel?> onChanged;

  @override
  ConsumerState<_LegField> createState() => _LegFieldState();
}

class _LegFieldState extends ConsumerState<_LegField> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial?.channelId ?? '');
  Timer? _debounce;
  ChannelVerdict? _verdict;
  bool _checking = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final channel = normalizeChannelId(value);
    if (channel.isEmpty) {
      setState(() {
        _verdict = null;
        _checking = false;
      });
      widget.onChanged(null);
      return;
    }
    setState(() => _checking = true);
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final check = await ref
          .read(transferPlannerProvider)
          .validateChannel(widget.fromChainId, channel, widget.toChainId);
      if (!mounted) return;
      final verdict = classifyChannelCheck(check, widget.toChainId);
      setState(() {
        _verdict = verdict;
        _checking = false;
      });
      widget.onChanged(verdictAllowsUse(verdict)
          ? ManualChannel(
              fromChainId: widget.fromChainId,
              toChainId: widget.toChainId,
              // The chain's own spelling: a check of one string and a signature
              // over another is what the path check refuses.
              channelId: check.channelId.isEmpty ? channel : check.channelId,
              counterpartyChannelId: verdict.counterpartyChannelId,
              verdict: verdict.kind,
            )
          : null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final verdict = _verdict;
    final color = switch (verdict?.kind) {
      ChannelVerdictKind.verified => s.success,
      ChannelVerdictKind.rejected => s.danger,
      ChannelVerdictKind.openUnconfirmed || ChannelVerdictKind.inconclusive => s.warning,
      null => s.fgMuted,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.count == 1
              ? '${widget.fromName} → ${widget.toName}'
              : 'Leg ${widget.index + 1}: ${widget.fromName} → ${widget.toName}',
          style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg),
        ),
        const SizedBox(height: 8),
        ZuniaInput(
          controller: _controller,
          label: 'CHANNEL ON ${widget.fromName.toUpperCase()}',
          hint: widget.planned ?? 'channel-141',
          errorText: verdict?.kind == ChannelVerdictKind.rejected ? verdict!.note : null,
          onChanged: _onChanged,
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            _checking
                ? 'Checking this channel on ${widget.fromName} and ${widget.toName}…'
                : verdict == null
                    ? (widget.planned == null
                        ? 'No channel chosen yet. Leave empty to let Zunia find one.'
                        : 'Planned: ${widget.planned}. Leave empty to keep it.')
                    : verdict.kind == ChannelVerdictKind.rejected
                        ? 'This channel cannot be used.'
                        : verdict.note,
            style: zuniaMono(fontSize: 10.5, height: 1.4, color: _checking ? s.fgMuted : color),
          ),
        ),
      ],
    );
  }
}
