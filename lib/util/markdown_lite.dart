/// A small markdown subset for governance proposal text.
///
/// Dart mirror of zunia-extension/lib/markdown.ts. Proposals are authored as
/// markdown and sometimes pasted HTML; this reads them into plain blocks and
/// runs so the screen renders text, never markup: nothing in a proposal is
/// treated as HTML, and only http(s) links survive.
library;

import 'package:flutter/foundation.dart';

enum MdInlineKind { text, strong, em, strike, code, link }

@immutable
class MdInline {
  const MdInline.text(this.value)
      : kind = MdInlineKind.text,
        children = const [],
        href = null;
  const MdInline.code(this.value)
      : kind = MdInlineKind.code,
        children = const [],
        href = null;
  const MdInline.wrap(this.kind, this.children)
      : value = '',
        href = null;
  const MdInline.link(this.href, this.children)
      : kind = MdInlineKind.link,
        value = '';

  final MdInlineKind kind;
  final String value;
  final List<MdInline> children;
  final String? href;

  /// The visible text, markup removed.
  String get plain => switch (kind) {
        MdInlineKind.text || MdInlineKind.code => value,
        _ => children.map((c) => c.plain).join(),
      };
}

enum MdBlockKind { heading, paragraph, list, quote, code, rule }

@immutable
class MdBlock {
  const MdBlock(
    this.kind, {
    this.level = 0,
    this.children = const [],
    this.items = const [],
    this.ordered = false,
    this.code = '',
  });

  final MdBlockKind kind;

  /// 1-3 for a heading.
  final int level;
  final List<MdInline> children;
  final List<List<MdInline>> items;
  final bool ordered;
  final String code;
}

const _maxSource = 40000;

final _fence = RegExp(r'^```');
final _rule = RegExp(r'^[-*_]{3,}\s*$');
final _heading = RegExp(r'^(#{1,3})\s+(.+)$');
final _quote = RegExp(r'^>\s?');
final _listItem = RegExp(r'^\s*([-*+]|\d+\.)\s+');
final _ordered = RegExp(r'^\s*\d+\.\s+');
final _blockStart =
    RegExp(r'^(#{1,3}\s+|```|>\s?|\s*([-*+]|\d+\.)\s+|[-*_]{3,}\s*$)');

List<MdBlock> parseMarkdown(String source) {
  final text = _prepare(source);
  if (text.isEmpty) return const [];
  final blocks = <MdBlock>[];
  final lines = text.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    if (_fence.hasMatch(line)) {
      final body = <String>[];
      i++;
      while (i < lines.length && !_fence.hasMatch(lines[i])) {
        body.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++;
      blocks.add(MdBlock(MdBlockKind.code, code: body.join('\n')));
      continue;
    }
    if (_rule.hasMatch(line.trim())) {
      blocks.add(const MdBlock(MdBlockKind.rule));
      i++;
      continue;
    }
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      blocks.add(
        MdBlock(
          MdBlockKind.heading,
          level: heading.group(1)!.length,
          children: parseInline(heading.group(2)!),
        ),
      );
      i++;
      continue;
    }
    if (_quote.hasMatch(line)) {
      final quoted = <String>[];
      while (i < lines.length && _quote.hasMatch(lines[i])) {
        quoted.add(lines[i].replaceFirst(_quote, ''));
        i++;
      }
      blocks.add(
        MdBlock(MdBlockKind.quote, children: parseInline(quoted.join(' '))),
      );
      continue;
    }
    if (_listItem.hasMatch(line)) {
      final ordered = _ordered.hasMatch(line);
      final items = <List<MdInline>>[];
      while (i < lines.length && _listItem.hasMatch(lines[i])) {
        items.add(parseInline(lines[i].replaceFirst(_listItem, '')));
        i++;
      }
      blocks.add(MdBlock(MdBlockKind.list, items: items, ordered: ordered));
      continue;
    }
    final paragraph = <String>[line];
    i++;
    while (i < lines.length) {
      final next = lines[i];
      if (next.trim().isEmpty || _blockStart.hasMatch(next)) break;
      paragraph.add(next);
      i++;
    }
    blocks.add(
      MdBlock(MdBlockKind.paragraph, children: parseInline(paragraph.join(' '))),
    );
  }
  return blocks;
}

/// http(s) only, `www.` upgraded to https. Relative and `javascript:` links
/// are dropped and their text kept.
String? safeMarkdownHref(String href) {
  final value = href.trim();
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) return value;
  if (RegExp(r'^www\.', caseSensitive: false).hasMatch(value)) {
    return 'https://$value';
  }
  return null;
}

