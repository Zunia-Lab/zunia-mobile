import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/onboarding_screen.dart';
import 'package:zunia_mobile/screens/root_shell.dart';
import 'package:zunia_mobile/screens/root_warning_screen.dart';
import 'package:zunia_mobile/screens/unlock_screen.dart';
import 'package:zunia_mobile/security/device_integrity.dart';
import 'package:zunia_mobile/security/screen_security.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/push_messaging.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_ui/zunia_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Chain metadata backs address derivation, so nothing can render before it.
  await ChainCatalog.load();
  runApp(const ProviderScope(child: ZuniaApp()));
}

class ZuniaApp extends ConsumerStatefulWidget {
  const ZuniaApp({super.key});

  @override
  ConsumerState<ZuniaApp> createState() => _ZuniaAppState();
}

class _ZuniaAppState extends ConsumerState<ZuniaApp> {
  final _navKey = GlobalKey<NavigatorState>();
  DeepLinkHandler? _deepLinks;

  @override
  void initState() {
    super.initState();
    Future.microtask(_bootstrap);
  }

  Future<void> _bootstrap() async {
    await PushMessaging.init();
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
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
        }
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: Center(child: Text('Startup error: $e')),
      ),
    );
  }
}
