import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/settings_tiles.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Accounts derived from the one phrase: add, rename and switch.
class WalletsScreen extends ConsumerWidget {
  const WalletsScreen({super.key});

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    WalletAccount account,
  ) async {
    final controller = TextEditingController(text: account.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename wallet'),
        content: ZuniaInput(controller: controller, label: 'Name'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      await ref
          .read(walletProvider.notifier)
          .renameAccount(account.id, controller.text.trim());
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final primary = accounts.isEmpty ? null : accounts.first.address;

    return Scaffold(
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Wallets',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              SettingsGroup(
                label: 'Accounts',
                children: [
                  for (final account in wallet.accounts)
                    SettingsRow(
                      title: account.name,
                      description: account.id == wallet.active?.id
                          ? (primary == null
                              ? "Active · m/44'/…/${account.index}'"
                              : 'Active · ${truncateAddress(primary)}')
                          : "Derivation index ${account.index}",
                      leading: ZuniaWalletAvatar(
                        seed: account.id == wallet.active?.id
                            ? (primary ?? account.id)
                            : account.id,
                        size: 26,
                        semanticLabel: account.name,
                      ),
                      trailing: IconButton(
                        tooltip: 'Rename',
                        onPressed: () => _rename(context, ref, account),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                      onTap: () => ref
                          .read(walletProvider.notifier)
                          .selectAccount(account.id),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'One phrase, many accounts',
                body:
                    'Every account here comes from the same recovery phrase at '
                    'a different derivation index. Backing up the phrase backs '
                    'up all of them.',
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Add account',
            size: ZuniaButtonSize.lg,
            leading: const Icon(Icons.add),
            onPressed: () => ref
                .read(walletProvider.notifier)
                .addAccount('Account ${wallet.accounts.length + 1}'),
          ),
        ),
      ),
    );
  }
}
