import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/wallet_setup_flow.dart';
import 'package:zunia_mobile/screens/wallets_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Bottom sheet for switching account. It overlays the page rather than
/// expanding inline, so nothing below shifts; a tap switches at once (the
/// phrase and the account change in the same frame) and closes the sheet.
Future<void> showWalletSwitcher(BuildContext context) {
  return showZuniaSheet<void>(
    context,
    title: 'Accounts',
    builder: (_) => const _WalletSwitcherSheet(),
  );
}

class _WalletSwitcherSheet extends ConsumerWidget {
  const _WalletSwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    final active = wallet.active;
    // Watched here, in build, not in the list's item builder.
    final addresses = {
      for (final a in wallet.accounts) a.id: accountAddress(ref, a),
    };
    // The sheet's own context is gone once it pops; push from the page's.
    final page = Navigator.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: wallet.accounts.length,
            itemBuilder: (_, i) {
              final account = wallet.accounts[i];
              final address = addresses[account.id];
              return AccountRow(
                account: account,
                active: account.id == active?.id,
                subtitle: address == null
                    ? (account.isHdChild ? 'From the first phrase' : 'Own phrase')
                    : truncateAddress(address),
                onTap: () {
                  switchToAccount(ref, account);
                  Navigator.of(context).pop();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: ZuniaButton(
                label: 'Add account',
                leading: const Icon(Icons.add),
                onPressed: () {
                  final host = page.context;
                  page.pop();
                  AddAccountScreen.start(host);
                },
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: ZuniaButton(
                label: 'Manage',
                variant: ZuniaButtonVariant.secondary,
                onPressed: () {
                  page.pop();
                  page.push(
                    MaterialPageRoute<void>(
                      builder: (_) => const WalletsScreen(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
