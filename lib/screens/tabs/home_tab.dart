/// Wallet home: the account, the total in the user's currency, the four
/// things people come to do, and everything held, named by token identity.
///
/// Built to stay fast with hundreds of networks enabled: balances arrive
/// chain by chain (`portfolioProvider`), rows are built lazily, and nothing on
/// this screen waits for the slowest endpoint. A balance that was not read is
/// "—", never 0, and a total that covers only part of what is held says so.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/prices/fiat.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/asset_detail_screen.dart';
import 'package:zunia_mobile/screens/chain_detail_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/nft_collection_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/receive_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/widgets/amount_roll.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_mobile/widgets/search_field.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_mobile/widgets/wallet_header.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum _Segment { assets, staked, nfts }

const _kListMode = 'zunia.home.groupByNetwork';
const _kHeldOnly = 'zunia.home.heldOnly';

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key, this.onOpenTab});

  /// Switches the root shell to another tab (`swap`, `earn`), for the Swap
  /// and Stake actions. Null opens nothing.
  final ValueChanged<String>? onOpenTab;

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  _Segment _segment = _Segment.assets;
  final _query = TextEditingController();
  bool _grouped = false;
  bool _heldOnly = false;
  String? _nftChainId;
  StreamSubscription<TrackedTransfer>? _settled;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreLayout());
    _settled = ref.read(pendingTransfersProvider.notifier).settled.listen(_onSettled);
    _offerTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_offerNotifications());
    });
  }

  Timer? _offerTimer;

  static const _kNotifyOffered = 'zunia.notify.offered';

  /// Once, shortly after the wallet first opens: ask whether to be told in
  /// real time. Without this the system permission was only requested after a
  /// stake, so most people never saw a banner. Settings > Notifications can
  /// still turn them on or off later.
  Future<void> _offerNotifications() async {
    if (!mounted) return;
    final store = await SharedPreferences.getInstance();
    if (!mounted || (store.getBool(_kNotifyOffered) ?? false)) return;
    final permission = await ref.read(alertPermissionProvider.future);
    if (!mounted) return;
    if (permission == AlertPermission.granted ||
        permission == AlertPermission.unavailable) {
      await store.setBool(_kNotifyOffered, true);
      return;
    }
    await store.setBool(_kNotifyOffered, true);
    if (!mounted) return;
    final yes = await showZuniaConfirm(
      context,
      title: 'Get notified in real time?',
      message: 'Zunia tells you when tokens arrive, a transfer lands or staking '
          'rewards are ready. Notifications are made on this phone; nothing is '
          'sent to a server.',
      confirmLabel: 'Turn on',
      cancelLabel: 'Not now',
    );
    if (!yes || !mounted) return;
    final granted = await enableDeviceNotifications(ref);
    if (granted) unawaited(ZuniaHaptics.success());
  }

  @override
  void dispose() {
    _settled?.cancel();
    _offerTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _restoreLayout() async {
    final store = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _grouped = store.getBool(_kListMode) ?? false;
      _heldOnly = store.getBool(_kHeldOnly) ?? false;
    });
  }

  Future<void> _setLayout({bool? grouped, bool? heldOnly}) async {
    setState(() {
      _grouped = grouped ?? _grouped;
      _heldOnly = heldOnly ?? _heldOnly;
    });
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kListMode, _grouped);
    await store.setBool(_kHeldOnly, _heldOnly);
  }

  void _onSettled(TrackedTransfer result) {
    if (!mounted) return;
    final record = result.record;
    final text = switch (result.outcome) {
      RouteOutcome.delivered => 'Arrived: ${record.label}',
      RouteOutcome.refunded => 'Came back to your account: ${record.label}',
      RouteOutcome.recoverable => 'Needs your action: ${record.label}',
      RouteOutcome.failed => 'Rejected by the chain: ${record.label}',
      null => null,
    };
    if (text == null) return;
    if (result.outcome == RouteOutcome.delivered) {
      ZuniaHaptics.success();
    } else {
      ZuniaHaptics.warning();
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
    unawaited(ref.read(portfolioProvider.notifier).refresh(force: true));
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _refresh() async {
    ref.invalidate(pricesProvider);
    await ref.read(portfolioProvider.notifier).refresh(force: true);
    await ZuniaHaptics.success();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen(title: 'Scan')),
    );
    if (!mounted || code == null || code.isEmpty) return;
    PaymentRequest? request;
    try {
      request = parsePaymentRequest(code);
    } on PaymentRequestException catch (error) {
      ZuniaHaptics.error();
      await showZuniaAlert<void>(
        context,
        title: 'This payment request cannot be used',
        message: error.message,
        actions: const [ZuniaAlertAction(label: 'OK', isDefault: true)],
      );
      return;
    }
    if (!mounted) return;
    if (request != null) {
      _open(SendScreen.fromRequest(request));
      return;
    }
    await handleScannedCode(context, ref, code);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final portfolio = ref.watch(portfolioProvider);
    final snapshot = ref.watch(pricesProvider).valueOrNull;
    ref.watch(identityGenerationProvider);
    final verified = ref.watch(backupVerifiedProvider);
    final currency = normaliseCurrency(prefs.currency);
    final chains = [for (final account in accounts) account.chain];
    final balances = portfolio.balances;
    final prices = snapshot?.prices ?? const <String, SpotPrice>{};
    final assets = homeAssets(
      chains,
      balances,
      prices,
      exchangePriced: snapshot == null ? const {} : exchangePricedChains(snapshot),
    );
    final totals = computePortfolio(chains, balances, prices, assets);

    final slivers = <Widget>[
      if (verified.valueOrNull == false && MnemonicSecurityConfig.persistentUnverifiedBanner)
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: 'Backup not verified',
              body: 'Confirm your recovery phrase before you fund this wallet.',
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverToBoxAdapter(
          child: _Hero(
            totals: totals,
            snapshot: snapshot,
            currency: currency,
            hidden: prefs.hideAmounts,
            liveReads: prefs.liveReads,
            loading: portfolio.loadingAny && !portfolio.anySettled,
            testnets: chains.where((chain) => chain.isTestnet).length,
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              ZuniaQuickAction(
                label: 'Send',
                icon: Icons.arrow_upward_rounded,
                primary: true,
                onTap: () => _open(const SendScreen()),
              ),
              const SizedBox(width: 8),
              ZuniaQuickAction(
                label: 'Receive',
                icon: Icons.arrow_downward_rounded,
                onTap: () => _open(const ReceiveScreen()),
              ),
              const SizedBox(width: 8),
              ZuniaQuickAction(
                label: 'Swap',
                icon: Icons.swap_horiz_rounded,
                onTap: () => widget.onOpenTab?.call('swap'),
              ),
              const SizedBox(width: 8),
              ZuniaQuickAction(
                label: 'Stake',
                icon: Icons.savings_outlined,
                onTap: () => widget.onOpenTab?.call('earn'),
              ),
            ],
          ),
        ),
      ),
      if (!prefs.liveReads)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _ReadsOffCallout(
              onEnable: () => ref.read(preferencesProvider.notifier).setLiveReads(true),
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        sliver: SliverToBoxAdapter(
          child: ZuniaSegmented<_Segment>(
            value: _segment,
            onChanged: (value) => setState(() => _segment = value),
            options: const {
              _Segment.assets: 'Assets',
              _Segment.staked: 'Staked',
              _Segment.nfts: 'NFTs',
            },
          ),
        ),
      ),
      ..._segmentSlivers(
        accounts: accounts,
        assets: assets,
        portfolio: portfolio,
        prices: prices,
        totals: totals,
        currency: currency,
        hidden: prefs.hideAmounts,
        liveReads: prefs.liveReads,
      ),
      const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
    ];

    return ZuniaBackdrop(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeHeader(onScan: _scan),
          Expanded(
            child: ZuniaRefresh(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: slivers,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _segmentSlivers({
    required List<ChainAccount> accounts,
    required List<HomeAsset> assets,
    required PortfolioState portfolio,
    required Map<String, SpotPrice> prices,
    required PortfolioTotals totals,
    required String currency,
    required bool hidden,
    required bool liveReads,
  }) {
    if (accounts.isEmpty) {
      return [SliverToBoxAdapter(child: _NoAccounts(onManage: () => _open(const NetworksScreen())))];
    }
    switch (_segment) {
      case _Segment.nfts:
        final chainId = accounts.any((a) => a.chain.chainId == _nftChainId)
            ? _nftChainId!
            : accounts.first.chain.chainId;
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChainPicker(value: chainId, onChanged: (value) => setState(() => _nftChainId = value)),
                  const SizedBox(height: 14),
                  NftGalleryView(key: ValueKey(chainId), chainId: chainId),
                ],
              ),
            ),
          ),
        ];
      case _Segment.staked:
        return _stakedSlivers(accounts, portfolio, prices, totals, currency, hidden, liveReads);
      case _Segment.assets:
        return _assetSlivers(assets, portfolio, currency, hidden, liveReads, accounts);
    }
  }

  List<Widget> _assetSlivers(
    List<HomeAsset> assets,
    PortfolioState portfolio,
    String currency,
    bool hidden,
    bool liveReads,
    List<ChainAccount> accounts,
  ) {
    final s = ZuniaSemanticsExt.of(context);
    final query = _query.text.trim().toLowerCase();
    final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final visible = [
      for (final asset in assets)
        if ((!_heldOnly || !liveReads || asset.held) && _matches(asset, words)) asset,
    ];
    final failures = portfolio.failures;
    final failing = failures.values
        .where((f) => f.kind != ChainReadFailureKind.readsDisabled)
        .length;

    final toolbar = SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(
              child: AdaptiveSearchField(
                controller: _query,
                placeholder: 'Token or network',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 6),
            _LayoutMenu(
              grouped: _grouped,
              heldOnly: _heldOnly,
              liveReads: liveReads,
              onGrouped: (value) => _setLayout(grouped: value),
              onHeldOnly: (value) => _setLayout(heldOnly: value),
            ),
          ],
        ),
      ),
    );

    final notes = <Widget>[
      if (failing > 0 && liveReads)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _FailureNote(
            count: failing,
            onRetry: () => ref.read(portfolioProvider.notifier).refresh(force: true),
          ),
        ),
    ];

    if (portfolio.loadingAny && !portfolio.anySettled && liveReads) {
      return [
        toolbar,
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(child: ListSkeleton(count: 5, label: 'Loading balances')),
        ),
      ];
    }

    if (visible.isEmpty) {
      return [
        toolbar,
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              query.isNotEmpty
                  ? 'Nothing matches “${_query.text.trim()}”${_heldOnly ? ' among held assets' : ''}.'
                  : _heldOnly
                      ? 'Nothing held yet. Receive to fund this wallet.'
                      : 'No networks enabled.',
              textAlign: TextAlign.center,
              style: zuniaSans(fontSize: 13, color: s.fgMuted),
            ),
          ),
        ),
      ];
    }

    final rows = <Widget Function()>[];
    if (_grouped) {
      final groups = groupHomeAssets(visible, [for (final a in accounts) a.chain.chainId]);
      for (final group in groups) {
        rows.add(() => _GroupHeader(
              group: group,
              currency: currency,
              hidden: hidden,
              onTap: () => _open(ChainDetailScreen(chainId: group.chain.chainId)),
            ));
        for (final asset in group.assets) {
          rows.add(() => _AssetRow(
                asset: asset,
                currency: currency,
                hidden: hidden,
                grouped: true,
                onTap: () => _open(AssetDetailScreen(chainId: asset.chain.chainId, denom: asset.denom)),
              ));
        }
      }
    } else {
      for (final asset in visible) {
        rows.add(() => _AssetRow(
              asset: asset,
              currency: currency,
              hidden: hidden,
              grouped: false,
              onTap: () => _open(AssetDetailScreen(chainId: asset.chain.chainId, denom: asset.denom)),
            ));
      }
    }

    return [
      toolbar,
      if (notes.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(child: Column(children: notes)),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverList.builder(itemCount: rows.length, itemBuilder: (_, index) => rows[index]()),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverToBoxAdapter(
          child: ZuniaButton(
            label: 'Manage networks',
            variant: ZuniaButtonVariant.secondary,
            leading: const Icon(Icons.hub_outlined),
            onPressed: () => _open(const NetworksScreen()),
          ),
        ),
      ),
    ];
  }

  static bool _matches(HomeAsset asset, List<String> words) {
    if (words.isEmpty) return true;
    final haystack = [
      ...tokenKeywords(asset.identity),
      asset.chain.chainName,
      tokenKindLabel(asset.identity.kind),
      asset.metadataName ?? '',
    ].join(' ').toLowerCase();
    return words.every(haystack.contains);
  }

  List<Widget> _stakedSlivers(
    List<ChainAccount> accounts,
    PortfolioState portfolio,
    Map<String, SpotPrice> prices,
    PortfolioTotals totals,
    String currency,
    bool hidden,
    bool liveReads,
  ) {
    final rows = [
      for (final account in accounts)
        if (portfolio.balances[account.chain.chainId] case final balance?)
          if (balance.stakingKnown && balance.staked != '0') (account.chain, balance),
    ];
    final unknown = [
      for (final account in accounts)
        if (portfolio.balances[account.chain.chainId] case final balance?)
          if (!balance.stakingKnown) account.chain.chainName,
    ];
    if (portfolio.loadingAny && rows.isEmpty && liveReads) {
      return const [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(child: ListSkeleton(count: 2, label: 'Loading staked positions')),
        ),
      ];
    }
    if (rows.isEmpty) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(
            child: ZuniaEmptyState(
              title: liveReads ? 'Nothing staked' : 'Staking is off',
              description: liveReads
                  ? (unknown.isEmpty
                      ? 'Pick a validator in Earn and your positions land here.'
                      : 'Staked amounts on ${unknown.join(', ')} could not be read.')
                  : 'Turn on live reads to read staking positions from each chain.',
              action: liveReads
                  ? ZuniaButton(
                      label: 'Open Earn',
                      size: ZuniaButtonSize.sm,
                      variant: ZuniaButtonVariant.secondary,
                      onPressed: () => widget.onOpenTab?.call('earn'),
                    )
                  : null,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Staked value',
                  value: hidden ? maskedAmount : (totals.staked > 0 ? formatFiatCompact(totals.staked, currency) : '—'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'To claim',
                  value: hidden
                      ? maskedAmount
                      : (totals.claimable > 0 ? formatFiatCompact(totals.claimable, currency) : '—'),
                  accent: true,
                ),
              ),
            ],
          ),
        ),
      ),
      if (unknown.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Staked amounts on ${unknown.join(', ')} could not be read and are left out.',
              style: zuniaSans(fontSize: 12, color: ZuniaSemanticsExt.of(context).fgDim),
            ),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (_, index) {
            final (chain, balance) = rows[index];
            return _StakedRow(
              chain: chain,
              balance: balance,
              price: prices[chain.chainId],
              currency: currency,
              hidden: hidden,
              onTap: () => _open(ChainDetailScreen(chainId: chain.chainId, initialTab: 'stake')),
            );
          },
        ),
      ),
    ];
  }
}

