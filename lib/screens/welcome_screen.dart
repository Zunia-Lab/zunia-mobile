import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/ui/zunia_mark.dart';
import 'package:zunia_tokens/zunia_tokens.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// First screen of a fresh install: what Zunia is in three pages, then create
/// or restore.
///
/// The pages swipe over one stage whose mark never moves; each page brings its
/// own scene around it (the phone that keeps the keys, the chains in orbit, the
/// ways a dApp connects) and the scene follows the finger, so the story is
/// scrubbed rather than played.
///
/// Create and restore ask the recovery-phrase acknowledgements on their own
/// first step. This screen only chooses which flow to open.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Story {
  const _Story(this.eyebrow, this.title, this.body);

  final String eyebrow;
  final String title;
  final String body;
}

// Titles keep their last two words together (no-break space) so a narrow
// screen never leaves one word alone on the last line.
const _stories = [
  _Story(
    'Self-custody',
    'Your keys stay on this\u00A0phone',
    'Zunia creates them here and seals them with your password. No account, '
        'no server copy: your recovery phrase is the only backup.',
  ),
  _Story(
    'Multichain',
    'Every Cosmos chain in one\u00A0place',
    'Every balance, IBC transfers, swaps and staking, all from one wallet.',
  ),
  _Story(
    'Connect',
    'Connect to any\u00A0dApp',
    'Scan a QR code, follow a link or browse inside Zunia. You see what each '
        'request does before you approve it.',
  ),
];

