import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/wallet_setup_flow.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Which flow onboarding opens on.
enum OnboardingMode { create, import }

/// Create or restore the first account. The steps themselves are
/// [WalletSetupFlow], shared with "Add account".
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.initialMode});

  /// Opens straight on that flow, skipping the welcome step (the app's
  /// welcome screen asked already). Back from its first step pops.
  final OnboardingMode? initialMode;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  OnboardingMode? _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  void _exitFlow() {
    final navigator = Navigator.of(context);
    if (widget.initialMode != null && navigator.canPop()) {
      navigator.pop();
      return;
    }
    setState(() => _mode = null);
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: mode == null
            ? _Welcome(onChoose: (m) => setState(() => _mode = m))
            : WalletSetupFlow(
                key: ValueKey(mode),
                mode: mode,
                onExit: _exitFlow,
              ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onChoose});

  final ValueChanged<OnboardingMode> onChoose;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return ZuniaScreenScaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 64),
            Center(
              child: Image.asset(
                'assets/brand/icon.png',
                width: 66,
                height: 61,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(height: 26),
            Semantics(
              header: true,
              child: Text(
                'Your keys.\nEvery chain.',
                textAlign: TextAlign.center,
                style: zuniaSans(
                  fontSize: 27,
                  height: 1.15,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.9,
                  color: s.fg,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'One wallet for the Cosmos ecosystem. Keys are sealed on this '
              'device and never leave it.',
              textAlign: TextAlign.center,
              style: zuniaSans(fontSize: 13.5, height: 1.6, color: s.fgMuted),
            ),
          ],
        ),
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZuniaButton(
            label: 'Create a new wallet',
            size: ZuniaButtonSize.lg,
            onPressed: () => onChoose(OnboardingMode.create),
          ),
          const SizedBox(height: 10),
          ZuniaButton(
            label: 'I have a recovery phrase',
            size: ZuniaButtonSize.lg,
            variant: ZuniaButtonVariant.secondary,
            onPressed: () => onChoose(OnboardingMode.import),
          ),
        ],
      ),
    );
  }
}
