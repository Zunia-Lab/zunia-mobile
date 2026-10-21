/// Receive: the address on every enabled network, as text and as a QR code
/// drawn on this device, and an optional payment request.
///
/// A payment request (`zunia://pay?…`, see `lib/util/address_payload.dart`)
/// carries the token, an amount in base units and a memo next to the
/// address; another Zunia reads it into Send, where every field is reviewed.
/// Any other wallet's scanner still finds the address inside it, and with no
/// amount the code is the plain address every wallet reads.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/pickers.dart';
import 'package:zunia_mobile/widgets/portfolio_feedback.dart';
import 'package:zunia_mobile/widgets/qr_code.dart';
import 'package:zunia_mobile/widgets/search_field.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _kFavorites = 'zunia.receive.favorites';

class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, this.chainId, this.denom});

  /// Open straight on this network's address.
  final String? chainId;

  /// Preselect this token for a payment request.
  final String? denom;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  final _search = TextEditingController();
  late String? _chainId = widget.chainId;
  Set<String> _favorites = {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadFavorites());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    final store = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _favorites = (store.getStringList(_kFavorites) ?? const []).toSet());
  }

  Future<void> _toggleFavorite(String chainId) async {
    ZuniaHaptics.selection();
    setState(() {
      if (!_favorites.remove(chainId)) _favorites.add(chainId);
    });
    final store = await SharedPreferences.getInstance();
    await store.setStringList(_kFavorites, _favorites.toList());
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);
    final selected = accounts.where((a) => a.chain.chainId == _chainId).firstOrNull;
    if (selected != null) {
      return _AddressPage(
        account: selected,
        initialDenom: widget.chainId == selected.chain.chainId ? widget.denom : null,
        onBack: () {
          if (widget.chainId != null) {
            Navigator.of(context).pop();
          } else {
            setState(() => _chainId = null);
          }
        },
      );
    }
    final query = _search.text.trim();
    final ranked = [
      ...accounts.where((a) => _favorites.contains(a.chain.chainId)),
      ...accounts.where((a) => !_favorites.contains(a.chain.chainId)),
    ];
    final shown = query.isEmpty
        ? ranked
        : [
            for (final a in ranked)
              if (a.chain.matches(query) || a.address.contains(query.toLowerCase())) a,
          ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Receive',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text('${accounts.length} network${accounts.length == 1 ? '' : 's'}',
              style: zuniaMono(fontSize: 10.5, color: s.fgDim)),
          body: accounts.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: ZuniaEmptyState(
                    title: 'No networks enabled',
                    description: 'Enable a network to get an address to receive on.',
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: AdaptiveSearchField(
                        controller: _search,
                        placeholder: 'Search a network',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    Expanded(
                      child: shown.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text('Nothing matches “$query”.',
                                  style: zuniaSans(fontSize: 13, color: s.fgMuted)),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                              itemCount: shown.length,
                              itemBuilder: (context, index) {
                                final account = shown[index];
                                final starred = _favorites.contains(account.chain.chainId);
                                return _NetworkRow(
                                  account: account,
                                  starred: starred,
                                  onTap: () => setState(() => _chainId = account.chain.chainId),
                                  onStar: () => _toggleFavorite(account.chain.chainId),
                                  onCopy: () => copyWithFeedback(context, account.address, 'Address'),
                                );
                              },
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.account,
    required this.starred,
    required this.onTap,
    required this.onStar,
    required this.onCopy,
  });

  final ChainAccount account;
  final bool starred;
  final VoidCallback onTap;
  final VoidCallback onStar;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            ChainAvatar(chain: account.chain, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: true,
                label: '${account.chain.chainName}, show the address and QR code',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.chain.chainName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg)),
                    Text(truncateAddress(account.address, left: 12, right: 6),
                        style: zuniaMono(fontSize: 11, color: s.fgMuted)),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: starred ? 'Remove ${account.chain.chainName} from favourites' : 'Add ${account.chain.chainName} to favourites',
              onPressed: onStar,
              icon: Icon(
                starred
                    ? (cupertino ? CupertinoIcons.star_fill : Icons.star_rounded)
                    : (cupertino ? CupertinoIcons.star : Icons.star_outline_rounded),
                size: 20,
                color: starred ? s.warning : s.fgDim,
              ),
            ),
            IconButton(
              tooltip: 'Copy the ${account.chain.chainName} address',
              onPressed: onCopy,
              icon: Icon(Icons.copy_rounded, size: 19, color: s.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// One network's address, its QR code, and an optional payment request.
class _AddressPage extends ConsumerStatefulWidget {
  const _AddressPage({required this.account, required this.onBack, this.initialDenom});

  final ChainAccount account;
  final VoidCallback onBack;
  final String? initialDenom;

  @override
  ConsumerState<_AddressPage> createState() => _AddressPageState();
}

class _AddressPageState extends ConsumerState<_AddressPage> {
  bool _requesting = false;
  late String _denom = widget.initialDenom ?? widget.account.chain.coinMinimalDenom;
  final _amount = TextEditingController();
  final _memo = TextEditingController();

  @override
  void initState() {
    super.initState();
    _requesting = widget.initialDenom != null && widget.initialDenom != widget.account.chain.coinMinimalDenom;
  }

  @override
  void dispose() {
    _amount.dispose();
    _memo.dispose();
    super.dispose();
  }

  List<TokenOption> _tokens(ChainBalance? balance) {
    final chain = widget.account.chain;
    final seen = <String>{};
    return [
      for (final option in [
        TokenOption(identity: nativeIdentity(chain), amount: balance?.available ?? '0', amountKnown: balance != null),
        for (final token in balance?.tokens ?? const <HeldToken>[])
          if (token.denom != chain.coinMinimalDenom)
            TokenOption(identity: rowIdentity(chain, token), amount: token.amount, amountKnown: true),
        for (final currency in chain.currencies)
          if (currency.coinMinimalDenom != chain.coinMinimalDenom && !currency.coinMinimalDenom.startsWith('ibc/'))
            TokenOption(identity: identityOf(chain.chainId, currency.coinMinimalDenom), amount: '0', amountKnown: false),
      ])
        if (seen.add(option.identity.denom)) option,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final account = widget.account;
    final chain = account.chain;
    final balance = ref.watch(portfolioProvider.select((state) => state.chains[chain.chainId]?.balance));
    final tokens = _tokens(balance);
    final token = tokens.firstWhere((t) => t.identity.denom == _denom, orElse: () => tokens.first);
    final identity = token.identity;
    final scale = AmountScale.of(identity);
    final parsed = parseAmount(_amount.text, decimals: scale.decimalsKnown ? scale.decimals : 0);
    final amountError = _amount.text.trim().isEmpty || parsed.isValid
        ? null
        : parsed.issue == AmountIssue.tooManyDecimals
            ? '${identity.ticker} carries ${scale.decimals} decimals'
            : 'Enter a positive amount';
    final memo = _memo.text.trim();
    final request = _requesting && (parsed.isValid || memo.isNotEmpty)
        ? PaymentRequest(
            address: account.address,
            chainId: chain.chainId,
            denom: parsed.isValid ? identity.denom : null,
            amount: parsed.isValid ? parsed.baseUnits : null,
            memo: memo.isEmpty ? null : memo,
          )
        : null;
    final payload = request == null ? account.address : buildPaymentRequestUri(request);
    final width = MediaQuery.sizeOf(context).width;
    final qrSize = (width - 96).clamp(180.0, 300.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Receive',
          onBack: widget.onBack,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Row(
                children: [
                  ChainAvatar(chain: chain, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(chain.chainName,
                            style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg)),
                        Text(chain.chainId, style: zuniaMono(fontSize: 10.5, color: s.fgMuted)),
                      ],
                    ),
                  ),
                  if (chain.isTestnet) const ZuniaPill('Testnet'),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: Semantics(
                  image: true,
                  label: request == null
                      ? 'QR code of your ${chain.chainName} address'
                      : 'QR code of a payment request on ${chain.chainName}',
                  child: QrCode(data: payload, size: qrSize),
                ),
              ),
              const SizedBox(height: 18),
              SelectableText(
                account.address,
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 13, height: 1.5, color: s.fg),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: ZuniaButton(
                      label: 'Copy',
                      leading: const Icon(Icons.copy_rounded),
                      onPressed: () => copyWithFeedback(context, account.address, 'Address'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Builder(
                      builder: (buttonContext) => ZuniaButton(
                        label: 'Share',
                        variant: ZuniaButtonVariant.secondary,
                        leading: Icon(ZuniaPlatform.isCupertino(context) ? CupertinoIcons.share : Icons.share_outlined),
                        onPressed: () => _share(buttonContext, payload, request != null),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Same network only',
                body: 'Only ${chain.bech32Prefix}1… addresses on ${chain.chainName} can send here directly. '
                    'Funds sent from another network without IBC or a bridge do not arrive and cannot be recovered.',
              ),
              const SizedBox(height: 18),
              ZuniaListSection(
                children: [
                  ZuniaListTile(
                    title: 'Request an amount',
                    subtitle: 'Put the token, an amount and a memo in the code',
                    trailing: ZuniaAdaptiveSwitch(
                      value: _requesting,
                      onChanged: (value) => setState(() => _requesting = value),
                    ),
                  ),
                ],
              ),
              if (_requesting) ...[
                const SizedBox(height: 12),
                Semantics(
                  button: true,
                  label: 'Token: ${tokenText(identity, TokenTextVariant.a11y)}. Change',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      final picked = await showTokenSheet(context, options: tokens, selectedDenom: identity.denom);
                      if (picked != null && mounted) {
                        setState(() {
                          _denom = picked;
                          _amount.clear();
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: s.glass,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: s.line),
                      ),
                      child: Row(
                        children: [
                          TokenAvatar(identity: identity, size: 30),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TokenTicker.of(identity),
                                Text(tokenText(identity, TokenTextVariant.row),
                                    style: zuniaSans(fontSize: 12, color: s.fgMuted)),
                              ],
                            ),
                          ),
                          Icon(Icons.unfold_more, size: 18, color: s.fgMuted),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ZuniaInput(
                  controller: _amount,
                  label: 'AMOUNT (${identity.ticker})',
                  hint: scale.decimalsKnown ? '0.00' : 'Base units',
                  errorText: amountError,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: const [DecimalDigitFormatter()],
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                ZuniaInput(
                  controller: _memo,
                  label: 'MEMO (OPTIONAL)',
                  hint: 'Invoice 42',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  request == null
                      ? 'Enter an amount or a memo to add them to the code.'
                      : 'Scanned in Zunia, this opens Send with ${parsed.isValid ? '${formatTokenAmount(parsed.baseUnits, scale, TokenAmountVariant.confirm, unit: true)} ' : ''}'
                          'to this address; the sender still reviews it. Other wallets read the address.',
                  style: zuniaSans(fontSize: 12, height: 1.4, color: s.fgDim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext buttonContext, String payload, bool isRequest) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final chain = widget.account.chain;
    await SharePlus.instance.share(ShareParams(
      text: isRequest ? payload : widget.account.address,
      subject: 'My ${chain.chainName} address',
      sharePositionOrigin: origin,
    ));
  }
}
