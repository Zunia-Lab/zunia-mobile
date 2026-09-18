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
    final accounts = ref.read(chainAccountsProvider);
    final primary = accounts.isEmpty ? null : accounts.first.address;
    final seed = account.id == ref.read(walletProvider).active?.id
        ? (primary ?? account.id)
        : account.id;

    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RenameWalletSheet(
        account: account,
        seed: seed,
        addressHint: account.id == ref.read(walletProvider).active?.id &&
                primary != null
            ? truncateAddress(primary)
            : "m/44'/…/${account.index}'",
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(walletProvider.notifier).renameAccount(account.id, name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final primary = accounts.isEmpty ? null : accounts.first.address;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
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

class _RenameWalletSheet extends StatefulWidget {
  const _RenameWalletSheet({
    required this.account,
    required this.seed,
    required this.addressHint,
  });

  final WalletAccount account;
  final String seed;
  final String addressHint;

  @override
  State<_RenameWalletSheet> createState() => _RenameWalletSheetState();
}

class _RenameWalletSheetState extends State<_RenameWalletSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.account.name);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _trimmed => _controller.text.trim();

  bool get _canSave =>
      _trimmed.isNotEmpty && _trimmed != widget.account.name.trim();

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(_trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: s.sheetGradient,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          border: Border(top: BorderSide(color: s.lineStrong)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: s.lineStrong,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    ZuniaWalletAvatar(
                      seed: widget.seed,
                      size: 44,
                      semanticLabel: widget.account.name,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Rename wallet',
                            style: zuniaSans(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.3,
                              color: s.fg,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.addressHint,
                            style: zuniaMono(
                              fontSize: 11.5,
                              color: s.fgMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Only the label on this device changes. Addresses and keys stay the same.',
                  style: zuniaSans(
                    fontSize: 13,
                    height: 1.35,
                    color: s.fgMuted,
                  ),
                ),
                const SizedBox(height: 16),
                ZuniaInput(
                  controller: _controller,
                  label: 'Display name',
                  hint: 'Account name',
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 20),
                ZuniaButton(
                  label: 'Save name',
                  size: ZuniaButtonSize.lg,
                  onPressed: _canSave ? _save : null,
                ),
                const SizedBox(height: 6),
                ZuniaButton(
                  label: 'Cancel',
                  variant: ZuniaButtonVariant.ghost,
                  size: ZuniaButtonSize.lg,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
