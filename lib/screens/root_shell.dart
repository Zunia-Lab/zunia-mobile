import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/curated_dapps.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/activity_screen.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/bridge_screen.dart';
import 'package:zunia_mobile/screens/governance_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/nft_collection_screen.dart';
import 'package:zunia_mobile/screens/notifications_screen.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/dapp_connect_sheet.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/rewards_screen.dart';
import 'package:zunia_mobile/screens/sessions_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/screens/tabs/browser_tab.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/screens/tabs/home_tab.dart';
import 'package:zunia_mobile/screens/tabs/missions_tab.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Root navigation: five destinations in the bar, everything occasional behind
/// the right-hand drawer.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  static const _tabs = [
    ZuniaTabItem(
      id: 'home',
      label: 'Wallet',
      icon: Icons.account_balance_wallet_outlined,
      activeIcon: Icons.account_balance_wallet,
      cupertinoIcon: CupertinoIcons.house,
      cupertinoActiveIcon: CupertinoIcons.house_fill,
    ),
    ZuniaTabItem(
      id: 'swap',
      label: 'Swap',
      icon: Icons.swap_horiz_rounded,
      cupertinoIcon: CupertinoIcons.arrow_right_arrow_left,
    ),
    ZuniaTabItem(
      id: 'earn',
      label: 'Earn',
      icon: Icons.savings_outlined,
      activeIcon: Icons.savings,
      cupertinoIcon: CupertinoIcons.graph_circle,
      cupertinoActiveIcon: CupertinoIcons.graph_circle_fill,
    ),
    ZuniaTabItem(
      id: 'browser',
      label: 'Discover',
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore,
      cupertinoIcon: CupertinoIcons.compass,
      cupertinoActiveIcon: CupertinoIcons.compass_fill,
    ),
    ZuniaTabItem(
      id: 'activity',
      label: 'Activity',
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long,
      cupertinoIcon: CupertinoIcons.clock,
      cupertinoActiveIcon: CupertinoIcons.clock_fill,
    ),
  ];

  String _tab = 'home';
  final _subs = <StreamSubscription<dynamic>>[];
  ProviderSubscription<String?>? _accountSub;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_listenConnect);
  }

  void _listenConnect() {
    if (!mounted) return;
    final native = ref.read(nativeConnectProvider);
    final wc = ref.read(walletConnectProvider);
    final deep = ref.read(deepLinkHandlerProvider);

    _subs.add(native.changes.listen((_) => _showNextNativeRequest()));
    _subs.add(native.notices.listen(_onNativeNotice));
    _subs.add(wc.sessionProposals.listen(_onWcProposal));
    _subs.add(deep.links.listen(_onDeepLink));
    // By id, not derivation index: accounts with their own phrase all
    // derive at index 0, and switching between them must still re-announce.
    _accountSub = ref.listenManual<String?>(
      walletProvider.select((w) => w.active?.id),
      _onAccountChanged,
    );
    // Requests that arrived while the wallet was locked.
    _showNextNativeRequest();
  }

  Future<void> _onDeepLink(Uri uri) async {
    if (!mounted) return;
    final dappUrl = DeepLinkHandler.parseDappUrl(uri);
    if (dappUrl == null || dappUrl.isEmpty) return;
    await DappBrowserScreen.open(context, url: dappUrl);
  }

  void _onNativeNotice(NativeConnectNotice notice) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(notice.message)),
    );
  }

  /// Shows what sites asked for, one sheet at a time, oldest first.
  Future<void> _showNextNativeRequest() async {
    if (!mounted || _sheetOpen) return;
    final native = ref.read(nativeConnectProvider);
    final pending = native.pendingRequests;
    if (pending.isEmpty) return;
    final request = pending.first;
    _sheetOpen = true;
    try {
      switch (request) {
        case NativeConnectRequest():
          await showNativeConnectSheet(context, request: request);
          // Dismissed without a choice: that is a no.
          if (native.isPending(request)) await native.rejectConnect(request);
        case NativeSignRequest():
          await showNativeSignSheet(context, request: request);
          if (native.isPending(request)) await native.rejectSign(request);
      }
    } catch (e) {
      debugPrint('native request: $e');
    } finally {
      _sheetOpen = false;
    }
    unawaited(_showNextNativeRequest());
  }

  void _onAccountChanged(String? previous, String? next) {
    if (next == null || previous == null || previous == next) return;
    // The phrase is swapped before the account (WalletController._persist).
    final phrase = ref.read(phraseProvider);
    if (phrase == null) return;
    final active = ref.read(walletProvider).active;
    final index = active?.index ?? 0;
    final name = active?.name;
    unawaited(
      ref.read(nativeConnectProvider).switchAccount(
            accountIndex: index,
            accountsFor: (chainIds) => connectAccountsFor(
              phrase: phrase,
              accountIndex: index,
              chainIds: chainIds,
              accountName: name,
            ),
          ),
    );
  }

  Future<void> _onWcProposal(WcSessionProposal proposal) async {
    if (!mounted || _sheetOpen) return;
    _sheetOpen = true;
    try {
      await showDappConnectSheet(
        context,
        offer: DappConnectOffer.fromWcProposal(proposal),
      );
    } finally {
      _sheetOpen = false;
    }
    unawaited(_showNextNativeRequest());
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _accountSub?.close();
    super.dispose();
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _fromDrawer(Widget screen) {
    Navigator.of(context).pop();
    _open(screen);
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabs.indexWhere((t) => t.id == _tab);
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        endDrawer: _Drawer(
          ecosystemActive: _tab == 'browser',
          onEcosystem: () {
            Navigator.of(context).pop();
            setState(() => _tab = 'browser');
          },
          onNetworks: () => _fromDrawer(const NetworksScreen()),
          onBridge: () => _fromDrawer(const BridgeScreen()),
          onCollectibles: () => _fromDrawer(const NftCollectionScreen()),
          onGovernance: () => _fromDrawer(const GovernanceScreen()),
          onActivity: () => _fromDrawer(const ActivityScreen()),
          onMissions: () => _fromDrawer(const _MissionsPage()),
          onRewards: () => _fromDrawer(const RewardsScreen()),
          onPair: () {
            final nav = Navigator.of(context);
            nav.pop();
            nav
                .push<String>(
              MaterialPageRoute(builder: (_) => const QrScannerScreen()),
            )
                .then((code) {
              if (!context.mounted || code == null || code.isEmpty) return;
              handleScannedCode(context, ref, code);
            });
          },
          onSessions: () => _fromDrawer(const SessionsScreen()),
          onAddressBook: () => _fromDrawer(const AddressBookScreen()),
          onNotifications: () => _fromDrawer(const NotificationsScreen()),
          onSettings: () => _fromDrawer(const SettingsScreen()),
          onHelp: () {
            Navigator.of(context).pop();
            showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (ctx) {
                final sheet = ZuniaSemanticsExt.of(ctx);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: sheet.sheetGradient,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(30)),
                    border: Border(top: BorderSide(color: sheet.lineStrong)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
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
                                color: sheet.lineStrong,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Help',
                            style: zuniaSans(
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              color: sheet.fg,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Keys stay on this device. Signing uses the local '
                            'zunia-core kernel. Live reads talk only to public '
                            'chain endpoints listed in the registry.',
                            style: zuniaSans(
                              fontSize: 13,
                              height: 1.55,
                              color: sheet.fgMuted,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'LOCAL KEYS · APACHE 2.0',
                            textAlign: TextAlign.center,
                            style: zuniaMono(fontSize: 10, color: sheet.fgDim),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        bottomNavigationBar: ZuniaNavigationBar(
          items: _tabs,
          value: _tab,
          onChanged: (v) => setState(() => _tab = v),
        ),
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: index < 0 ? 0 : index,
            children: [
              // Home's Swap and Stake actions switch tabs here.
              HomeTab(onOpenTab: (id) => setState(() => _tab = id)),
              const SwapTab(),
              const EarnTab(),
              const BrowserTab(),
              const ActivityScreen(embedded: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _Drawer extends ConsumerWidget {
  const _Drawer({
    required this.ecosystemActive,
    required this.onEcosystem,
    required this.onNetworks,
    required this.onBridge,
    required this.onCollectibles,
    required this.onGovernance,
    required this.onActivity,
    required this.onMissions,
    required this.onRewards,
    required this.onPair,
    required this.onSessions,
    required this.onAddressBook,
    required this.onNotifications,
    required this.onSettings,
    required this.onHelp,
  });

  final bool ecosystemActive;
  final VoidCallback onEcosystem;
  final VoidCallback onNetworks;
  final VoidCallback onBridge;
  final VoidCallback onCollectibles;
  final VoidCallback onGovernance;
  final VoidCallback onActivity;
  final VoidCallback onMissions;
  final VoidCallback onRewards;
  final VoidCallback onPair;
  final VoidCallback onSessions;
  final VoidCallback onAddressBook;
  final VoidCallback onNotifications;
  final VoidCallback onSettings;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final address = ref.watch(primaryAddressProvider);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final wc = ref.watch(walletConnectProvider);
    final native = ref.watch(nativeConnectProvider);
    final sessionCount =
        wc.activeSessions.length + native.activeSessions.length;
    // The Discover list's own length, so the count follows its data file.
    final apps = ref.watch(curatedDappsProvider).valueOrNull?.dapps.length;

    return ZuniaDrawerPanel(
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: s.accentGradient,
              ),
              child: Text(
                wallet.active?.initial ?? 'W',
                style: zuniaMono(fontSize: 12, color: s.accentFg),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wallet.active?.name ?? 'Wallet',
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: s.fg,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    address == null ? 'Locked' : truncateAddress(address),
                    overflow: TextOverflow.ellipsis,
                    style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.close, size: 18, color: s.fgMuted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                s.accent.withValues(alpha: 0.24),
                s.info.withValues(alpha: 0.1),
              ],
            ),
          ),
          child: Row(
            children: [
              Text(
                'TOTAL',
                style: zuniaMono(
                  fontSize: 9,
                  letterSpacing: 1.2,
                  color: s.fgMuted,
                ),
              ),
              const Spacer(),
              Text(
                prefs.hideAmounts
                    ? '••••'
                    : '${accounts.length} chain${accounts.length == 1 ? '' : 's'}',
                style: zuniaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: s.fg,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const ZuniaSectionLabel('Explore'),
        const SizedBox(height: 6),
        ZuniaDrawerRow(
          icon: Icons.apps_outlined,
          label: 'Ecosystem',
          active: ecosystemActive,
          meta: apps?.toString(),
          onTap: onEcosystem,
        ),
        ZuniaDrawerRow(
          icon: Icons.hub_outlined,
          label: 'Manage networks',
          meta: '${wallet.enabledChainIds.length}',
          onTap: onNetworks,
        ),
        ZuniaDrawerRow(
          icon: Icons.compare_arrows,
          label: 'Bridge',
          onTap: onBridge,
        ),
        // Same place in the drawer as the other clients put it, so the three
        // products stay recognisably one product.
        ZuniaDrawerRow(
          icon: Icons.image_outlined,
          label: 'Collectibles',
          onTap: onCollectibles,
        ),
        ZuniaDrawerRow(
          icon: Icons.how_to_vote_outlined,
          label: 'Governance',
          onTap: onGovernance,
        ),
        ZuniaDrawerRow(
          icon: Icons.history,
          label: 'Activity',
          onTap: onActivity,
        ),
        ZuniaDrawerRow(
          icon: Icons.savings_outlined,
          label: 'Rewards',
          onTap: onRewards,
        ),
        ZuniaDrawerRow(
          icon: Icons.star_outline,
          label: 'Missions',
          onTap: onMissions,
        ),
        const SizedBox(height: 14),
        const ZuniaSectionLabel('Wallet'),
        const SizedBox(height: 6),
        ZuniaDrawerRow(
          icon: Icons.qr_code_scanner,
          label: 'Pair a device',
          onTap: onPair,
        ),
        ZuniaDrawerRow(
          icon: Icons.link,
          label: 'Connected apps',
          meta: sessionCount == 0 ? null : '$sessionCount',
          onTap: onSessions,
        ),
        ZuniaDrawerRow(
          icon: Icons.contacts_outlined,
          label: 'Address book',
          onTap: onAddressBook,
        ),
        ZuniaDrawerRow(
          icon: Icons.notifications_none,
          label: 'Notifications',
          badge: prefs.alerts,
          onTap: onNotifications,
        ),
        ZuniaDrawerRow(
          icon: Icons.settings_outlined,
          label: 'Settings & security',
          onTap: onSettings,
        ),
        ZuniaDrawerRow(
          icon: Icons.help_outline,
          label: 'Help',
          onTap: onHelp,
        ),
        const SizedBox(height: 18),
        ZuniaSegmented<ThemeMode>(
          value: prefs.themeMode == ThemeMode.system
              ? ThemeMode.dark
              : prefs.themeMode,
          onChanged: (mode) =>
              ref.read(preferencesProvider.notifier).setTheme(mode),
          options: const {ThemeMode.dark: 'Dark', ThemeMode.light: 'Light'},
        ),
      ],
    );
  }
}

/// Missions moved off the tab bar; it opens from the drawer as a page.
class _MissionsPage extends StatelessWidget {
  const _MissionsPage();

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Missions',
          onBack: () => Navigator.of(context).pop(),
          body: const MissionsTab(),
        ),
      ),
    );
  }
}
