/// The retry control every Swap check shares: it says it is working, cannot be
/// tapped twice, and says what came of it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/swap_balances.dart';
import 'package:zunia_mobile/state/swap_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// What a run of [SwapRetry.onRetry] came to: true when the problem is gone.
typedef SwapRetryRun = Future<bool> Function();

/// A "Try again" button that owns the state of one retry.
///
/// Idle it is a plain text button. A tap ticks the haptic, disables the
/// button and shows a spinner with [runningLabel] until [onRetry] finishes.
/// If the check came back bad again it says so under the button ("Still
/// unavailable, checked just now"); if it came back good the caller takes the
/// control away because the problem it sat under is gone.
///
/// Keep it mounted while the check runs: a parent that swaps it out for a
/// loading state loses the outcome.
class SwapRetry extends StatefulWidget {
  const SwapRetry({
    super.key,
    required this.onRetry,
    required this.active,
    this.label = 'Try again',
    this.runningLabel = 'Checking…',
    this.semanticLabel,
    this.alignment = Alignment.centerLeft,
  });

  final SwapRetryRun onRetry;

  /// Whether the problem this sits under is still there. The control stays in
  /// the tree while it runs even if the problem is briefly not shown (a plan
  /// being made again hides its own error), and hides itself once the check
  /// is over and the problem is gone.
  final bool active;
  final String label;
  final String runningLabel;
  final String? semanticLabel;
  final AlignmentGeometry alignment;

  @override
  State<SwapRetry> createState() => _SwapRetryState();
}

class _SwapRetryState extends State<SwapRetry> {
  bool _running = false;
  DateTime? _failedAt;
  Timer? _tick;

  @override
  void didUpdateWidget(SwapRetry old) {
    super.didUpdateWidget(old);
    // A problem that went away by itself takes its old verdict with it.
    if (!widget.active && !_running) _failedAt = null;
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    // A second tap while the first is running does nothing.
    if (_running) return;
    unawaited(ZuniaHaptics.selection());
    setState(() => _running = true);
    var cleared = false;
    try {
      cleared = await widget.onRetry();
    } on Object {
      cleared = false;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _failedAt = cleared ? null : DateTime.now();
    });
    _tick?.cancel();
    if (!cleared) {
      // "just now" ages: say so while the message is on screen.
      _tick = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  String _when(DateTime at) {
    final seconds = DateTime.now().difference(at).inSeconds;
    if (seconds < 30) return 'just now';
    if (seconds < 90) return '1 minute ago';
    return '${(seconds / 60).round()} minutes ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final failedAt = _failedAt;
    if (!widget.active && !_running) return const SizedBox.shrink();
    return Align(
      alignment: widget.alignment,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            container: true,
            button: true,
            enabled: !_running,
            label: _running
                ? widget.runningLabel
                : widget.semanticLabel ?? widget.label,
            excludeSemantics: true,
            child: TextButton(
              onPressed: _running ? null : _run,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 40),
                foregroundColor: s.accent,
              ),
              child: _running
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const ZuniaActivityIndicator(size: 14),
                        const SizedBox(width: 8),
                        Text(
                          widget.runningLabel,
                          style: zuniaSans(fontSize: 14, color: s.fgMuted),
                        ),
                      ],
                    )
                  : Text(widget.label),
            ),
          ),
          if (failedAt != null && !_running)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  'Still unavailable — checked ${_when(failedAt)}',
                  style: zuniaSans(
                    fontSize: 12,
                    height: 1.35,
                    color: s.warning,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/* -------------------------------------------------------------------------- *
 * The checks the controls run
 * -------------------------------------------------------------------------- */

/// Ask for the same plan and price again and wait for the answer to the new
/// ask. True when the form shows no error for it. The Swap tab makes the plan
/// itself once the inputs settle; this only waits for it.
Future<bool> retryPlan(
  WidgetRef ref, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final before = ref.read(swapViewProvider).planKey;
  if (before.isEmpty) return false;
  final done = Completer<bool>();
  final sub = ref.listenManual<SwapView>(swapViewProvider, (_, view) {
    if (done.isCompleted || view.planKey == before) return;
    if (view.planKey.isEmpty) {
      done.complete(false);
    } else if (view.contract != null || view.pool != null) {
      done.complete(view.contract?.error == null && view.quoteError == null);
    }
  });
  try {
    ref.read(swapControllerProvider.notifier).retry();
    return await done.future.timeout(timeout, onTimeout: () => false);
  } finally {
    sub.close();
  }
}

/// Check the cross-chain swap contract (and the route table that hangs off
/// it) again. True when it is confirmed.
Future<bool> retryVenue(WidgetRef ref) async {
  ref.invalidate(swapVenueStatusProvider);
  try {
    return (await ref.read(swapVenueStatusProvider.future)).ready;
  } on Object {
    return false;
  }
}

/// Check the one-signature entry point on Osmosis again. True when confirmed.
Future<bool> retryEntryPoint(WidgetRef ref) async {
  ref.invalidate(entryPointStatusProvider);
  try {
    return (await ref.read(entryPointStatusProvider.future)).ready;
  } on Object {
    return false;
  }
}

/// Read the Osmosis token list again; true when it came.
Future<bool> retryOsmosisAssets(WidgetRef ref) async {
  ref.invalidate(osmosisSwapAssetsProvider);
  try {
    return (await ref.read(osmosisSwapAssetsProvider.future)).error == null;
  } on Object {
    return false;
  }
}

/// Read the balances that did not answer again; true when all of them did.
Future<bool> retryBalances(WidgetRef ref, Iterable<String> chainIds) async {
  // The base read may be what failed: read these chains over it.
  return ref.read(swapBalancesProvider.notifier).refresh(chainIds);
}
