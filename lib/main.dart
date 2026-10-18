import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/screens/root_shell.dart';
import 'package:zunia_mobile/screens/root_warning_screen.dart';
import 'package:zunia_mobile/screens/splash_screen.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/push_messaging.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/preferences.dart';
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
  runApp(const ProviderScope(child: ZuniaApp()));
}

class ZuniaApp extends ConsumerStatefulWidget {
  const ZuniaApp({super.key});

  @override
  ConsumerState<ZuniaApp> createState() => _ZuniaAppState();
}

class _ZuniaAppState extends ConsumerState<ZuniaApp> with WidgetsBindingObserver {
  final _navKey = GlobalKey<NavigatorState>();
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
      builder: (context, child) {
        return ScreenSecurityScope(child: child ?? const SizedBox.shrink());
      },
      home: const _AppGate(),
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
    if (session != null) {
      return const RootShell();
    }

    final gate = ref.watch(appGateProvider);
    return gate.when(
      data: (g) {
        switch (g) {
          case AppGate.onboarding:
            return const OnboardingScreen();
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

/// Shown instead of the wallet when the build is missing its signing core.
class KernelMissingScreen extends StatelessWidget {
  const KernelMissingScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: s.screenMid,
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
