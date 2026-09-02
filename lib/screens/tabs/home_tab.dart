import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/screens/chain_detail_screen.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/receive_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/screens/tabs/swap_tab.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Portfolio home: balance header, quick actions, holdings per chain.
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  String _tab = 'tokens';

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final balances = ref.watch(balancesProvider);
    final verified = ref.watch(backupVerifiedProvider);

    return DecoratedBox(
      decoration: BoxDecoration(gradient: s.screenGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WalletHeader(onOpenNetworks: () => _open(const NetworksScreen())),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(balancesProvider),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                children: [
                  verified.maybeWhen(
                    data: (ok) => ok ||
                            !MnemonicSecurityConfig.persistentUnverifiedBanner
                        ? const SizedBox.shrink()
                        : const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: ZuniaCallout(
                              tone: ZuniaCalloutTone.warning,
                              title: 'Backup not verified',
                              body:
                                  'Confirm your recovery phrase before you fund '
                                  'this wallet.',
                            ),
                          ),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const ZuniaSectionLabel('Total balance'),
                  const SizedBox(height: 10),
                  _TotalBalance(
                    accounts: accounts,
                    balances: balances.valueOrNull ?? const {},
                    hidden: prefs.hideAmounts,
                    liveReads: prefs.liveReads,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      ZuniaQuickAction(
                        label: 'Send',
                        icon: Icons.arrow_upward,
                        primary: true,
                        onTap: () => _open(const SendScreen()),
                      ),
                      const SizedBox(width: 8),
                      ZuniaQuickAction(
                        label: 'Receive',
                        icon: Icons.arrow_downward,
                        onTap: () => _open(const ReceiveScreen()),
                      ),
                      const SizedBox(width: 8),
                      ZuniaQuickAction(
                        label: 'Swap',
                        icon: Icons.swap_horiz,
                        onTap: () => _open(const _SwapSheet()),
                      ),
                      const SizedBox(width: 8),
                      ZuniaQuickAction(
                        label: 'Stake',
                        icon: Icons.diamond_outlined,
                        onTap: () {
                          if (accounts.isEmpty) return;
                          _open(
                            ChainDetailScreen(
                              chainId: accounts.first.chain.chainId,
                              initialTab: 'stake',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _Tabs(
                    value: _tab,
                    onChanged: (v) => setState(() => _tab = v),
                  ),
                  const SizedBox(height: 6),
                  ..._tabBody(accounts, balances.valueOrNull ?? const {}, prefs),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _tabBody(
    List<ChainAccount> accounts,
    Map<String, ChainBalance> balances,
    AppPreferences prefs,
  ) {
    if (accounts.isEmpty) {
      return [
        const SizedBox(height: 12),
        ZuniaEmptyState(
          title: 'No networks enabled',
          description:
              'Add a chain to start deriving addresses for this wallet.',
          action: ZuniaButton(
            label: 'Manage networks',
            size: ZuniaButtonSize.sm,
            variant: ZuniaButtonVariant.secondary,
            onPressed: () => _open(const NetworksScreen()),
          ),
        ),
      ];
    }

    switch (_tab) {
      case 'staked':
        final staked = accounts
            .where((a) => (balances[a.chain.chainId]?.staked ?? '0') != '0')
            .toList();
        if (staked.isEmpty) {
          return const [
            SizedBox(height: 12),
            ZuniaEmptyState(
              title: 'Nothing staked',
              description:
                  'Delegations and rewards across your chains appear here.',
            ),
          ];
        }
        return [
          for (final a in staked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _ChainRow(
                account: a,
                amount: balances[a.chain.chainId]!.staked,
                hidden: prefs.hideAmounts,
                onTap: () => _open(
                  ChainDetailScreen(
                    chainId: a.chain.chainId,
                    initialTab: 'stake',
                  ),
                ),
              ),
            ),
        ];

      case 'nfts':
        return const [
          SizedBox(height: 12),
          ZuniaEmptyState(
            title: 'No collectibles',
            description:
                'CW-721 and ICS-721 collections held by this wallet show here.',
          ),
        ];

      default:
        return [
          if (!prefs.liveReads)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: 'Live reads are off',
                body:
                    'Addresses are derived locally. Turn on live reads in '
                    'Settings to fetch balances from public endpoints.',
              ),
            ),
          for (final a in accounts)
            _ChainRow(
              account: a,
              amount: balances[a.chain.chainId]?.available,
              hidden: prefs.hideAmounts,
              onTap: () =>
                  _open(ChainDetailScreen(chainId: a.chain.chainId)),
            ),
        ];
    }
  }
}

class _TotalBalance extends StatelessWidget {
  const _TotalBalance({
    required this.accounts,
    required this.balances,
    required this.hidden,
    required this.liveReads,
  });

  final List<ChainAccount> accounts;
  final Map<String, ChainBalance> balances;
  final bool hidden;
  final bool liveReads;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    // No price feed ships with the wallet, so the hero shows the count of
    // funded chains rather than inventing a fiat total.
    final funded = balances.values
        .where((b) => b.available != '0' || b.staked != '0')
        .length;

    // Hero uses ZuniaAmount so fractional totals mute cents when present.
    final value = hidden
        ? '••••'
        : liveReads
            ? '$funded'
            : '—';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ZuniaAmount(value: value, hero: true),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            liveReads ? '${accounts.length} CHAINS' : 'NO PRICE FEED',
            style: zuniaMono(fontSize: 9.5, letterSpacing: 1.2, color: s.fgDim),
          ),
        ),
      ],
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.account,
    required this.amount,
    required this.hidden,
    required this.onTap,
  });

  final ChainAccount account;
  final String? amount;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final chain = account.chain;
    final display = amount == null
        ? '—'
        : formatBaseUnits(amount!, decimals: chain.coinDecimals);
    final balanceLabel = hidden ? '••••' : '$display ${chain.coinDenom}';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            decoration: BoxDecoration(
              gradient: s.surfaceRaisedGradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  ChainAvatar(chain: chain, size: 32),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chain.chainName,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.2,
                            color: s.fg,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          balanceLabel,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    hidden ? '••••' : display,
                    style: zuniaSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.3,
                      color: s.fg,
                      tabular: FontFeature.tabularFigures(),
                    ),
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

class _Tabs extends StatelessWidget {
  const _Tabs({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const _items = [
    (id: 'tokens', label: 'Tokens'),
    (id: 'staked', label: 'Staked'),
    (id: 'nfts', label: 'NFTs'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.line)),
      ),
      child: Row(
        children: _items.map((item) {
          final active = item.id == value;
          return Padding(
            padding: const EdgeInsets.only(right: 18),
            child: GestureDetector(
              onTap: () => onChanged(item.id),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? s.fg : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                ),
                child: Text(
                  item.label,
                  style: zuniaSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: active ? s.fg : s.fgDim,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Full-page swap reached from the home quick action, not the bottom tab.
class _SwapSheet extends StatelessWidget {
  const _SwapSheet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
              ),
            ),
            const Expanded(child: SwapTab()),
          ],
        ),
      ),
    );
  }
}
