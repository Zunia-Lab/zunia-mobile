/// A site's real icon: a bundled asset, else the favicon captured from the page,
/// else the site's touch icon / favicon.ico, else a neutral globe. Network
/// icons honour the "live reads" switch like every other remote image.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_tokens/zunia_tokens.dart';
import 'package:zunia_ui/zunia_ui.dart';

class BrowserFavicon extends ConsumerStatefulWidget {
  const BrowserFavicon({
    super.key,
    required this.host,
    this.asset,
    this.iconUrl,
    this.size = 40,
    this.radius,
  });

  final String host;
  final String? asset;
  final String? iconUrl;
  final double size;
  final double? radius;

  @override
  ConsumerState<BrowserFavicon> createState() => _BrowserFaviconState();
}

class _BrowserFaviconState extends ConsumerState<BrowserFavicon> {
  int _failed = 0;

  List<String> get _candidates {
    final host = widget.host;
    return [
      if (widget.iconUrl != null && widget.iconUrl!.startsWith('https://')) widget.iconUrl!,
      if (host.isNotEmpty) 'https://$host/apple-touch-icon.png',
      if (host.isNotEmpty) 'https://$host/favicon.ico',
    ];
  }

  @override
  void didUpdateWidget(BrowserFavicon old) {
    super.didUpdateWidget(old);
    if (old.iconUrl != widget.iconUrl || old.host != widget.host) _failed = 0;
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final live = ref.watch(preferencesProvider.select((p) => p.liveReads));
    final size = widget.size;
    final radius = widget.radius ?? size * 0.26;
    final inner = size * 0.64;
    final px = (inner * MediaQuery.devicePixelRatioOf(context)).round();

    Widget content;
    final candidates = _candidates;
    final globe = Icon(Icons.public_rounded, size: size * 0.5, color: s.fgMuted);
    if (widget.asset != null) {
      content = Image.asset(
        widget.asset!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => globe,
      );
      return _frame(s, size, radius, content, bare: true);
    }
    if (live && _failed < candidates.length) {
      content = Image.network(
        candidates[_failed],
        key: ValueKey(candidates[_failed]),
        width: inner,
        height: inner,
        fit: BoxFit.contain,
        cacheWidth: px,
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _failed++);
          });
          return globe;
        },
      );
    } else {
      content = globe;
    }
    return _frame(s, size, radius, content);
  }

  Widget _frame(ZuniaSemantic s, double size, double radius, Widget child, {bool bare = false}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: bare ? null : s.glass2,
        border: bare ? null : Border.all(color: s.line),
      ),
      child: child,
    );
  }
}
