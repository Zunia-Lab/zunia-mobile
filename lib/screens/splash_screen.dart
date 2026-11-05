import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/ui/zunia_mark.dart';
import 'package:zunia_tokens/zunia_tokens.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Branded handoff between the native launch screen and the first real route.
///
/// The first frame is the native launch screen, pixel for pixel: the mark at
/// 96 x 120 in the centre of the whole screen, on the launch background of the
/// system appearance (ios/Runner/Base.lproj/LaunchScreen.storyboard,
/// android/app/src/main/res/values*/styles.xml). It holds still while iOS fades
/// its launch view out over Flutter's first frame, then the mark rises into the
/// stacked lockup as the wordmark and a soft glow come in.
///
/// With reduced motion it never moves: the mark stays where the native screen
/// left it and [SplashGate] dissolves straight into the app.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.message, this.onIntroDone});

  /// Optional status under the lockup (e.g. boot error text).
  final String? message;

  /// Called once the intro has played (at once with reduced motion).
  final VoidCallback? onIntroDone;

  /// The whole intro, hold included. With [exitDuration] and the frame each
  /// animation waits to start on, a ready app waits under 900 ms.
  static const introDuration = Duration(milliseconds: 680);

  /// iOS removes its launch view with a 200 ms fade on top of Flutter's first
  /// frame; a mark that moved before then would show twice.
  static const holdDuration = Duration(milliseconds: 220);

  /// [SplashGate]'s dissolve into the first route.
  static const exitDuration = Duration(milliseconds: 180);

  /// How far the mark rises to make room for the wordmark: it centres the
  /// stacked lockup (zunia-logo-stacked: mark box 0-120, baseline at 192).
  static const rise = 40.0;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Tokens for the launch background, which follows the system appearance: the
/// native screens cannot know the app's theme, so the splash matches them
/// instead and the app's theme takes over at the handoff.
ZuniaSemantic _launchTokens(BuildContext context) =>
    MediaQuery.platformBrightnessOf(context) == Brightness.dark
        ? ZuniaSemantic.dark
        : ZuniaSemantic.light;

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  late final Animation<double> _rise;
  late final Animation<double> _word;
  late final Animation<double> _glow;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: SplashScreen.introDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onIntroDone?.call();
      });
    final hold = SplashScreen.holdDuration.inMilliseconds /
        SplashScreen.introDuration.inMilliseconds;
    _rise = CurvedAnimation(
      parent: _intro,
      curve: Interval(hold, 1, curve: Curves.easeInOutCubic),
    );
    _word = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.48, 1, curve: Curves.easeOutCubic),
    );
    _glow = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0, 1, curve: Curves.easeOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      // Nothing to play: report done after this first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onIntroDone?.call();
      });
    } else {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _launchTokens(context);
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final overlay = (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: Material(
        color: s.bg,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The native screens centre the mark on the whole display, not the
            // safe area, and so does this.
            final cx = constraints.maxWidth / 2;
            final cy = constraints.maxHeight / 2;
            return AnimatedBuilder(
              animation: _intro,
              builder: (context, _) {
                final markY = cy - SplashScreen.rise * _rise.value;
                // Baseline sits 132 under the mark's centre, as in the lockup.
                final baseline = markY + 132 + 12 * (1 - _word.value);
                return Stack(
                  children: [
                    if (_glow.value > 0)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _GlowPainter(
                            center: Offset(cx, markY),
                            t: _glow.value,
                            color: s.accent,
                            bloom: s.bloom,
                          ),
                        ),
                      ),
                    Positioned(
                      left: cx - ZuniaMarkPainter.gridWidth / 2,
                      top: markY - ZuniaMarkPainter.gridHeight / 2,
                      child: const ZuniaMark(height: 120, semanticLabel: 'Zunia'),
                    ),
                    if (_word.value > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: baseline - 62,
                        child: ExcludeSemantics(
                          child: Opacity(
                            opacity: _word.value,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Baseline(
                                baseline: 62,
                                baselineType: TextBaseline.alphabetic,
                                // The wordmark is artwork: Space Grotesk 700,
                                // -0.065em, never scaled with the text size.
                                child: Text(
                                  'zunia',
                                  textScaler: TextScaler.noScaling,
                                  style: zuniaSans(
                                    fontSize: 62,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -4,
                                    height: 1,
                                    color: s.fg,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.message != null)
                      Positioned(
                        left: 32,
                        right: 32,
                        top: (_word.value > 0 ? baseline : markY + 60) + 32,
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            widget.message!,
                            textAlign: TextAlign.center,
                            style: zuniaSans(
                              fontSize: 13,
                              height: 1.45,
                              color: s.danger,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({
    required this.center,
    required this.t,
    required this.color,
    required this.bloom,
  });

  final Offset center;
  final double t;
  final Color color;
  final double bloom;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = 190 * (0.72 + 0.28 * t);
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.34 * bloom * t),
            color.withValues(alpha: 0.08 * bloom * t),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.42, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.center != center || old.t != t || old.color != color || old.bloom != bloom;
}

/// Keeps the splash over the first route until the intro has played and the
/// app gate has decided where to go, then dissolves into that route.
///
/// The route underneath is built from the start, so it has laid out (and the
/// unlock screen can already ask for biometrics) by the time it shows. A ready
/// app waits for the intro and the dissolve only, under 900 ms from the first
/// frame; with reduced motion, for the dissolve alone.
class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _exit;
  late final Animation<double> _fade;
  bool _introDone = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _exit = AnimationController(vsync: this, duration: SplashScreen.exitDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) setState(() => _gone = true);
      });
    _fade = CurvedAnimation(parent: _exit, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  bool get _gateResolved {
    // Without a kernel the gate shows its own screen at once.
    if (!WalletKernel.instance.isAvailable) return true;
    return ref.read(appGateProvider).maybeWhen(
          data: (gate) => gate != AppGate.loading,
          error: (_, _) => true,
          orElse: () => false,
        );
  }

  void _maybeExit() {
    if (!mounted || _gone || !_exit.isDismissed) return;
    if (!_introDone || !_gateResolved) return;
    setState(() {});
    _exit.forward();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AppGate>>(appGateProvider, (_, _) => _maybeExit());
    final exiting = !_exit.isDismissed;
    final still = MediaQuery.disableAnimationsOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(excluding: !exiting && !_gone, child: widget.child),
        if (!_gone)
          IgnorePointer(
            ignoring: exiting,
            child: ExcludeSemantics(
              excluding: exiting,
              child: AnimatedBuilder(
                animation: _fade,
                builder: (context, child) => Opacity(
                  opacity: 1 - _fade.value,
                  // Opening into the app: the splash eases towards the viewer
                  // as it dissolves.
                  child: still
                      ? child
                      : Transform.scale(scale: 1 + 0.04 * _fade.value, child: child),
                ),
                child: SplashScreen(
                  onIntroDone: () {
                    _introDone = true;
                    _maybeExit();
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
