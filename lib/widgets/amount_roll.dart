import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// A figure that rolls to its new value instead of jumping: the headline
/// total after a refresh. Short and eased, and instant when the system asks
/// for reduced motion.
class AmountRoll extends StatelessWidget {
  const AmountRoll({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.semanticsLabel,
  });

  final double value;

  /// Turns an in-between value into text (`$12,408.20`).
  final String Function(double value) format;
  final TextStyle? style;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final textStyle = style ??
        zuniaSans(
          fontSize: 34,
          fontWeight: FontWeight.w500,
          letterSpacing: -1.4,
          height: 1.05,
          color: s.fg,
          tabular: const FontFeature.tabularFigures(),
        );
    return Semantics(
      label: semanticsLabel ?? format(value),
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        builder: (context, shown, _) => _SplitFigure(text: format(shown), style: textStyle),
      ),
    );
  }
}

/// `$12,408` bright and `.20` muted, as the hero amount reads.
class _SplitFigure extends StatelessWidget {
  const _SplitFigure({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final dot = text.lastIndexOf('.');
    final split = dot > 0 && RegExp(r'^\.\d+$').hasMatch(text.substring(dot));
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          text: split ? text.substring(0, dot) : text,
          style: style,
          children: [
            if (split) TextSpan(text: text.substring(dot), style: style.copyWith(color: s.fgDim)),
          ],
        ),
        maxLines: 1,
      ),
    );
  }
}
