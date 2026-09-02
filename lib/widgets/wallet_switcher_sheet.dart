import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/wallets_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Bottom sheet for switching between accounts derived from the same phrase.
/// It overlays the page rather than expanding inline, so nothing below shifts.
Future<void> showWalletSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _WalletSwitcherSheet(),
  );
}

class _WalletSwitcherSheet extends ConsumerWidget {
  const _WalletSwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final primary = accounts.isEmpty ? null : accounts.first.address;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.sheetGradient,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: s.lineStrong)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.lineStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(
                    'Wallets',
                    style: zuniaSans(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.3,
                      color: s.fg,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const WalletsScreen()),
                      );
                    },
                    child: Text(
                      'Manage',
                      style: zuniaMono(fontSize: 11, color: s.info),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: wallet.accounts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 9),
                  itemBuilder: (_, i) {
                    final account = wallet.accounts[i];
                    final active = account.id == wallet.active?.id;
                    return _AccountRow(
                      name: account.name,
                      seed: active && primary != null ? primary : account.id,
                      subtitle: active && primary != null
                          ? truncateAddress(primary)
                          : "Account ${account.index}",
                      active: active,
                      onTap: () {
                        ref
                            .read(walletProvider.notifier)
                            .selectAccount(account.id);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ZuniaButton(
                      label: 'Add wallet',
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await ref
                            .read(walletProvider.notifier)
                            .addAccount('Account ${wallet.accounts.length + 1}');
                      },
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: ZuniaButton(
                      label: 'Manage',
                      variant: ZuniaButtonVariant.secondary,
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const WalletsScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.name,
    required this.seed,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final String name;
  final String seed;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: active
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      s.accent.withValues(alpha: 0.3),
                      s.info.withValues(alpha: 0.12),
                    ],
                  )
                : s.surfaceRaisedGradient,
            border: Border.all(
              color: active
                  ? s.accent.withValues(alpha: 0.65)
                  : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                ZuniaWalletAvatar(
                  seed: seed,
                  size: 34,
                  semanticLabel: name,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                      ),
                    ],
                  ),
                ),
                if (active)
                  Text(
                    'ACTIVE',
                    style: zuniaMono(
                      fontSize: 9.5,
                      letterSpacing: 1,
                      color: s.info,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