/* -------------------------------------------------------------------------- *
 * Pieces
 * -------------------------------------------------------------------------- */

class _Hero extends StatelessWidget {
  const _Hero({
    required this.totals,
    required this.snapshot,
    required this.currency,
    required this.hidden,
    required this.liveReads,
    required this.loading,
    required this.testnets,
  });

  final PortfolioTotals totals;
  final PriceSnapshot? snapshot;
  final String currency;
  final bool hidden;
  final bool liveReads;
  final bool loading;
  final int testnets;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final change = totals.change24h;
    final notes = <String>[
      if (totals.hasTotal && totals.unpricedAssets > 0)
        '${totals.pricedAssets} of ${totals.pricedAssets + totals.unpricedAssets} assets priced',
      if (snapshot?.problem != null && liveReads) snapshot!.problem!,
      if (snapshot?.stale == true && snapshot?.fetchedAt != null)
        'Prices from ${_ago(snapshot!.fetchedAt!)}',
    ];
    Widget figure;
    if (hidden) {
      figure = Text(
        maskedAmount,
        style: zuniaSans(fontSize: 34, fontWeight: FontWeight.w500, color: s.fg),
      );
    } else if (loading) {
      figure = Semantics(
        label: 'Loading total balance',
        child: const ZuniaSkeleton(width: 180, height: 34),
      );
    } else if (totals.hasTotal) {
      figure = AmountRoll(
        value: totals.total,
        format: (value) => formatFiatFull(value, currency),
        semanticsLabel: 'Total balance ${formatFiatFull(totals.total, currency)}',
      );
    } else {
      figure = Text(
        '—',
        semanticsLabel: 'Total balance not available',
        style: zuniaSans(fontSize: 34, fontWeight: FontWeight.w500, color: s.fgMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'TOTAL BALANCE',
              style: zuniaMono(fontSize: 10.5, letterSpacing: 1.4, color: s.fgMuted),
            ),
            // Hide amounts sits with the amounts it hides.
            Consumer(
              builder: (context, ref, _) {
                final hide = ref.watch(preferencesProvider.select((p) => p.hideAmounts));
                final cupertino = ZuniaPlatform.isCupertino(context);
                return IconButton(
                  tooltip: hide ? 'Show amounts' : 'Hide amounts',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    ZuniaHaptics.selection();
                    ref.read(preferencesProvider.notifier).toggleHideAmounts();
                  },
                  icon: Icon(
                    hide
                        ? (cupertino ? CupertinoIcons.eye_slash : Icons.visibility_off_outlined)
                        : (cupertino ? CupertinoIcons.eye : Icons.visibility_outlined),
                    size: 18,
                    color: s.fgMuted,
                  ),
                );
              },
            ),
            if (testnets > 0) ...[
              const SizedBox(width: 8),
              const ZuniaPill('Testnet', tone: ZuniaPillTone.accent),
            ],
          ],
        ),
        const SizedBox(height: 8),
        figure,
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!hidden && totals.hasTotal && change != null)
              _ChangeChip(change: change),
            if (!hidden && !totals.hasTotal && !loading)
              Text(
                liveReads ? 'NO PRICE FEED' : 'LIVE READS OFF',
                style: zuniaMono(fontSize: 10, letterSpacing: 1.1, color: s.fgDim),
              ),
            for (final note in notes)
              Text(note, style: zuniaSans(fontSize: 12, color: s.fgDim)),
          ],
        ),
      ],
    );
  }

  static String _ago(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    return '${minutes ~/ 60} h ago';
  }
}

