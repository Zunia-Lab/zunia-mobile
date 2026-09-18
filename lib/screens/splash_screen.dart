import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Branded handoff between the native launch screen and the first real route.
///
/// Native [LaunchScreen] shows the mark alone. This screen continues on the
/// same dark field, then reveals the official stacked lockup so the cold start
/// never flashes white or a placeholder tile.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.message});

  /// Optional status under the lockup (e.g. boot error text).
  final String? message;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _bloom;
  late final Animation<double> _lockupOpacity;
  late final Animation<double> _lockupScale;
  late final Animation<double> _haze;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _bloom = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
    );
    _haze = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _lockupOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.12, 0.55, curve: Curves.easeOut),
    );
    _lockupScale = Tween<double>(begin: 0.92, end: 1).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.12, 0.65, curve: Curves.easeOutCubic),
      ),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    const bg = Color(0xFF0B0A09);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: bg,
      ),
      child: Scaffold(
        backgroundColor: bg,
        body: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // Warm top wash so the field is not a flat void.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(
                            bg,
                            s.accent,
                            0.07 * _haze.value,
                          )!,
                          bg,
                          bg,
                        ],
                        stops: const [0, 0.45, 1],
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(0, -0.12),
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.9 * _bloom.value,
                      child: Container(
                        width: 380,
                        height: 380,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              s.accent.withValues(alpha: 0.38 * s.bloom),
                              s.accent.withValues(alpha: 0.08 * s.bloom),
                              s.accent.withValues(alpha: 0),
                            ],
                            stops: const [0, 0.42, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(
                          opacity: _lockupOpacity.value.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: _lockupScale.value,
                            child: Image.asset(
                              'assets/brand/splash-lockup.png',
                              width: 220,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              semanticLabel: 'Zunia',
                            ),
                          ),
                        ),
                        if (widget.message != null) ...[
                          const SizedBox(height: 28),
                          Text(
                            widget.message!,
                            textAlign: TextAlign.center,
                            style: zuniaSans(
                              fontSize: 13,
                              height: 1.45,
                              color: s.danger,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
