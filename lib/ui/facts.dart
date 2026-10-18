/// Label and value rows for review cards and detail screens.
///
/// `ZuniaKeyValueRow` lays both out in one Row with no flex, which overflows
/// at 320dp as soon as a value is an address or a validator name. This one
/// gives the value the remaining width and lets it wrap, and stacks the two
/// under large text. Candidate for promotion into zunia_ui.
library;

import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

class FactRow extends StatelessWidget {
  const FactRow({
    super.key,
    required this.label,
    required this.value,
    this.valueWidget,
    this.mono = true,
    this.emphasis = false,
    this.tone,
  });

  final String label;
  final String value;

  /// Replaces the value text (a link, a pill), keeping [value] for semantics.
  final Widget? valueWidget;
  final bool mono;
  final bool emphasis;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final large = MediaQuery.textScalerOf(context).scale(10) > 12;
    final labelText = Text(
      label,
      style: zuniaSans(fontSize: 13, color: s.fgMuted),
    );
    final valueStyle = mono
        ? zuniaMono(
            fontSize: emphasis ? 13.5 : 12.5,
            fontWeight: emphasis ? FontWeight.w500 : FontWeight.w400,
            color: tone ?? s.fg,
          )
        : zuniaSans(
            fontSize: 14,
            fontWeight: emphasis ? FontWeight.w600 : FontWeight.w500,
            color: tone ?? s.fg,
          );
    final valueChild = valueWidget ??
        Text(
          value,
          textAlign: large ? TextAlign.start : TextAlign.end,
          style: valueStyle,
        );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: large
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, const SizedBox(height: 2), valueChild],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  labelText,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: valueChild,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// A rounded group of [FactRow]s with an optional caption.
class FactsCard extends StatelessWidget {
  const FactsCard({super.key, required this.children, this.title});

  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(
                  title!.toUpperCase(),
                  style: zuniaMono(
                    fontSize: 10,
                    letterSpacing: 1.4,
                    color: s.fgDim,
                  ),
                ),
              ),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Uppercase caption above a group, matching the list sections.
class SectionCaption extends StatelessWidget {
  const SectionCaption(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                text.toUpperCase(),
                style: zuniaMono(
                  fontSize: 10.5,
                  letterSpacing: 1.4,
                  color: s.fgDim,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Grey placeholder rows while a list loads: skeletons, not spinners.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 4, this.label = 'Loading'});

  final int rows;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      liveRegion: true,
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const ZuniaSkeleton(width: 32, height: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ZuniaSkeleton(width: i.isEven ? 140 : 110, height: 11),
                          const SizedBox(height: 8),
                          ZuniaSkeleton(width: i.isEven ? 90 : 120, height: 8),
                        ],
                      ),
                    ),
                    const ZuniaSkeleton(width: 54, height: 11),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
