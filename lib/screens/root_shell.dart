import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/activity_screen.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/bridge_screen.dart';
import 'package:zunia_mobile/screens/connect_inbox.dart';
import 'package:zunia_mobile/screens/governance_screen.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/nft_collection_screen.dart';
import 'package:zunia_mobile/screens/notifications_screen.dart';
import 'package:zunia_mobile/screens/pair_device.dart';
import 'package:zunia_mobile/screens/sessions_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/screens/tabs/browser_tab.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/screens/tabs/home_tab.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
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
  // Browser sits in the middle: it is where a site meets the wallet.
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
      id: 'browser',
      label: 'Browser',
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore,
      cupertinoIcon: CupertinoIcons.compass,
      cupertinoActiveIcon: CupertinoIcons.compass_fill,
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
      id: 'gov',
      label: 'Gov',
      icon: Icons.how_to_vote_outlined,
      activeIcon: Icons.how_to_vote,
      cupertinoIcon: CupertinoIcons.checkmark_seal,
      cupertinoActiveIcon: CupertinoIcons.checkmark_seal_fill,
    ),
  ];

  String _tab = 'home';
  StreamSubscription<dynamic>? _noticeTaps;

  @override
  void initState() {
    super.initState();
    Future.microtask(_listenNotices);
  }

  /// The notice engine watches chains while the wallet is unlocked; a tapped
  /// device notification, or a notice asking for a tab, lands here. Requests
  /// from sites are ConnectInbox's.
  void _listenNotices() {
    if (!mounted) return;
    _noticeTaps = ref.read(noticeEngineProvider.notifier).taps.listen((target) {
      if (!mounted) return;
      if (target == null) {
        _open(const NotificationsScreen());
      } else {
        openNoticeTarget(context, ref, target);
      }
    });
    ref.listenManual<String?>(noticeTabRequestProvider, (_, tab) {
      if (tab == null || !mounted) return;
      setState(() => _tab = tab);
      ref.read(noticeTabRequestProvider.notifier).state = null;
    });
  }

  @override
  void dispose() {
    _noticeTaps?.cancel();
    super.dispose();
  }
  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _fromDrawer(Widget screen) {
    Navigator.of(context).pop();
    _open(screen);
  }

  // Requests from connected sites and apps show over whichever tab is open.
  @override
  Widget build(BuildContext context) {
    // Start the notice engine before any header reads its unread count.
    ref.listen(noticeEngineProvider, (_, _) {});
    return ConnectInbox(child: _shell(context));
  }

  Widget _shell(BuildContext context) {
    final index = _tabs.indexWhere((t) => t.id == _tab);
    return ZuniaBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // What the tab bar shows is not repeated here.
        endDrawer: _Drawer(
          onActivity: () => _fromDrawer(const ActivityScreen()),
          onNetworks: () => _fromDrawer(const NetworksScreen()),
          onBridge: () => _fromDrawer(const BridgeScreen()),
          onCollectibles: () => _fromDrawer(const NftCollectionScreen()),
          onMissions: () => _fromDrawer(const _MissionsPage()),
          onPair: () {
            Navigator.of(context).pop();
            unawaited(openPairDevice(context, ref));
          },
          onSessions: () => _fromDrawer(const SessionsScreen()),
          onAddressBook: () => _fromDrawer(const AddressBookScreen()),
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
              const BrowserTab(),
              const EarnTab(),
              const GovernanceScreen(embedded: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _Drawer extends ConsumerWidget {
  const _Drawer({
    required this.onActivity,
    required this.onNetworks,
    required this.onBridge,
    required this.onCollectibles,
    required this.onMissions,
    required this.onPair,
    required this.onSessions,
    required this.onAddressBook,
    required this.onSettings,
    required this.onHelp,
  });

  final VoidCallback onActivity;
  final VoidCallback onNetworks;
  final VoidCallback onBridge;
  final VoidCallback onCollectibles;
  final VoidCallback onMissions;
  final VoidCallback onPair;
  final VoidCallback onSessions;
  final VoidCallback onAddressBook;
  final VoidCallback onSettings;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final address = ref.watch(primaryAddressProvider);
    final prefs = ref.watch(preferencesProvider);
    final wc = ref.watch(walletConnectProvider);
    final native = ref.watch(nativeConnectProvider);
    final sessionCount =
        wc.activeSessions.length + native.activeSessions.length;
    // The Discover list's own length, so the count follows its data file.
    return ZuniaDrawerPanel(
      children: [
        Row(
          children: [
            // The same orb as the Wallet header, so the account looks the
            // same wherever it appears.
            ZuniaWalletAvatar(
              seed: wallet.active?.id ?? wallet.active?.name ?? 'Wallet',
              size: 38,
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
        const SizedBox(height: 14),
        const ZuniaSectionLabel('Explore'),
        const SizedBox(height: 6),
        ZuniaDrawerRow(
          icon: Icons.receipt_long_outlined,
          label: 'Activity',
          onTap: onActivity,
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
          icon: Icons.star_outline,
          label: 'Missions',
          meta: 'Soon',
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
        // Dark, Light and Auto, as the extension's drawer offers them; Auto
        // used to show as Dark here, so the drawer misreported the setting.
        ZuniaSegmented<ThemeMode>(
          value: prefs.themeMode,
          onChanged: (mode) =>
              ref.read(preferencesProvider.notifier).setTheme(mode),
          options: const {
            ThemeMode.dark: 'Dark',
            ThemeMode.light: 'Light',
            ThemeMode.system: 'Auto',
          },
        ),
      ],
    );
  }
}

/// Missions are not live yet: the page says so instead of showing a
/// checklist that earns nothing.
class _MissionsPage extends StatelessWidget {
  const _MissionsPage();

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: zuniaGroundTop(context),
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Missions',
          onBack: () => Navigator.of(context).pop(),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: s.accentGradient,
                    ),
                    child: const Icon(Icons.star_rounded, size: 36, color: Colors.white),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Coming soon',
                    style: zuniaSans(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.6,
                      color: s.fg,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Missions will reward you for exploring the Cosmos with Zunia. '
                    'They are not live yet.',
                    textAlign: TextAlign.center,
                    style: zuniaSans(fontSize: 15, height: 1.5, color: s.fgMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
