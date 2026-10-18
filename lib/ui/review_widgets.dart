/// Pieces every signing prompt is built from, so a dApp request reads the
/// same whether it came from the in-app browser, Zunia Connect or
/// WalletConnect (the extension's TxReview.tsx and ApproveScreen.tsx):
/// - what matters first (the action, the account, the fee);
/// - what stops the signature, never folded;
/// - everything else folded into sections that start closed.
///
/// Candidates for zunia_ui once a second surface needs them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// A labelled card surface for the facts under the headline.
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.children, this.danger = false});

  final List<Widget> children;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: danger ? s.dangerFill : s.glass,
        border: Border.all(color: danger ? s.dangerLine : s.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 18, thickness: 0.5, color: s.line),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One fact: what it is on the left, the value on the right, wrapping rather
/// than overflowing (a fee in an unnamed denom, an address).
class ReviewRow extends StatelessWidget {
  const ReviewRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.note,
  });

  final String label;
  final String value;
  final bool mono;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final valueStyle = mono
        ? zuniaMono(fontSize: 12, color: s.fg, height: 1.4)
        : zuniaSans(fontSize: 13, color: s.fg, height: 1.35, tabular: const FontFeature.tabularFigures());
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72, maxWidth: 120),
            child: Text(label, style: zuniaSans(fontSize: 12.5, color: s.fgMuted, height: 1.35)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, textAlign: TextAlign.end, style: valueStyle),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    note!,
                    textAlign: TextAlign.end,
                    style: zuniaSans(fontSize: 11, color: s.fgDim, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A section that opens on demand and starts closed.
class ReviewDisclosure extends StatefulWidget {
  const ReviewDisclosure({
    super.key,
    required this.title,
    required this.child,
    this.hint,
  });

  final String title;

  /// Beside the title, quieter: what is inside, in a word or two.
  final String? hint;
  final Widget child;

  @override
  State<ReviewDisclosure> createState() => _ReviewDisclosureState();
}

class _ReviewDisclosureState extends State<ReviewDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: widget.title,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                ZuniaHaptics.selection();
                setState(() => _open = !_open);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: zuniaSans(fontSize: 13, fontWeight: FontWeight.w500, color: s.fgMuted),
                      ),
                    ),
                    if (widget.hint != null)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8, right: 6),
                          child: Text(
                            widget.hint!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zuniaSans(fontSize: 11.5, color: s.fgDim),
                          ),
                        ),
                      ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.expand_more_rounded, size: 20, color: s.fgDim),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: widget.child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Monospace text shown whole: scrollable, selectable, copyable.
class RawTextBlock extends StatelessWidget {
  const RawTextBlock({super.key, required this.text, this.maxHeight = 260});

  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: s.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: zuniaMono(fontSize: 10.5, color: s.fg, height: 1.45),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ZuniaHaptics.light();
            },
            icon: Icon(Icons.copy_rounded, size: 15, color: s.fgMuted),
            label: Text('Copy', style: zuniaSans(fontSize: 12, color: s.fgMuted)),
          ),
        ),
      ],
    );
  }
}

/// Warnings the user should read before approving, as one list.
class ReviewWarnings extends StatelessWidget {
  const ReviewWarnings({super.key, required this.warnings, this.title = 'Check before approving'});

  final List<String> warnings;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) return const SizedBox.shrink();
    return ZuniaCallout(
      tone: ZuniaCalloutTone.warning,
      title: title,
      body: warnings.map((w) => '• $w').join('\n'),
    );
  }
}

/// Seconds left until [expiresAt], ticking; `m:ss`, amber under 30 s.
class ExpiryCountdown extends StatefulWidget {
  const ExpiryCountdown({super.key, required this.expiresAt, this.onExpired});

  final DateTime expiresAt;
  final VoidCallback? onExpired;

  @override
  State<ExpiryCountdown> createState() => _ExpiryCountdownState();
}

class _ExpiryCountdownState extends State<ExpiryCountdown> {
  Timer? _timer;
  late int _left = _secondsLeft();

  int _secondsLeft() {
    final left = widget.expiresAt.difference(DateTime.now()).inMilliseconds / 1000;
    return left <= 0 ? 0 : left.round();
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = _secondsLeft();
      if (next == _left) return;
      setState(() => _left = next);
      if (next == 0) {
        _timer?.cancel();
        widget.onExpired?.call();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final text = '${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}';
    return Semantics(
      label: 'Expires in ${_left ~/ 60} minutes ${_left % 60} seconds',
      excludeSemantics: true,
      child: Text(
        text,
        style: zuniaMono(
          fontSize: 11,
          letterSpacing: 0.6,
          color: _left <= 30 ? s.warning : s.fgDim,
        ),
      ),
    );
  }
}

/// A quiet paragraph: what a site says about itself, a note under a fact.
class ReviewNote extends StatelessWidget {
  const ReviewNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Text(text, style: zuniaSans(fontSize: 12.5, height: 1.45, color: s.fgMuted));
  }
}
