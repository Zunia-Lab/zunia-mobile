import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/activity/bundled_links.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/root_shell.dart';
import 'package:zunia_mobile/screens/root_warning_screen.dart';
import 'package:zunia_mobile/screens/splash_screen.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/screens/welcome_screen.dart';
import 'package:zunia_mobile/security/app_restart.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_mobile/security/security_shell.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/push_messaging.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';
import 'package:zunia_ui/zunia_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw under the status and navigation bars, as Android 15 requires and as
  // every native app does; screens pad themselves with SafeArea.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarColor: Colors.transparent,
    ),
  );
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // Chain metadata backs address derivation, so nothing can render before it.
  await ChainCatalog.load();
  // Chains the user added by hand are part of the catalog from the first
  // frame, or a custom chain enabled before a restart derives no address.
  await hydrateCustomChains();
  // The stored theme and live-reads choice, before anything renders or reads.
  await PreferencesController.preload();
  // Token names (the hash-verified table) are read synchronously by every
  // balance row; the proven traces and explorer links can arrive a moment later.
  await TokenRegistry.load();
  unawaited(hydrateTokenIdentities());
  unawaited(loadBundledLinks());
  // AppRestart: removing the wallet starts the app over with fresh providers.
  runApp(
    AppRestart(
      builder: (key) => ProviderScope(key: key, child: const ZuniaApp()),
    ),
  );
}

class ZuniaApp extends ConsumerStatefulWidget {
  const ZuniaApp({super.key});

  @override
  ConsumerState<ZuniaApp> createState() => _ZuniaAppState();
}

class _ZuniaAppState extends ConsumerState<ZuniaApp> with WidgetsBindingObserver {
  late final _navKey = ref.read(appNavigatorKeyProvider);
  DeepLinkHandler? _deepLinks;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_bootstrap);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sockets often die while the app is in the background.
    if (state == AppLifecycleState.resumed) {
      ref.read(nativeConnectProvider).resume();
    } else if (state == AppLifecycleState.paused) {
      // A later answer was not prompted by the link that opened the app.
      ref.read(nativeConnectProvider).onBackground();
    }
  }

  Future<void> _bootstrap() async {
    await PushMessaging.init();
    await ref.read(nativeConnectProvider).restore();
    _deepLinks = ref.read(deepLinkHandlerProvider);
    await _deepLinks!.start();
    final report = await DeviceIntegrity.check();
    if (report.isCompromised) {
      _navKey.currentState?.push(
        MaterialPageRoute<void>(builder: (_) => const RootWarningScreen()),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinks?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode =
        ref.watch(preferencesProvider.select((p) => p.themeMode));

    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Zunia',
      debugShowCheckedModeBanner: false,
      theme: ZuniaTheme.light(),
      darkTheme: ZuniaTheme.dark(),
      themeMode: themeMode,
      // Auto-lock, the lock screen over the app, the app-switcher cover.
      builder: (context, child) {
        // The design's sizes read a touch small on a phone held at arm's
        // length: everything is set 8% larger, on top of the user's own text
        // size, which keeps the hierarchy and still honours accessibility.
        final media = MediaQuery.of(context);
        final user = media.textScaler.scale(16) / 16;
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear((user * kTextBoost).clamp(0.8, 2.2)),
          ),
          child: SecurityShell(child: child ?? const SizedBox.shrink()),
        );
      },
      home: const SplashGate(child: _AppGate()),
    );
  }
}

class _AppGate extends ConsumerWidget {
  const _AppGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Without the kernel nothing can be derived, opened or signed.
    if (!WalletKernel.instance.isAvailable) {
      return KernelMissingScreen(reason: WalletKernel.instance.loadError);
    }
    final session = ref.watch(sessionProvider);
    // Once unlocked, a lock covers the shell (SecurityShell) instead of
    // replacing it, so whatever was open is still there after unlocking.
    if (session != null || ref.watch(hasUnlockedProvider)) {
      return const RootShell();
    }

    final gate = ref.watch(appGateProvider);
    return gate.when(
      data: (g) {
        switch (g) {
          case AppGate.onboarding:
            return const WelcomeScreen();
          case AppGate.unlock:
          case AppGate.ready:
            return const UnlockScreen();
          case AppGate.loading:
            return const SplashScreen();
        }
      },
      loading: () => const SplashScreen(),
      error: (e, _) => SplashScreen(message: 'Startup error: $e'),
    );
  }
}

/// How much larger than the design's sizes text is drawn (see the app builder).
const double kTextBoost = 1.08;

/// Shown instead of the wallet when the build is missing its signing core.
class KernelMissingScreen extends StatelessWidget {
  const KernelMissingScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaCallout(
                tone: ZuniaCalloutTone.danger,
                title: 'This build cannot sign',
                body: 'Its signing core (zunia-core) did not load, so Zunia will not '
                    'open your wallet. Install the app from the App Store or Google '
                    'Play. Your recovery phrase is not affected.',
              ),
              if (reason != null) ...[
                const SizedBox(height: 16),
                Text(reason!, style: zuniaMono(fontSize: 11, color: s.fgDim)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
