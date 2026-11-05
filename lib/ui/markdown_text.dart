/// Proposal text, rendered from [parseMarkdown] blocks as plain styled text.
/// A link opens only after the user sees where it goes.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/util/markdown_lite.dart';
import 'package:zunia_ui/zunia_ui.dart';

class MarkdownText extends StatefulWidget {
  const MarkdownText(this.source, {super.key});

  final String source;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  late List<MdBlock> _blocks = parseMarkdown(widget.source);
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void didUpdateWidget(covariant MarkdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _blocks = parseMarkdown(widget.source);
    }
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final go = await showZuniaConfirm(
      context,
      title: 'Open link?',
      message: '${uri.host}\n\nProposal text is written by whoever submitted '
          'it. Zunia has not checked this link.',
      confirmLabel: 'Open',
    );
    if (!go) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  List<InlineSpan> _spans(List<MdInline> runs, TextStyle base) {
    final s = ZuniaSemanticsExt.of(context);
    return [
      for (final run in runs)
        switch (run.kind) {
          MdInlineKind.text => TextSpan(text: run.value, style: base),
          MdInlineKind.code => TextSpan(
              text: run.value,
              style: zuniaMono(
                fontSize: (base.fontSize ?? 14) - 1,
                color: s.fg,
              ).copyWith(backgroundColor: s.glass2),
            ),
          MdInlineKind.strong => TextSpan(
              children: _spans(
                run.children,
                base.copyWith(fontWeight: FontWeight.w600, color: s.fg),
              ),
            ),
          MdInlineKind.em => TextSpan(
              children: _spans(
                run.children,
                base.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          MdInlineKind.strike => TextSpan(
              children: _spans(
                run.children,
                base.copyWith(decoration: TextDecoration.lineThrough),
              ),
            ),
          MdInlineKind.link => TextSpan(
              children: _spans(
                run.children,
                base.copyWith(
                  color: s.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: s.accent.withValues(alpha: 0.5),
                ),
              ),
              recognizer: _recognizer(run.href!),
            ),
        },
    ];
  }

  TapGestureRecognizer _recognizer(String href) {
    final r = TapGestureRecognizer()..onTap = () => _open(href);
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final body = zuniaSans(fontSize: 14.5, height: 1.55, color: s.fgMuted);
    final children = <Widget>[];
    for (final block in _blocks) {
      switch (block.kind) {
        case MdBlockKind.heading:
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Semantics(
                header: true,
                child: Text.rich(
                  TextSpan(
                    children: _spans(
                      block.children,
                      zuniaSans(
                        fontSize: switch (block.level) {
                          1 => 19,
                          2 => 17,
                          _ => 15.5,
                        },
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: s.fg,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        case MdBlockKind.paragraph:
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text.rich(TextSpan(children: _spans(block.children, body))),
            ),
          );
        case MdBlockKind.quote:
          children.add(
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: s.lineStrong, width: 3)),
              ),
              child: Text.rich(
                TextSpan(
                  children: _spans(
                    block.children,
                    body.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
              ),
            ),
          );
        case MdBlockKind.list:
          for (var i = 0; i < block.items.length; i++) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        block.ordered ? '${i + 1}.' : '•',
                        style: body,
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: _spans(block.items[i], body)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          children.add(const SizedBox(height: 4));
        case MdBlockKind.code:
          children.add(
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: s.glass2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  block.code,
                  style: zuniaMono(fontSize: 12, height: 1.5, color: s.fg),
                ),
              ),
            ),
          );
        case MdBlockKind.rule:
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: s.line),
            ),
          );
      }
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