class _ChangeChip extends StatelessWidget {
  const _ChangeChip({required this.change});

  final double change;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final up = change >= 0;
    final color = up ? s.success : s.danger;
    return Semantics(
      label: '${up ? 'Up' : 'Down'} ${change.abs().toStringAsFixed(1)} percent in 24 hours',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: up ? s.successFill : s.dangerFill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '${formatChange(change)} 24h',
          style: zuniaMono(fontSize: 11, color: color),
        ),
      ),
    );
  }
}

class _ReadsOffCallout extends StatelessWidget {
  const _ReadsOffCallout({required this.onEnable});

  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ZuniaCallout(
          tone: ZuniaCalloutTone.info,
          title: 'Live reads are off',
          body: 'Zunia reads balances, prices and history from public endpoints only when you '
              'allow it. Addresses still derive on this device.',
        ),
        const SizedBox(height: 8),
        ZuniaButton(
          label: 'Turn on live reads',
          size: ZuniaButtonSize.sm,
          variant: ZuniaButtonVariant.secondary,
          onPressed: onEnable,
        ),
      ],
    );
  }
}

class _NoAccounts extends ConsumerWidget {
  const _NoAccounts({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    final phrase = ref.watch(phraseProvider);
    final (title, description) = phrase == null
        ? ('Wallet locked', 'Unlock the vault to derive addresses for your chains.')
        : wallet.accounts.isEmpty
            ? ('Account missing', 'Wallet metadata was incomplete. Unlock again or re-import to repair.')
            : wallet.enabledChainIds.isEmpty
                ? ('No networks enabled', 'Add a chain to start deriving addresses for this wallet.')
                : ('No addresses yet', 'Enabled chains could not be derived. Check Manage networks.');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ZuniaEmptyState(
        title: title,
        description: description,
        action: ZuniaButton(
          label: 'Manage networks',
          size: ZuniaButtonSize.sm,
          variant: ZuniaButtonVariant.secondary,
          onPressed: onManage,
        ),
      ),
    );
  }
}

