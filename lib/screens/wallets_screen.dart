import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/screens/backup_verify_screen.dart';
import 'package:zunia_mobile/screens/reveal_phrase_screen.dart';
import 'package:zunia_mobile/screens/wallet_setup_flow.dart';
import 'package:zunia_mobile/security/password_prompt.dart';
import 'package:zunia_mobile/security/vault_session.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Address of [account] on its first network, for the rows that list
/// accounts. Null while locked.
String? accountAddress(WidgetRef ref, WalletAccount account) {
  final session = ref.watch(sessionProvider);
  final phrase = session?.phraseFor(account.phraseId);
  if (phrase == null || !ChainCatalog.isLoaded) return null;
  final wallet = ref.watch(walletProvider);
  final chainIds = account.enabledChainIds ??
      (wallet.globalChainIds.isEmpty ? kDefaultChainIds : wallet.globalChainIds);
  for (final id in chainIds) {
    final chain = ChainCatalog.instance.find(id);
    if (chain == null) continue;
    try {
      return WalletKernel.instance
          .deriveAddress(phrase: phrase, chain: chain, accountIndex: account.index)
          .address;
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Switches account with a tick; the phrase swaps in the same frame.
Future<void> switchToAccount(WidgetRef ref, WalletAccount account) async {
  if (ref.read(walletProvider).active?.id == account.id) return;
  unawaited(ZuniaHaptics.selection());
  await ref.read(vaultSessionProvider).switchAccount(account.id);
}

/// Every account on this device: switch, add, rename, back up, remove.
class WalletsScreen extends ConsumerWidget {
  const WalletsScreen({super.key});

  Future<void> _actions(
    BuildContext context,
    WidgetRef ref,
    WalletAccount account,
  ) async {
    final wallet = ref.read(walletProvider);
    final info = wallet.phraseOf(account);
    final choice = await showZuniaActionSheet<String>(
      context,
      title: account.name,
      actions: [
        const ZuniaAlertAction(label: 'Rename', value: 'rename'),
        const ZuniaAlertAction(label: 'Show recovery phrase', value: 'reveal'),
        if (info != null && !info.backupVerified)
          const ZuniaAlertAction(label: 'Verify backup', value: 'verify'),
        if (wallet.accounts.length > 1)
          const ZuniaAlertAction(
            label: 'Remove from this device',
            value: 'remove',
            destructive: true,
          ),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'rename':
        await _rename(context, ref, account);
      case 'reveal':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RevealPhraseScreen(accountId: account.id),
          ),
        );
      case 'verify':
        await Navigator.of(context).push(
          MaterialPageRoute<bool>(
            builder: (_) => BackupVerifyScreen(phraseId: account.phraseId),
          ),
        );
      case 'remove':
        await _remove(context, ref, account);
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    WalletAccount account,
  ) async {
    final name = await showZuniaSheet<String>(
      context,
      title: 'Rename account',
      builder: (_) => _RenameSheet(account: account),
    );
    if (name == null || name.trim().isEmpty) return;
    await ref.read(vaultSessionProvider).renameAccount(account.id, name);
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    WalletAccount account,
  ) async {
    final wallet = ref.read(walletProvider);
    final sharesPhrase = wallet.accountsOf(account.phraseId).length > 1;
    final sure = await showZuniaConfirm(
      context,
      title: 'Remove ${account.name}?',
      message: sharesPhrase
          ? 'It disappears from this device. Its phrase stays, since another '
              'account here uses it.'
          : 'Its recovery phrase is erased from this device. You can restore '
              'the account later with that phrase, and only with it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!sure || !context.mounted) return;
    final session = ref.read(vaultSessionProvider);
    // The password, typed: removing keys is not something a glance at the
    // phone should be able to do.
    final done = await showPasswordPrompt(
      context,
      title: 'Remove ${account.name}',
      reason: 'Enter the wallet password to remove this account.',
      confirmLabel: 'Remove',
      check: (password) => session.removeAccount(account.id, password),
      throttle: session.throttle,
    );
    if (done == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('${account.name} removed')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final active = wallet.active;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Accounts',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
            children: [
              ZuniaListSection(
                header: '${wallet.accounts.length} '
                    'account${wallet.accounts.length == 1 ? '' : 's'}',
                footer: 'Tap an account to use it. One password unlocks them '
                    'all.',
                children: [
                  for (final account in wallet.accounts)
                    AccountRow(
                      account: account,
                      active: account.id == active?.id,
                      subtitle: _subtitle(ref, wallet, account),
                      onTap: () => switchToAccount(ref, account),
                      onMore: () => _actions(context, ref, account),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: Text(
                  'Each account added here has its own recovery phrase. Back '
                  'up every one: a phrase only restores its own account. '
                  'Accounts marked "from the first phrase" were added by an '
                  'earlier version and are backed up by that phrase.',
                  style: zuniaSans(fontSize: 12.5, height: 1.5, color: s.fgDim),
                ),
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Add account',
            size: ZuniaButtonSize.lg,
            leading: const Icon(Icons.add),
            onPressed: () => AddAccountScreen.start(context),
          ),
        ),
      ),
    );
  }

  String _subtitle(WidgetRef ref, WalletData wallet, WalletAccount account) {
    final address = accountAddress(ref, account);
    final info = wallet.phraseOf(account);
    final parts = <String>[
      if (address != null) truncateAddress(address),
      if (account.isHdChild)
        'from the first phrase · #${account.index}'
      else if (info != null && !info.backupVerified)
        'backup not verified',
    ];
    return parts.isEmpty ? 'Locked' : parts.join(' · ');
  }
}

/// One account: orb, name, address, and a "more" control. Shared with the
/// account switcher sheet.
class AccountRow extends StatelessWidget {
  const AccountRow({
    super.key,
    required this.account,
    required this.active,
    required this.subtitle,
    required this.onTap,
    this.onMore,
  });

  final WalletAccount account;
  final bool active;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return Semantics(
      selected: active,
      button: true,
      label: '${account.name}, $subtitle${active ? ', in use' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: _Pressable(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(cupertino ? 16 : 20, 10, 6, 10),
          child: Row(
            children: [
              ZuniaWalletAvatar(seed: account.avatar, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(
                        fontSize: 16,
                        fontWeight: cupertino ? FontWeight.w400 : FontWeight.w500,
                        letterSpacing: cupertino ? -0.3 : 0,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 11, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    cupertino ? CupertinoIcons.check_mark : Icons.check_circle,
                    size: cupertino ? 18 : 20,
                    color: s.accent,
                  ),
                ),
              if (onMore != null)
                IconButton(
                  tooltip: 'Options for ${account.name}',
                  onPressed: onMore,
                  icon: Icon(
                    cupertino ? CupertinoIcons.ellipsis_circle : Icons.more_vert,
                    size: 22,
                    color: s.fgMuted,
                  ),
                )
              else
                const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// A table-cell press on iOS (grey while held, no ripple), an ink ripple on
/// Android.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!ZuniaPlatform.isCupertino(context)) {
      return InkWell(onTap: widget.onTap, child: widget.child);
    }
    final s = ZuniaSemanticsExt.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: ColoredBox(
        color: _down ? s.statePress : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

class _RenameSheet extends StatefulWidget {
  const _RenameSheet({required this.account});

  final WalletAccount account;

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.account.name);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.selection =
          TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
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
    if (_canSave) Navigator.of(context).pop(_trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ZuniaWalletAvatar(seed: widget.account.avatar, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Only the label on this device changes. Addresses and keys '
                  'stay the same.',
                  style: zuniaSans(fontSize: 13, height: 1.4, color: s.fgMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ZuniaInput(
            controller: _controller,
            label: 'DISPLAY NAME',
            hint: 'Account name',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 18),
          ZuniaButton(
            label: 'Save name',
            size: ZuniaButtonSize.lg,
            onPressed: _canSave ? _save : null,
          ),
        ],
      ),
    );
  }
}