double _pageOf(PageController controller) {
  if (controller.hasClients && controller.position.hasContentDimensions) {
    return controller.page ?? 0;
  }
  return controller.initialPage.toDouble();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  final _pages = PageController();

  /// Slow loop for the orbit and the connection pulses.
  late final AnimationController _ambient =
      AnimationController(vsync: this, duration: const Duration(seconds: 30));

  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ambient.stop();
    } else if (!_ambient.isAnimating) {
      _ambient.repeat();
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _ambient.dispose();
    super.dispose();
  }

  Route<void> _onboardingRoute(OnboardingMode mode) => MaterialPageRoute<void>(
        builder: (_) => _OnboardingGround(child: OnboardingScreen(initialMode: mode)),
      );

  Future<void> _start(OnboardingMode mode) async {
    if (_opening) return;
    _opening = true;
    try {
      // The flow's first step asks the recovery-phrase acknowledgements.
      ZuniaHaptics.light();
      await Navigator.of(context).push(_onboardingRoute(mode));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The gate swaps this screen for the wallet once onboarding opens a
    // session; the onboarding route pushed on top has to go with it.
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null && next != null) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });

    final s = ZuniaSemanticsExt.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final short = media.size.height < 700;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: s.bg,
        body: ZuniaBackdrop(
      child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                SizedBox(height: short ? 4 : 10),
                Semantics(
                  header: true,
                  label: 'Zunia',
                  child: ExcludeSemantics(
                    child: Text(
                      'zunia',
                      textScaler: TextScaler.noScaling,
                      style: zuniaSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.3,
                        height: 1.2,
                        color: s.fg,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxHeight < 520;
                      // The words get the room they need at this width and
                      // text size; the stage takes the rest, up to 58%.
                      final words = _StoryText.heightFor(
                        context,
                        width: constraints.maxWidth,
                        compact: compact,
                      );
                      final stageHeight = math.max(
                        _StoryText.minStage,
                        math.min(
                          constraints.maxHeight - words,
                          constraints.maxHeight * 0.58,
                        ),
                      );
                      return Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: stageHeight,
                            child: _Stage(
                              pages: _pages,
                              ambient: _ambient,
                              still: still,
                            ),
                          ),
                          Positioned.fill(
                            child: PageView.builder(
                              controller: _pages,
                              itemCount: _stories.length,
                              onPageChanged: (_) => ZuniaHaptics.selection(),
                              itemBuilder: (context, index) => _StoryPage(
                                index: index,
                                controller: _pages,
                                stageHeight: stageHeight,
                                compact: compact,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                _PageDots(controller: _pages, count: _stories.length),
                Padding(
                  padding: EdgeInsets.fromLTRB(24, short ? 14 : 20, 24, 12 + media.viewPadding.bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ZuniaButton(
                        label: 'Create a new wallet',
                        size: ZuniaButtonSize.lg,
                        onPressed: () => _start(OnboardingMode.create),
                      ),
                      const SizedBox(height: 10),
                      ZuniaButton(
                        label: 'I already have a wallet',
                        size: ZuniaButtonSize.lg,
                        variant: ZuniaButtonVariant.secondary,
                        onPressed: () => _start(OnboardingMode.import),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Onboarding paints from below the status bar only; give its route an opaque
/// ground in the screen's own gradient so nothing shows through the top inset.
class _OnboardingGround extends StatelessWidget {
  const _OnboardingGround({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: ZuniaSemanticsExt.of(context).screenGradient),
      child: child,
    );
  }
}

/// The story's type, shared by the pages and by the measurement that sizes
/// the stage around them.
abstract final class _StoryText {
  static const bodyMaxWidth = 360.0;

  /// The stage keeps at least room for the mark.
  static const minStage = 88.0;

  static TextStyle eyebrow(ZuniaSemantic s) => zuniaMono(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.6,
        color: s.info,
      );

  static TextStyle title(ZuniaSemantic s, bool compact) => zuniaSans(
        fontSize: compact ? 23 : 27,
        fontWeight: FontWeight.w500,
        letterSpacing: compact ? -0.6 : -0.9,
        height: 1.15,
        color: s.fg,
      );

  static TextStyle body(ZuniaSemantic s) =>
      zuniaSans(fontSize: 14.5, height: 1.55, color: s.fgMuted);

  static double gap(bool compact) => compact ? 8 : 12;

  static EdgeInsets padding(bool compact) =>
      EdgeInsets.fromLTRB(28, compact ? 6 : 14, 28, fade);

  /// Words that still do not fit fade out over the bottom padding, so the
  /// cut reads as "scroll for more".
  static const fade = 14.0;

  /// Height of the tallest page's words at this width and text size.
  static double heightFor(
    BuildContext context, {
    required double width,
    required bool compact,
  }) {
    final s = ZuniaSemanticsExt.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final inner = width - padding(compact).horizontal;
    double measure(String text, TextStyle style, double maxWidth) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textAlign: TextAlign.center,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: maxWidth);
      final h = painter.height;
      painter.dispose();
      return h;
    }

    var tallest = 0.0;
    for (final story in _stories) {
      final h = measure(story.eyebrow.toUpperCase(), eyebrow(s), inner) +
          measure(story.title, title(s, compact), inner) +
          measure(story.body, body(s), math.min(inner, bodyMaxWidth)) +
          gap(compact) * 2;
      tallest = math.max(tallest, h);
    }
    return tallest + padding(compact).vertical;
  }
}

class _StoryPage extends StatelessWidget {
  const _StoryPage({
    required this.index,
    required this.controller,
    required this.stageHeight,
    required this.compact,
  });

  final int index;
  final PageController controller;
  final double stageHeight;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final story = _stories[index];
    final gap = _StoryText.gap(compact);
    final eyebrow = Text(
      story.eyebrow.toUpperCase(),
      textAlign: TextAlign.center,
      style: _StoryText.eyebrow(s),
    );
    final title = Semantics(
      header: true,
      child: Text(
        story.title,
        textAlign: TextAlign.center,
        style: _StoryText.title(s, compact),
      ),
    );
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _StoryText.bodyMaxWidth),
      child: Text(
        story.body,
        textAlign: TextAlign.center,
        style: _StoryText.body(s),
      ),
    );

    return Column(
      children: [
        SizedBox(height: stageHeight),
        Expanded(
          // Only text far larger than the stage can give way to still scrolls.
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 1 - _StoryText.fade / rect.height, 1],
            ).createShader(rect),
            child: SingleChildScrollView(
              padding: _StoryText.padding(compact),
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  // Lines leave at different speeds: a little depth while the
                  // page follows the finger.
                  final delta = index - _pageOf(controller);
                  return Opacity(
                    opacity: (1 - delta.abs() * 0.9).clamp(0.0, 1.0),
                    child: Column(
                      children: [
                        Transform.translate(offset: Offset(delta * 16, 0), child: eyebrow),
                        SizedBox(height: gap),
                        Transform.translate(offset: Offset(delta * 34, 0), child: title),
                        SizedBox(height: gap),
                        Transform.translate(offset: Offset(delta * 60, 0), child: body),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.controller, required this.count});

  final PageController controller;
  final int count;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = _pageOf(controller);
        return Semantics(
          label: 'Page ${page.round() + 1} of $count',
          child: ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < count; i++)
                  Builder(
                    builder: (context) {
                      final on = (1 - (page - i).abs()).clamp(0.0, 1.0);
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3.5),
                        width: 7 + 15 * on,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Color.lerp(s.lineStrong, s.accent, on),
                          borderRadius: BorderRadius.circular(ZuniaRadii.full),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- Stage ---------------------------------------------------------------------

/// Where everything on the stage sits for a page position, shared by the
/// painter and the widgets layered over it.
class _StageLayout {
  _StageLayout(this.size, this.page, this.spin, this.still) {
    center = Offset(size.width / 2, size.height / 2);
    radius = math.min(size.width, size.height) / 2;
    markHeight = (radius * 0.62).clamp(40.0, 108.0);
    phone = Size(markHeight * 1.08, math.min(markHeight * 1.9, radius * 1.5));
    orbitRx = math.min(radius * 1.12, size.width / 2 - 38);
    orbitRy = orbitRx * 0.4;
    satelliteRadius = (radius * 0.19).clamp(18.0, 30.0);
    satelliteDistance = math.min(
      radius - satelliteRadius - 2,
      (size.width / 2 - satelliteRadius - 14) / math.cos(math.pi / 6),
    );
  }

  final Size size;
  final double page;

  /// 0..1 over the ambient loop.
  final double spin;
  final bool still;

  late final Offset center;
  late final double radius;
  late final double markHeight;
  late final Size phone;
  late final double orbitRx;
  late final double orbitRy;
  late final double satelliteRadius;
  late final double satelliteDistance;

  /// How present scene [i] is: 1 on its page, gone two thirds of a page away,
  /// so neighbouring scenes hand over instead of piling up mid-swipe.
  double weight(int i) =>
      Curves.easeOut.transform((1 - (page - i).abs() * 1.5).clamp(0.0, 1.0));

  /// Scenes trail the swipe at a quarter of its speed.
  Offset shift(int i) => Offset((i - page) * size.width * 0.24, 0);

  static const satelliteAngles = [-150.0, -30.0, 90.0];

  Offset satellite(int k) {
    final a = satelliteAngles[k] * math.pi / 180;
    return center + shift(2) + Offset(math.cos(a), math.sin(a)) * satelliteDistance;
  }

  double get haloRadius => markHeight * 0.66;

  /// Orbit angle for chain [i] of [n]: turns with the ambient loop and with the
  /// swipe, so dragging the page spins the orbit.
  double orbitAngle(int i, int n) =>
      (still ? 0 : spin * 2 * math.pi) + (page - 1) * 0.9 + i * 2 * math.pi / n + math.pi / 2;

  Offset orbitPoint(double angle) =>
      center + shift(1) + Offset(math.cos(angle) * orbitRx, math.sin(angle) * orbitRy);
}

const _chains = ['SAF', 'ATOM', 'OSMO', 'TIA', 'INJ', 'NTRN', 'AKT'];

const _warm = [
  Color(0xFFFF1B0C),
  Color(0xFFFF4E12),
  Color(0xFFFF8A17),
  Color(0xFFFFBE14),
];

class _Stage extends StatelessWidget {
  const _Stage({required this.pages, required this.ambient, required this.still});

  final PageController pages;
  final Animation<double> ambient;
  final bool still;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return ExcludeSemantics(
      child: MediaQuery.withNoTextScaling(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder: (context, constraints) => AnimatedBuilder(
              animation: Listenable.merge([pages, ambient]),
              builder: (context, _) {
                final l = _StageLayout(constraints.biggest, _pageOf(pages), ambient.value, still);
                final pills = [
                  for (var i = 0; i < _chains.length; i++)
                    (i, l.orbitAngle(i, _chains.length)),
                ];
                final chainsOn = l.weight(1);
                List<Widget> pillLayer(bool front) => [
                      if (chainsOn > 0.01)
                        for (final (i, angle) in pills)
                          if ((math.sin(angle) >= 0) == front)
                            _orbitPill(context, s, l, i, angle, chainsOn),
                    ];
                final keysOn = l.weight(0);
                final connectOn = l.weight(2);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: CustomPaint(painter: _StagePainter(l, s))),
                    ...pillLayer(false),
                    Center(child: ZuniaMark(height: l.markHeight)),
                    ...pillLayer(true),
                    if (keysOn > 0.01) _lockBadge(s, l, keysOn, cupertino),
                    if (connectOn > 0.01)
                      for (var k = 0; k < 3; k++) _satellite(s, l, k, connectOn, cupertino),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _orbitPill(
    BuildContext context,
    ZuniaSemantic s,
    _StageLayout l,
    int i,
    double angle,
    double on,
  ) {
    final p = l.orbitPoint(angle);
    // Nearer the viewer (lower half of the orbit): larger and brighter.
    final depth = (math.sin(angle) + 1) / 2;
    return Positioned(
      left: p.dx - 40,
      top: p.dy - 12,
      width: 80,
      height: 24,
      child: Opacity(
        opacity: on * (0.45 + 0.55 * depth),
        child: Transform.scale(
          scale: 0.8 + 0.2 * depth,
          child: Center(
            child: Container(
              padding: const EdgeInsets.fromLTRB(7, 4, 9, 4),
              decoration: BoxDecoration(
                color: s.surfaceRaised,
                borderRadius: BorderRadius.circular(ZuniaRadii.full),
                border: Border.all(color: s.lineStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _warm[i % _warm.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _chains[i],
                    style: zuniaMono(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: s.fgMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lockBadge(ZuniaSemantic s, _StageLayout l, double on, bool cupertino) {
    final d = (l.radius * 0.26).clamp(26.0, 40.0);
    final corner = l.center +
        l.shift(0) +
        Offset(l.phone.width / 2 - d * 0.2, l.phone.height / 2 - d * 0.2);
    return Positioned(
      left: corner.dx - d / 2,
      top: corner.dy - d / 2,
      width: d,
      height: d,
      child: Opacity(
        opacity: on,
        child: Transform.scale(
          scale: 0.7 + 0.3 * on,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: s.accentGradient,
              border: Border.all(color: s.bg, width: 2.5),
            ),
            child: Icon(
              cupertino ? CupertinoIcons.lock_fill : Icons.lock_rounded,
              size: d * 0.46,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _satellite(ZuniaSemantic s, _StageLayout l, int k, double on, bool cupertino) {
    final p = l.satellite(k);
    final r = l.satelliteRadius;
    final icon = switch (k) {
      0 => cupertino ? CupertinoIcons.qrcode : Icons.qr_code_2_rounded,
      1 => cupertino ? CupertinoIcons.link : Icons.link_rounded,
      _ => cupertino ? CupertinoIcons.compass : Icons.public_rounded,
    };
    return Positioned(
      left: p.dx - r,
      top: p.dy - r,
      width: r * 2,
      height: r * 2,
      child: Opacity(
        opacity: on,
        child: Transform.scale(
          scale: 0.75 + 0.25 * on,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.surfaceRaised,
              border: Border.all(color: s.lineStrong),
            ),
            child: Icon(icon, size: r * 0.95, color: s.fg),
          ),
        ),
      ),
    );
  }
}

class _StagePainter extends CustomPainter {
  _StagePainter(this.l, this.s);

  final _StageLayout l;
  final ZuniaSemantic s;

  static const _amber = Color(0xFFFF8A17);

  @override
  void paint(Canvas canvas, Size size) {
    _glow(canvas);
    final keys = l.weight(0);
    final chains = l.weight(1);
    final connect = l.weight(2);
    if (keys > 0.01) _keys(canvas, keys);
    if (chains > 0.01) _orbits(canvas, chains);
    if (connect > 0.01) _connections(canvas, connect);
  }

  Paint _line(Color color, double opacity, [double width = 1]) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color.withValues(alpha: color.a * opacity);

  void _glow(Canvas canvas) {
    // Warms from red to amber across the story.
    final color = Color.lerp(s.accent, _amber, (l.page / 2).clamp(0.0, 1.0))!;
    final r = l.radius * 1.3;
    canvas.drawCircle(
      l.center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.30 * s.bloom),
            color.withValues(alpha: 0.07 * s.bloom),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: l.center, radius: r)),
    );
  }

  void _keys(Canvas canvas, double on) {
    final c = l.center + l.shift(0);
    for (final (f, a) in const [(0.78, 1.0), (0.94, 0.55)]) {
      canvas.drawCircle(c, l.radius * f, _line(s.line, on * a));
    }
    // A short arc keeps watch around the phone.
    if (!l.still) {
      final start = l.spin * 4 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: l.radius * 0.78),
        start,
        0.9,
        false,
        _line(s.accent, on * 0.8, 2)..strokeCap = StrokeCap.round,
      );
    }
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: l.phone.width, height: l.phone.height),
      Radius.circular(l.phone.width * 0.22),
    );
    canvas.drawRRect(
      phone,
      Paint()..color = s.surface.withValues(alpha: s.surface.a * 0.55 * on),
    );
    canvas.drawRRect(phone, _line(s.lineStrong, on, 1.5));
    final island = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(c.dx, phone.top + l.phone.width * 0.1),
        width: l.phone.width * 0.3,
        height: math.max(4, l.phone.width * 0.06),
      ),
      const Radius.circular(99),
    );
    canvas.drawRRect(island, Paint()..color = s.lineStrong.withValues(alpha: s.lineStrong.a * on));
  }

  void _orbits(Canvas canvas, double on) {
    final c = l.center + l.shift(1);
    canvas.drawOval(
      Rect.fromCenter(center: c, width: l.orbitRx * 2, height: l.orbitRy * 2),
      _line(s.lineStrong, on * 0.9),
    );
    canvas.drawOval(
      Rect.fromCenter(center: c, width: l.orbitRx * 1.4, height: l.orbitRy * 1.4),
      _line(s.line, on * 0.7),
    );
  }

  void _connections(Canvas canvas, double on) {
    final c = l.center + l.shift(2);
    canvas.drawCircle(c, l.haloRadius, Paint()..color = s.glass2.withValues(alpha: s.glass2.a * on));
    canvas.drawCircle(c, l.haloRadius, _line(s.line, on));
    for (var k = 0; k < 3; k++) {
      final sat = l.satellite(k);
      final dir = (c - sat) / (c - sat).distance;
      final from = sat + dir * (l.satelliteRadius + 6);
      final to = c - dir * (l.haloRadius + 6);
      _dashed(canvas, from, to, _line(s.lineStrong, on, 1.2));
      if (!l.still) {
        // A request travelling in from each way to connect.
        final t = (l.spin * 6 + k / 3) % 1;
        final p = Offset.lerp(from, to, Curves.easeInOut.transform(t))!;
        canvas.drawCircle(
          p,
          3,
          Paint()..color = s.accent.withValues(alpha: on * math.sin(t * math.pi)),
        );
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final length = (b - a).distance;
    final dir = (b - a) / length;
    for (var d = 0.0; d < length; d += 9) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + 4, length), paint);
    }
  }

  @override
  bool shouldRepaint(_StagePainter old) =>
      old.l.page != l.page ||
      old.l.spin != l.spin ||
      old.l.size != l.size ||
      old.l.still != l.still ||
      old.s != s;
}
