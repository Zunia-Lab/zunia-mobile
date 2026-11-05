/// Wraps the whole app (MaterialApp.builder): auto-lock, the lock screen over
/// whatever was open, the app-switcher cover, and the signing gate's
/// context-free handler.
///
/// Locking covers the app rather than replacing it. Every open screen stays
/// as it was underneath (a half-typed send, the tab, the scroll position),
/// but it cannot be seen, touched, read by a screen reader or navigated with
/// the back button, and nothing in it can sign: the phrases are gone from
/// memory until the next unlock. Screens that show a secret close themselves
/// on lock (see [lockEpochProvider]).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/security/auto_lock.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/security/signing_gate.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/widgets/app_switcher_overlay.dart';

/// The app's root navigator. One per ProviderScope, so restarting the scope
/// (after the wallet is removed) starts from a fresh navigation stack.
final appNavigatorKeyProvider =
    Provider<GlobalKey<NavigatorState>>((ref) => GlobalKey<NavigatorState>());

class SecurityShell extends ConsumerStatefulWidget {
  const SecurityShell({super.key, required this.child});

  /// The app's Navigator, from MaterialApp.builder.
  final Widget child;

  @override
  ConsumerState<SecurityShell> createState() => _SecurityShellState();
}

class _SecurityShellState extends ConsumerState<SecurityShell>
    with WidgetsBindingObserver {
  late final AutoLockController _autoLock;
  bool _covered = false;
  Route<void>? _guard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoLock = AutoLockController(
      delay: () => ref.read(securitySettingsProvider).autoLock,
      onLock: () => ref.read(vaultSessionProvider).lock(),
    );
    ScreenCaptureMonitor.start();
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = ref.read(appNavigatorKeyProvider);
    SigningGate.install(
      (reason) => confirmSigningWith(
        container: container,
        navigator: navigator,
        reason: reason,
      ),
    );
    if (ref.read(sessionProvider) != null) _autoLock.start();
    ref.listenManual(sessionProvider, (previous, next) {
      if (next != null && previous == null) {
        _autoLock.start();
        _removeGuard();
      } else if (next == null && previous != null) {
        _autoLock.stop();
        _onLocked();
      }
    }, fireImmediately: false);
    ref.listenManual(
      securitySettingsProvider.select((s) => s.autoLock),
      (_, _) => _autoLock.reschedule(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoLock.stop();
    SigningGate.install(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _autoLock.backgrounded();
        _setCovered(true);
      case AppLifecycleState.inactive:
        // iOS covers natively (AppDelegate); a Flutter frame drawn now is
        // not reliably in the switcher snapshot. Android < 13 has no native
        // way short of FLAG_SECURE everywhere, so the cover is drawn here.
        if (_flutterCover) _setCovered(true);
      case AppLifecycleState.resumed:
        _autoLock.foregrounded();
        _setCovered(false);
    }
  }

  bool get _flutterCover => !kIsWeb && Platform.isAndroid;

  void _setCovered(bool value) {
    if (value && !_flutterCover) return;
    // A biometric prompt makes the app look inactive; that is not leaving.
    if (value && ref.read(biometricVaultProvider).promptActive) return;
    if (_covered == value || !mounted) return;
    setState(() => _covered = value);
  }

  void _onLocked() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!ref.read(hasUnlockedProvider)) return;
    final navigator = ref.read(appNavigatorKeyProvider).currentState;
    if (navigator == null || _guard != null) return;
    // Holds the back button while locked, so nothing navigates underneath.
    final guard = _LockGuardRoute();
    _guard = guard;
    navigator.push(guard);
  }

  void _removeGuard() {
    final guard = _guard;
    _guard = null;
    if (guard == null || !guard.isActive) return;
    guard.navigator?.removeRoute(guard);
  }

  @override
  Widget build(BuildContext context) {
    final locked =
        ref.watch(hasUnlockedProvider) && ref.watch(sessionProvider) == null;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _autoLock.touch(),
      onPointerSignal: (_) => _autoLock.touch(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: locked,
            child: TickerMode(
              enabled: !locked,
              child: AbsorbPointer(absorbing: locked, child: widget.child),
            ),
          ),
          if (locked) const _LockLayer(),
          if (_covered) const AppSwitcherCover(),
        ],
      ),
    );
  }
}

/// The unlock screen with a navigator of its own, so it can push "Forgot
/// password" and show dialogs while the app's navigator stays untouched.
class _LockLayer extends StatelessWidget {
  const _LockLayer();

  @override
  Widget build(BuildContext context) {
    // MaterialApp's hero controller belongs to the app's navigator; a
    // navigator may not share it.
    return HeroControllerScope.none(
      child: Navigator(
        onGenerateInitialRoutes: (_, _) => [
          MaterialPageRoute<void>(
            builder: (_) => const UnlockScreen(overlay: true),
          ),
        ],
      ),
    );
  }
}

class _LockGuardRoute extends PageRoute<void> {
  _LockGuardRoute();

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return const PopScope(canPop: false, child: SizedBox.shrink());
  }
}
