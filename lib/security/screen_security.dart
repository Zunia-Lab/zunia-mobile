import 'package:flutter/material.dart';
import 'package:zunia_mobile/security/flag_secure.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/widgets/app_switcher_overlay.dart';

/// Wraps the app to apply mnemonic-security display policy:
/// FLAG_SECURE, app-switcher blur, and lifecycle re-blur hooks.
class ScreenSecurityScope extends StatefulWidget {
  const ScreenSecurityScope({
    super.key,
    required this.child,
    this.enableFlagSecure = MnemonicSecurityConfig.androidFlagSecure,
  });

  final Widget child;
  final bool enableFlagSecure;

  @override
  State<ScreenSecurityScope> createState() => _ScreenSecurityScopeState();
}

class _ScreenSecurityScopeState extends State<ScreenSecurityScope>
    with WidgetsBindingObserver {
  bool _obscured = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableFlagSecure) {
      FlagSecure.setEnabled(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.enableFlagSecure) {
      FlagSecure.setEnabled(false);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!MnemonicSecurityConfig.hideInAppSwitcher &&
        !MnemonicSecurityConfig.autoReblurOnBackground) {
      return;
    }
    final hide = state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    if (hide != _obscured) {
      setState(() => _obscured = hide);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSwitcherOverlay(
      obscured: _obscured && MnemonicSecurityConfig.hideInAppSwitcher,
      child: widget.child,
    );
  }
}