class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.count, required this.onRetry});

  final int count;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Row(
      children: [
        Icon(Icons.cloud_off_outlined, size: 16, color: s.warning),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$count network${count == 1 ? '' : 's'} did not answer. Their balances show as —, not 0.',
            style: zuniaSans(fontSize: 12, color: s.fgMuted),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}

/// List layout: each token, or grouped by network; and held-only.
class _LayoutMenu extends StatelessWidget {
  const _LayoutMenu({
    required this.grouped,
    required this.heldOnly,
    required this.liveReads,
    required this.onGrouped,
    required this.onHeldOnly,
  });

  final bool grouped;
  final bool heldOnly;
  final bool liveReads;
  final ValueChanged<bool> onGrouped;
  final ValueChanged<bool> onHeldOnly;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return IconButton(
      tooltip: 'List options',
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: () async {
        final choice = await showZuniaActionSheet<String>(
          context,
          title: 'Assets',
          actions: [
            ZuniaAlertAction(
              label: '${grouped ? '' : '✓ '}Show each token',
              value: 'separate',
              isDefault: !grouped,
            ),
            ZuniaAlertAction(
              label: '${grouped ? '✓ ' : ''}Group by network',
              value: 'grouped',
              isDefault: grouped,
            ),
            if (liveReads)
              ZuniaAlertAction(
                label: heldOnly ? 'Show zero balances' : 'Hide zero balances',
                value: 'held',
              ),
          ],
        );
        switch (choice) {
          case 'separate':
            onGrouped(false);
          case 'grouped':
            onGrouped(true);
          case 'held':
            onHeldOnly(!heldOnly);
        }
      },
      icon: Icon(
        grouped
            ? (cupertino ? CupertinoIcons.square_stack_3d_up : Icons.layers_outlined)
            : (cupertino ? CupertinoIcons.list_bullet : Icons.view_list_outlined),
        size: 22,
        color: s.fg,
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.currency,
    required this.hidden,
    required this.onTap,
  });

  final HomeAssetGroup group;
  final String currency;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final value = group.fiatValue;
    return Semantics(
      button: true,
      label: '${group.chain.chainName}${value != null && !hidden ? ', ${formatFiatCompact(value, currency)}' : ''}. Open network',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
          child: Row(
            children: [
              ChainAvatar(chain: group.chain, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  group.chain.chainName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: zuniaSans(fontSize: 13, fontWeight: FontWeight.w600, color: s.fg),
                ),
              ),
              if (group.chain.isTestnet) ...[
                const SizedBox(width: 6),
                const ZuniaPill('Testnet'),
              ],
              const Spacer(),
              Text(
                hidden ? maskedAmount : (value == null ? '' : formatFiatCompact(value, currency)),
                style: zuniaMono(fontSize: 11, color: s.fgMuted),
              ),
              Icon(Icons.chevron_right, size: 18, color: s.fgDim),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.currency,
    required this.hidden,
    required this.grouped,
    required this.onTap,
  });

  final HomeAsset asset;
  final String currency;
  final bool hidden;
  final bool grouped;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final identity = asset.identity;
    final amount = asset.amountKnown
        ? formatTokenAmount(asset.amount, asset.scale, TokenAmountVariant.list, hidden: hidden)
        : '—';
    final parts = splitBaseUnits(amount);
    final fiat = asset.fiatValue == null ? null : formatFiatCompact(asset.fiatValue!, currency);
    final change = asset.change24h;
    final subtitle = grouped ? groupedSubtitle(identity) : asset.subtitle;
    final label = [
      tokenText(identity, TokenTextVariant.a11y),
      if (identity.proven) 'verified',
      if (hidden) 'amount hidden' else if (!asset.amountKnown) 'balance not read' else amount,
      if (!hidden && fiat != null) fiat,
    ].join(', ');
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              TokenAvatar(identity: identity, size: grouped ? 32 : 38, showLocation: !grouped),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: TokenTicker.of(identity)),
                        if (asset.chain.isTestnet && !grouped) ...[
                          const SizedBox(width: 6),
                          const ZuniaPill('Testnet'),
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(fontSize: 12, height: 1.25, color: s.fgMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.38),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      parts.figure,
                      maxLines: parts.words == null ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: zuniaSans(
                        fontSize: parts.words == null ? 15 : 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: asset.held || !asset.amountKnown ? s.fg : s.fgDim,
                        tabular: const FontFeature.tabularFigures(),
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (parts.words != null)
                      Text(parts.words!, style: zuniaMono(fontSize: 10, color: s.fgDim))
                    else if (hidden && (fiat != null || change != null))
                      Text(maskedAmount, style: zuniaMono(fontSize: 11, color: s.fgDim))
                    else if (fiat != null)
                      Text(
                        fiat,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 11, color: s.fgMuted),
                      )
                    else if (change != null && asset.held)
                      Text(
                        formatChange(change, digits: 2),
                        style: zuniaMono(fontSize: 11, color: change >= 0 ? s.success : s.danger),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.accent = false});

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.line),
        color: s.glass,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: zuniaMono(fontSize: 9.5, letterSpacing: 1.2, color: s.fgDim)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: zuniaSans(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: accent ? s.accent : s.fg,
              tabular: const FontFeature.tabularFigures(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StakedRow extends StatelessWidget {
  const _StakedRow({
    required this.chain,
    required this.balance,
    required this.price,
    required this.currency,
    required this.hidden,
    required this.onTap,
  });

  final ChainEntry chain;
  final ChainBalance balance;
  final SpotPrice? price;
  final String currency;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final scale = AmountScale.of(nativeIdentity(chain));
    final staked = formatTokenAmount(balance.staked, scale, TokenAmountVariant.history, hidden: hidden, unit: true);
    final rewards = !balance.rewardsKnown
        ? 'rewards not read'
        : balance.rewards == '0'
            ? 'no rewards yet'
            : '+${formatTokenAmount(balance.rewards, scale, TokenAmountVariant.history, unit: true)} to claim';
    final fiat = price == null
        ? null
        : formatFiatCompact(toWholeCoins(balance.staked, chain.coinDecimals) * price!.price, currency);
    return Semantics(
      button: true,
      label: '${chain.chainName}, $staked staked${hidden ? '' : ', $rewards'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              ChainAvatar(chain: chain, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chain.chainName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg),
                    ),
                    Text(
                      hidden ? maskedAmount : (fiat == null ? 'staked' : '$fiat staked'),
                      style: zuniaMono(fontSize: 11, color: s.fgMuted),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      staked,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: s.fg,
                        tabular: const FontFeature.tabularFigures(),
                      ),
                    ),
                    Text(
                      hidden ? maskedAmount : rewards,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zuniaMono(fontSize: 10.5, color: s.accent),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