String _prepare(String source) {
  var text = source.replaceAll('\r\n', '\n').replaceAll(r'\n', '\n');
  if (text.length > _maxSource) text = text.substring(0, _maxSource);
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  if (RegExp(r'</?(p|div|br|h[1-3]|ul|ol|li|strong|em|a)\b', caseSensitive: false)
      .hasMatch(text)) {
    text = _htmlToText(text);
  }
  return text.trim();
}

String _htmlToText(String html) {
  RegExp re(String p) => RegExp(p, caseSensitive: false);
  return html
      .replaceAll(re(r'<br\s*/?>'), '\n')
      .replaceAll(re(r'</p>'), '\n\n')
      .replaceAll(re(r'</h[1-3]>'), '\n\n')
      .replaceAll(re(r'</li>'), '\n')
      .replaceAll(re(r'<li[^>]*>'), '- ')
      .replaceAllMapped(
        re(r'<h([1-3])[^>]*>'),
        (m) => '${'#' * int.parse(m.group(1)!)} ',
      )
      .replaceAll(re(r'</?(ul|ol|div|span)[^>]*>'), '\n')
      .replaceAllMapped(
        re(r'''<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>'''),
        (m) => '[${m.group(2)}](${m.group(1)})',
      )
      .replaceAll(re(r'</?(strong|b)>'), '**')
      .replaceAll(re(r'</?(em|i)>'), '*')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

final _inlinePattern = RegExp(
  r'(`+)([^`]+?)\1'
  r'|<((?:https?://|www\.)[^>\s]+)>'
  r'|\[([^\]]+)\]\(([^)]+)\)'
  r'|\*\*([^*]+)\*\*'
  r'|__([^_]+)__'
  r'|~~([^~]+)~~'
  r'|\*([^*]+)\*'
  r'|(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])',
);

final _bareUrl = RegExp(r'''(?:https?://|www\.)[^\s<>"'`]+''', caseSensitive: false);

List<MdInline> parseInline(String source) {
  final out = <MdInline>[];
  var cursor = 0;
  for (final m in _inlinePattern.allMatches(source)) {
    if (m.start > cursor) _pushText(out, source.substring(cursor, m.start));
    if (m.group(2) != null) {
      out.add(MdInline.code(m.group(2)!));
    } else if (m.group(3) != null) {
      _pushLink(out, m.group(3)!, [MdInline.text(m.group(3)!)]);
    } else if (m.group(4) != null) {
      final href = safeMarkdownHref(m.group(5) ?? '');
      final label = parseInline(m.group(4)!);
      if (href != null) {
        out.add(MdInline.link(href, label));
      } else {
        out.addAll(label);
      }
    } else if (m.group(6) != null || m.group(7) != null) {
      out.add(
        MdInline.wrap(
          MdInlineKind.strong,
          parseInline(m.group(6) ?? m.group(7)!),
        ),
      );
    } else if (m.group(8) != null) {
      out.add(MdInline.wrap(MdInlineKind.strike, parseInline(m.group(8)!)));
    } else {
      out.add(
        MdInline.wrap(MdInlineKind.em, parseInline(m.group(9) ?? m.group(10)!)),
      );
    }
    cursor = m.end;
  }
  if (cursor < source.length) _pushText(out, source.substring(cursor));
  return out;
}

String _trimUrlPunct(String value) => value.replaceAll(RegExp(r'[),.;:!?]+$'), '');

void _pushLink(List<MdInline> out, String raw, List<MdInline> children) {
  final href = safeMarkdownHref(_trimUrlPunct(raw));
  out.add(href == null ? MdInline.text(raw) : MdInline.link(href, children));
}

void _pushText(List<MdInline> out, String value) {
  if (value.isEmpty) return;
  var cursor = 0;
  for (final m in _bareUrl.allMatches(value)) {
    final raw = _trimUrlPunct(m.group(0)!);
    final trailing = m.group(0)!.substring(raw.length);
    if (m.start > cursor) out.add(MdInline.text(value.substring(cursor, m.start)));
    _pushLink(out, raw, [MdInline.text(displayMarkdownHref(raw))]);
    if (trailing.isNotEmpty) out.add(MdInline.text(trailing));
    cursor = m.end;
  }
  if (cursor < value.length) out.add(MdInline.text(value.substring(cursor)));
}

/// A short label for a bare URL: host and a clipped path.
String displayMarkdownHref(String href) {
  final absolute = safeMarkdownHref(href) ?? href;
  final uri = Uri.tryParse(absolute);
  if (uri == null || uri.host.isEmpty) return href;
  final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
  final path = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'
      .replaceFirst(RegExp(r'/$'), '');
  final shown = path.isNotEmpty && path != '/' ? '$host$path' : host;
  return shown.length > 42 ? '${shown.substring(0, 39)}…' : shown;
}
