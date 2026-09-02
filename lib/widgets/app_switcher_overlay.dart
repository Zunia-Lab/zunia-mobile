import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen brand blur shown while the app is in the switcher / background.
class AppSwitcherOverlay extends StatelessWidget {
  const AppSwitcherOverlay({
    super.key,
    required this.child,
    required this.obscured,
  });

  final Widget child;
  final bool obscured;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (obscured)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/brand/icon.png',
                      width: 64,
                      height: 64,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'zunia',
                      style: zuniaSans(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
