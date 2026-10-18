import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Brand field drawn over the app while it is in the switcher / background,
/// so the thumbnail shows no balance or address. Android only: iOS draws its
/// own cover natively (AppDelegate), and Android 13+ also drops the
/// thumbnail at the source (`setRecentsScreenshotEnabled(false)`).
class AppSwitcherCover extends StatelessWidget {
  const AppSwitcherCover({super.key});

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: s.bg,
        child: Center(
          child: Image.asset(
            'assets/brand/icon.png',
            width: 64,
            height: 64,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
