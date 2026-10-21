import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shakes its child sideways, the way iOS and Android lock screens answer a
/// wrong passcode. Call [ShakeState.shake] through a `GlobalKey<ShakeState>`.
class Shake extends StatefulWidget {
  const Shake({super.key, required this.child});

  final Widget child;

  @override
  State<Shake> createState() => ShakeState();
}

class ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  void shake() {
    // Respect "reduce motion": the error text and haptic still say it.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        // Three decaying swings.
        final dx = math.sin(t * math.pi * 6) * 10 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
