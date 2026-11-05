/// Everything this wallet holds and can do on one network: what it is worth,
/// its own coin's price, every token held there by kind, staking, history,
/// and the facts about the chain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/prices/fiat.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/screens/asset_detail_screen.dart';
import 'package:zunia_mobile/screens/receive_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/screens/tx_detail_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/widgets/activity_row.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

class ChainDetailScreen extends ConsumerStatefulWidget {
  const ChainDetailScreen({
    super.key,
    required this.chainId,
    this.initialTab = 'assets',
  });

  final String chainId;

  /// `assets`, `activity`, `stake` or `about`.
  final String initialTab;

  @override
  ConsumerState<ChainDetailScreen> createState() => _ChainDetailScreenState();
}

class _ChainDetailScreenState extends ConsumerState<ChainDetailScreen> {
  late String _tab = const {'assets', 'activity', 'stake', 'about'}.contains(widget.initialTab)
      ? widget.initialTab
      : widget.initialTab == 'overview'
          ? 'activity'
          : 'assets';

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final account = accounts.where((a) => a.chain.chainId == widget.chainId).firstOrNull;
    ref.watch(identityGenerationProvider);

    if (account == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: widget.chainId,
            onBack: () => Navigator.of(context).pop(),
            body: const Padding(
              padding: EdgeInsets.all(16),
              child: ZuniaEmptyState(
                title: 'Network not enabled',
                description: 'Enable this network to derive an address for it.',
              ),
            ),
          ),
        ),
      );
    }

    final chain = account.chain;
    final read = ref.watch(portfolioProvider.select((state) => state.chains[chain.chainId]));
    final balance = read?.balance;
    final snapshot = ref.watch(pricesProvider).valueOrNull;
    final currency = normaliseCurrency(prefs.currency);
    final hidden = prefs.hideAmounts;
    final assets = homeAssets(
      [chain],
      {chain.chainId: ?balance},
      snapshot?.prices ?? const {},
      exchangePriced: snapshot == null ? const {} : exchangePricedChains(snapshot),
    );
    final totals = computePortfolio([chain], {chain.chainId: ?balance},
        snapshot?.prices ?? const {}, assets);
    final spot = snapshot?.prices[chain.chainId];
    final scale = AmountScale.of(nativeIdentity(chain));
    String fmt(String? units, {bool known = true}) => hidden
        ? maskedAmount
        : units == null
            ? '—'
            : !known
                ? 'Not read'
                : formatTokenAmount(units, scale, TokenAmountVariant.picker, unit: true);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: chain.chainName,
          onBack: () => Navigator.of(context).pop(),
          body: RefreshIndicator.adaptive(
            onRefresh: () async {
              ref.invalidate(activityProvider(chain.chainId));
              await ref.read(portfolioProvider.notifier).refresh(force: true);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Row(
                  children: [
                    ChainAvatar(chain: chain, size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hidden
                                ? maskedAmount
                                : totals.hasTotal
                                    ? formatFiatFull(totals.total, currency)
                                    : fmt(balance?.available),
                            style: zuniaSans(
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.8,
                              color: s.fg,
                              tabular: const FontFeature.tabularFigures(),
                            ),
                          ),
                          Row(
                            children: [
                              Flexible(
                                child: Text(chain.chainId,
                                    overflow: TextOverflow.ellipsis,
                                    style: zuniaMono(fontSize: 11, color: s.fgDim)),
                              ),
                              if (chain.isTestnet) ...[
                                const SizedBox(width: 6),
                                const ZuniaPill('Testnet'),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (spot != null) ...[
                  const SizedBox(height: 10),
                  _CoinPrice(ticker: chainTicker(chain), spot: spot, currency: currency),
                ],
                const SizedBox(height: 12),
                _StatRow(label: 'Available', value: fmt(balance?.available)),
                _StatRow(label: 'Staked', value: fmt(balance?.staked, known: balance?.stakingKnown ?? true)),
                _StatRow(
                  label: 'Rewards',
                  value: fmt(balance?.rewards, known: balance?.rewardsKnown ?? true),
                  highlight: true,
                ),
                if (balance == null && read?.failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: ZuniaCallout(
                      tone: ZuniaCalloutTone.warning,
                      title: 'Balance not available',
                      body: '${read!.failure!.message} This is not a statement that the account is empty.',
                    ),
                  ),
                const SizedBox(height: 12),
                _AddressCard(address: account.address),
                const SizedBox(height: 18),
                ZuniaSegmented<String>(
                  value: _tab,
                  onChanged: (value) => setState(() => _tab = value),
                  options: const {
                    'assets': 'Assets',
                    'activity': 'Activity',
                    'stake': 'Stake',
                    'about': 'About',
                  },
                ),
                const SizedBox(height: 12),
                ..._body(chain, assets, balance, read, currency, hidden),
              ],
            ),
          ),
          footer: Row(
            children: [
              Expanded(
                child: ZuniaButton(
                  label: 'Send',
                  onPressed: () => _open(SendScreen(initialChainId: chain.chainId)),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: ZuniaButton(
                  label: 'Receive',
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: () => _open(ReceiveScreen(chainId: chain.chainId)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(
    ChainEntry chain,
    List<HomeAsset> assets,
    ChainBalance? balance,
    ChainRead? read,
    String currency,
    bool hidden,
  ) {
    final s = ZuniaSemanticsExt.of(context);
    switch (_tab) {
      case 'activity':
        final activity = ref.watch(activityProvider(chain.chainId));
        return [
          activity.when(
            data: (rows) => rows.isEmpty
                ? const ZuniaEmptyState(
                    title: 'No activity yet',
                    description: 'Transfers and signatures on this network show here.',
                  )
                : Column(
                    children: [
                      for (final row in rows)
                        ActivityRow(
                          item: row,
                          hidden: hidden,
                          showChain: false,
                          onTap: () => _open(TxDetailScreen(item: row)),
                        ),
                    ],
                  ),
            loading: () => const ListSkeleton(count: 4, label: 'Loading activity'),
            error: (error, _) => ZuniaEmptyState(
              title: 'History unavailable',
              description: error is ChainReadException
                  ? '${chain.chainName} did not return its history. ${error.failure.message}'
                  : '${chain.chainName} did not return its history. Try again later.',
            ),
          ),
        ];
      case 'stake':
        return _stake(chain, hidden);
      case 'about':
        return [
          ZuniaListSection(
            children: [
              ZuniaListTile(title: 'Chain ID', value: chain.chainId),
              ZuniaListTile(title: 'Address prefix', value: chain.bech32Prefix),
              ZuniaListTile(title: 'Derivation', value: "m/44'/${chain.coinType}'/0'/0"),
              ZuniaListTile(title: 'Network', value: chain.isTestnet ? 'Testnet' : 'Mainnet'),
              ZuniaListTile(title: 'Coin', value: '${chainTicker(chain)} · ${chain.coinDecimals} decimals'),
              ZuniaListTile(title: 'Fee coin', value: feeTicker(chain)),
              ZuniaListTile(title: 'REST', subtitle: chain.rest ?? 'not listed'),
            ],
          ),
        ];
      default:
        if (balance == null && (read?.loading ?? true)) {
          return const [ListSkeleton(count: 3, label: 'Loading assets')];
        }
        final sections = <(String, List<HomeAsset>)>[
          ('Native', [for (final a in assets) if (a.group == AssetGroupKind.native) a]),
          ('IBC tokens', [for (final a in assets) if (a.group == AssetGroupKind.ibc && a.held) a]),
          ('Token factory', [for (final a in assets) if (a.group == AssetGroupKind.factory && a.held) a]),
          ('Other', [for (final a in assets) if (a.group == AssetGroupKind.other && a.held) a]),
        ];
        return [
          for (final (title, rows) in sections)
            if (rows.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(
                  '${title.toUpperCase()} · ${rows.length}',
                  style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim),
                ),
              ),
              for (final asset in rows)
                _TokenRow(
                  asset: asset,
                  currency: currency,
                  hidden: hidden,
                  onTap: () => _open(AssetDetailScreen(chainId: chain.chainId, denom: asset.denom)),
                ),
            ],
        ];
    }
  }

  List<Widget> _stake(ChainEntry chain, bool hidden) {
    final scale = AmountScale.of(nativeIdentity(chain));
    String fmt(String units) => formatTokenAmount(units, scale, TokenAmountVariant.picker, hidden: hidden, unit: true);
    final delegations = ref.watch(delegationsProvider(chain.chainId));
    final unbonding = ref.watch(unbondingProvider(chain.chainId));
    return [
      delegations.when(
        data: (rows) => rows.isEmpty
            ? const ZuniaEmptyState(
                title: 'No delegations',
                description: 'Stake to a validator in Earn to start earning rewards on this network.',
              )
            : Column(
                children: [
                  for (final row in rows)
                    _PositionRow(
                      title: truncateAddress(row.validatorAddress, left: 14, right: 6),
                      amount: fmt(row.amount),
                      meta: 'rewards ${fmt(row.rewards)}',
                    ),
                ],
              ),
        loading: () => const ListSkeleton(count: 2, label: 'Loading delegations'),
        error: (_, _) => const ZuniaEmptyState(
          title: 'Endpoint unavailable',
          description: 'The public endpoint for this network did not answer. Try again later.',
        ),
      ),
      unbonding.maybeWhen(
        data: (rows) => rows.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ZuniaSectionLabel('Unbonding'),
                    const SizedBox(height: 8),
                    for (final row in rows)
                      _PositionRow(
                        title: truncateAddress(row.validatorAddress, left: 14, right: 6),
                        amount: fmt(row.amount),
                        meta: row.completionTime == null
                            ? 'pending'
                            : 'available ${row.completionTime!.toLocal().toString().split(' ').first}',
                      ),
                  ],
                ),
              ),
        orElse: () => const SizedBox.shrink(),
      ),
    ];
  }
}

class _CoinPrice extends StatelessWidget {
  const _CoinPrice({required this.ticker, required this.spot, required this.currency});

  final String ticker;
  final SpotPrice spot;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final up = spot.change24h >= 0;
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('1 $ticker = ${formatFiatPrice(spot.price, currency)}', style: zuniaMono(fontSize: 12, color: s.fgMuted)),
        Text('${formatChange(spot.change24h, digits: 2)} 24h',
            style: zuniaMono(fontSize: 12, color: up ? s.success : s.danger)),
        if (spot.source case final source?)
          InkWell(
            onTap: () => openExternal(context, source.url),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'via ${source.name}',
                style: zuniaSans(fontSize: 12, color: s.accent).copyWith(decoration: TextDecoration.underline),
              ),
            ),
          ),
      ],
    );
  }
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({required this.asset, required this.currency, required this.hidden, required this.onTap});

  final HomeAsset asset;
  final String currency;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final identity = asset.identity;
    final amount = asset.amountKnown
        ? formatTokenAmount(asset.amount, asset.scale, TokenAmountVariant.list, hidden: hidden)
        : '—';
    final fiat = asset.fiatValue == null ? null : formatFiatCompact(asset.fiatValue!, currency);
    final subtitle = groupedSubtitle(identity);
    return Semantics(
      button: true,
      label: '${tokenText(identity, TokenTextVariant.a11y)}, ${hidden ? 'amount hidden' : amount}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            children: [
              TokenAvatar(identity: identity, size: 34, showLocation: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TokenTicker.of(identity),
                    if (subtitle != null)
                      Text(subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 12, color: s.fgMuted)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(amount,
                      style: zuniaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: s.fg,
                          tabular: const FontFeature.tabularFigures())),
                  if (fiat != null && !hidden) Text(fiat, style: zuniaMono(fontSize: 11, color: s.fgMuted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label, style: zuniaMono(fontSize: 12, color: s.fgDim)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: zuniaMono(fontSize: 12, color: highlight ? s.info : s.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.surfaceRaisedGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(address, style: zuniaMono(fontSize: 11, height: 1.5, color: s.fgMuted)),
            ),
            IconButton(
              tooltip: 'Copy address',
              onPressed: () => copyWithFeedback(context, address, 'Address'),
              icon: Icon(Icons.copy_rounded, size: 20, color: s.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionRow extends StatelessWidget {
  const _PositionRow({required this.title, required this.amount, required this.meta});

  final String title;
  final String amount;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: s.surfaceRaisedGradient, borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 12, color: s.fg)),
                    const SizedBox(height: 3),
                    Text(meta, style: zuniaMono(fontSize: 10, color: s.fgMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  amount,
                  textAlign: TextAlign.end,
                  style: zuniaSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
