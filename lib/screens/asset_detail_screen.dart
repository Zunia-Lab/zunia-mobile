/// One token on one chain: its price, what is held, what it is, and its
/// recent movements, with Send and Receive one tap away.
///
/// Everything named here comes from the token's identity: the issuer, the
/// IBC path it took and how Zunia proved its name. A price shows only when it
/// is the token's own (see `priceChainOf`), and a price read from one
/// exchange market says which one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/prices/fiat.dart';
import 'package:zunia_mobile/prices/price_service.dart';
import 'package:zunia_mobile/screens/chain_detail_screen.dart';
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
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

class AssetDetailScreen extends ConsumerWidget {
  const AssetDetailScreen({super.key, required this.chainId, this.denom});

  final String chainId;

  /// Exact bank denom; the chain's own coin when null.
  final String? denom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final account = accounts.where((a) => a.chain.chainId == chainId).firstOrNull;
    ref.watch(identityGenerationProvider);
    if (account == null) {
      return _Shell(
        title: 'Asset',
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: ZuniaEmptyState(
            title: 'Network not enabled',
            description: 'Enable this network to see what it holds.',
          ),
        ),
      );
    }
    final chain = account.chain;
    final read = ref.watch(portfolioProvider.select((state) => state.chains[chainId]));
    final balance = read?.balance;
    final snapshot = ref.watch(pricesProvider).valueOrNull;
    final currency = normaliseCurrency(prefs.currency);
    final hidden = prefs.hideAmounts;
    final target = denom ?? chain.coinMinimalDenom;
    final native = target == chain.coinMinimalDenom;
    final held = balance?.tokens.where((t) => t.denom == target).firstOrNull;
    final identity = native ? nativeIdentity(chain) : rowIdentity(chain, held ?? HeldToken(denom: target, amount: '0'));
    final scale = AmountScale.of(identity);
    final amount = native ? balance?.available : (balance == null ? null : held?.amount ?? '0');
    final exchange = snapshot == null ? const <String>{} : exchangePricedChains(snapshot);
    final priceChain = priceChainOf(identity, exchangePriced: exchange);
    final spot = priceChain == null ? null : snapshot?.prices[priceChain];
    final fiat = spot == null || amount == null ? null : toWholeCoins(amount, identity.decimals) * spot.price;

    String fmt(String? units) => units == null
        ? '—'
        : formatTokenAmount(units, scale, TokenAmountVariant.picker, hidden: hidden, unit: true);

    final activity = ref.watch(activityProvider(chainId));

    return _Shell(
      title: identity.ticker,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Row(
            children: [
              TokenAvatar(identity: identity, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TokenTicker.of(identity,
                        style: zuniaSans(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.5, color: s.fg)),
                    Text(tokenText(identity, TokenTextVariant.row),
                        style: zuniaSans(fontSize: 13, color: s.fgMuted)),
                    if (identity.proven)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const ZuniaVerifiedBadge(size: 16),
                            const SizedBox(width: 4),
                            Text('Verified origin', style: zuniaSans(fontSize: 12, color: s.info)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ZuniaCard(
            tone: ZuniaCardTone.raised,
            padding: const EdgeInsets.all(16),
            radius: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BALANCE', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim)),
                const SizedBox(height: 6),
                Text(
                  hidden ? maskedAmount : fmt(amount),
                  style: zuniaSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.6,
                    color: s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                ),
                if (fiat != null && !hidden)
                  Text(formatFiatFull(fiat, currency), style: zuniaMono(fontSize: 13, color: s.fgMuted)),
                if (amount == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      read?.failure?.message ?? 'Reading the balance…',
                      style: zuniaSans(fontSize: 12, color: s.fgDim),
                    ),
                  ),
                const SizedBox(height: 14),
                Divider(color: s.line, height: 1),
                const SizedBox(height: 12),
                _PriceLine(spot: spot, currency: currency, decimalsKnown: identity.decimalsKnown),
              ],
            ),
          ),
          if (native) ...[
            const SizedBox(height: 12),
            _Stat(label: 'Available', value: hidden ? maskedAmount : fmt(balance?.available)),
            _Stat(
              label: 'Staked',
              value: hidden ? maskedAmount : (balance != null && !balance.stakingKnown ? 'Not read' : fmt(balance?.staked)),
            ),
            _Stat(
              label: 'Rewards',
              value: hidden ? maskedAmount : (balance != null && !balance.rewardsKnown ? 'Not read' : fmt(balance?.rewards)),
              accent: true,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ZuniaButton(
                  label: 'Send',
                  leading: const Icon(Icons.arrow_upward_rounded),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SendScreen(initialChainId: chainId, initialDenom: target),
                  )),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ZuniaButton(
                  label: 'Receive',
                  variant: ZuniaButtonVariant.secondary,
                  leading: const Icon(Icons.arrow_downward_rounded),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ReceiveScreen(chainId: chainId, denom: target),
                  )),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ZuniaListSection(
            header: 'About this token',
            children: [
              ZuniaListTile(title: 'Network', value: chain.chainName, navigates: true, onTap: () {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChainDetailScreen(chainId: chainId)));
              }),
              ZuniaListTile(title: 'Issued on', value: issuerText(identity)),
              ZuniaListTile(title: 'Kind', value: tokenKindLabel(identity.kind)),
              if (_pathText(identity) case final path?) ZuniaListTile(title: 'IBC path', subtitle: path),
              ZuniaListTile(
                title: 'Decimals',
                value: identity.decimalsKnown ? '${identity.decimals}' : 'Unknown: amounts in base units',
              ),
              ZuniaListTile(
                title: 'Denom',
                subtitle: shortDenom(identity.denom),
                trailing: Icon(Icons.copy_rounded, size: 18, color: s.accent),
                onTap: () => copyWithFeedback(context, identity.denom, 'Denom'),
              ),
              if (identity.originDenom != null && identity.originDenom != identity.denom)
                ZuniaListTile(
                  title: 'Denom on issuer',
                  subtitle: shortDenom(identity.originDenom!),
                  trailing: Icon(Icons.copy_rounded, size: 18, color: s.accent),
                  onTap: () => copyWithFeedback(context, identity.originDenom!, 'Issuer denom'),
                ),
              ZuniaListTile(title: 'Named from', value: _provenanceText(identity)),
            ],
          ),
          const SizedBox(height: 20),
          const ZuniaSectionLabel('Recent activity'),
          const SizedBox(height: 6),
          activity.when(
            data: (rows) {
              final mine = [
                for (final row in rows)
                  if (row.denom == null ? native && row.amount == null : row.denom == target) row,
              ].take(10).toList();
              if (mine.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('No recent movements of ${identity.ticker} here.',
                      style: zuniaSans(fontSize: 13, color: s.fgMuted)),
                );
              }
              return Column(
                children: [
                  for (final row in mine)
                    ActivityRow(
                      item: row,
                      hidden: hidden,
                      showChain: false,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => TxDetailScreen(item: row)),
                      ),
                    ),
                ],
              );
            },
            loading: () => const ListSkeleton(count: 3, label: 'Loading activity'),
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error is ChainReadException
                    ? '${chain.chainName} did not return its history. ${error.failure.message}'
                    : '${chain.chainName} did not return its history.',
                style: zuniaSans(fontSize: 13, color: s.fgMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The trace hop by hop: `channel-750 → Noble`.
String? _pathText(TokenIdentity identity) {
  final parts = identity.path.isEmpty ? const <String>[] : identity.path.split('/');
  final hops = <String>[];
  for (var at = 0; at + 1 < parts.length; at += 2) {
    final index = at ~/ 2;
    final next = index < identity.hopChainIds.length ? identity.hopChainIds[index] : null;
    final name = next == null
        ? 'another chain'
        : (ChainCatalog.isLoaded ? ChainCatalog.instance.find(next)?.chainName : null) ?? next;
    hops.add('${parts[at + 1]} → $name');
  }
  return hops.isEmpty ? null : hops.join(' → ');
}

String _provenanceText(TokenIdentity identity) => switch (identity.provenance) {
      TokenProvenance.native => identity.listed ? 'Its own chain' : 'Nothing lists it',
      TokenProvenance.catalog => 'The chain registry',
      TokenProvenance.table => 'The verified token table',
      TokenProvenance.channelWalk => identity.proven ? 'A checked channel walk' : 'A channel walk, not verified',
      TokenProvenance.unknown => 'Nothing proves it',
    };

class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.spot, required this.currency, required this.decimalsKnown});

  final SpotPrice? spot;
  final String currency;
  final bool decimalsKnown;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final price = spot;
    if (price == null) {
      return Text(
        decimalsKnown ? 'No price for this token' : 'Not priced: its decimals are unknown',
        style: zuniaSans(fontSize: 12.5, color: s.fgDim),
      );
    }
    final up = price.change24h >= 0;
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(formatFiatPrice(price.price, currency),
            style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
        Text(
          '${formatChange(price.change24h, digits: 2)} 24h',
          style: zuniaMono(fontSize: 11.5, color: up ? s.success : s.danger),
        ),
        if (price.source case final source?)
          InkWell(
            onTap: () => openExternal(context, source.url),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'via ${source.name} · ${source.pair}',
                style: zuniaSans(fontSize: 12, color: s.accent, height: 1.2).copyWith(decoration: TextDecoration.underline),
              ),
            ),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.accent = false});

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Text(label, style: zuniaSans(fontSize: 14, color: s.fgMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: zuniaMono(fontSize: 13, color: accent ? s.accent : s.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: title,
            onBack: () => Navigator.of(context).maybePop(),
            body: body,
          ),
        ),
      );
}
