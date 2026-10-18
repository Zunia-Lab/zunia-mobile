/// Send any token, on the same chain or to another one.
///
/// Same chain is a `MsgSend`. Another chain is one ICS20 transfer planned by
/// the interchain engine (`lib/transfers/route_plan.dart`): a direct channel
/// when there is one, packet-forward middleware through a hub when not, and
/// every channel on the path checked on both chains (open, each end naming
/// the other, both light clients active) before the route can be signed.
///
/// Every token is named by its identity, and amounts are typed and converted
/// with the token's own exponent; a token whose decimals nobody knows takes
/// only Max. Fees come from a simulation (`TxEngine.quote`), at the speed and
/// gas adjustment the user keeps for every transaction.
///
/// Other screens and the scanner open it prefilled through the constructor
/// (or [SendScreen.fromRequest] for a payment request); nothing prefilled is
/// signed without the review.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/portfolio/portfolio.dart';
import 'package:zunia_mobile/screens/ibc_route_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/send_result_screen.dart';
import 'package:zunia_mobile/screens/send_review_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/fee_prefs.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/transfer_state.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/transfers/pending_transfers.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';
import 'package:zunia_mobile/transfers/send_arrival.dart';
import 'package:zunia_mobile/transfers/send_form.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_memo.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_mobile/widgets/pickers.dart';
import 'package:zunia_mobile/widgets/token_widgets.dart';
import 'package:zunia_ui/zunia_ui.dart';

class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({
    super.key,
    this.initialChainId,
    this.initialDenom,
    this.initialRecipient,
    this.initialAmount,
    this.initialMemo,
    this.initialDestChainId,
    this.initialCross = false,
  });

  /// Open on a payment request (`zunia://pay?…` or a plain address). The
  /// request's chain is where the recipient is; when it is enabled the send
  /// stays on it, otherwise the chain is found from the address prefix.
  factory SendScreen.fromRequest(PaymentRequest request, {Key? key}) {
    final enabledOn = request.chainId;
    return SendScreen(
      key: key,
      initialChainId: enabledOn,
      initialDenom: request.denom,
      initialRecipient: request.address,
      initialAmount: request.amount,
      initialMemo: request.memo,
    );
  }

  /// The chain to send from.
  final String? initialChainId;

  /// Exact bank denom on [initialChainId].
  final String? initialDenom;
  final String? initialRecipient;

  /// Base units of [initialDenom] (an integer string).
  final String? initialAmount;
  final String? initialMemo;

  /// Opens "Other chain" with this destination.
  final String? initialDestChainId;
  final bool initialCross;

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  late bool _cross = widget.initialCross || widget.initialDestChainId != null;
  String? _chainId;
  String? _destChainId;
  String? _denom;
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _memo = TextEditingController();
  bool _otherAddress = false;
  List<ManualChannel> _pins = const [];
  String? _amountScaleKey;

  String? _requestedKey;
  String? _planKey;
  TransferPlanResult? _plan;
  Timer? _debounce;
  int _retry = 0;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _chainId = widget.initialChainId;
    _destChainId = widget.initialDestChainId;
    _denom = widget.initialDenom;
    _recipient.text = widget.initialRecipient ?? '';
    _memo.text = widget.initialMemo ?? '';
    final accounts = ref.read(chainAccountsProvider);
    _resolvePrefillChain(accounts);
    _prefillAmount();
    if (_cross && _recipient.text.isNotEmpty) _otherAddress = true;
  }

  /// A request names the recipient's chain; when that chain is not enabled,
  /// the one whose prefix the address carries is used, if there is exactly one.
  void _resolvePrefillChain(List<ChainAccount> accounts) {
    final enabled = {for (final account in accounts) account.chain.chainId};
    if (_chainId != null && enabled.contains(_chainId)) return;
    final prefix = bech32Prefix(_recipient.text.trim());
    if (prefix == null) return;
    final matches = [for (final account in accounts) if (account.chain.bech32Prefix == prefix) account.chain];
    if (matches.length == 1) {
      if (_chainId != null && _chainId != matches.first.chainId) _denom = null;
      _chainId = matches.first.chainId;
    }
  }

  void _prefillAmount() {
    final units = widget.initialAmount;
    final chainId = _chainId;
    if (units == null || chainId == null || !ChainCatalog.isLoaded) return;
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) return;
    final denom = _denom ?? chain.coinMinimalDenom;
    final identity = denom == chain.coinMinimalDenom ? nativeIdentity(chain) : identityOf(chainId, denom);
    _amount.text = amountFieldText(units, identity.decimalsKnown ? identity.decimals : 0);
    _amountScaleKey = '${identity.key}|${identity.decimals}|${identity.decimalsKnown}';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _recipient.dispose();
    _amount.dispose();
    _memo.dispose();
    super.dispose();
  }

  void _resetRoute() {
    _pins = const [];
    _plan = null;
    _planKey = null;
    _requestedKey = null;
  }

  Future<void> _pickChain(List<ChainAccount> accounts, Map<String, ChainBalance> balances, bool hidden) async {
    final picked = await showChainSheet(
      context,
      title: _cross ? 'From network' : 'Network',
      selectedId: _chainId,
      options: [
        for (final account in accounts)
          ChainOption(
            chain: account.chain,
            trailing: balances[account.chain.chainId] == null
                ? null
                : formatTokenAmount(
                    balances[account.chain.chainId]!.available,
                    AmountScale.of(nativeIdentity(account.chain)),
                    TokenAmountVariant.list,
                    hidden: hidden,
                    unit: true,
                  ),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _chainId = picked;
      _denom = null;
      _amount.clear();
      _error = null;
      if (_destChainId == picked) _destChainId = null;
      _resetRoute();
    });
  }

  Future<void> _pickDest(List<ChainAccount> options, Map<String, RoutePath> reach) async {
    final picked = await showChainSheet(
      context,
      title: 'To network',
      selectedId: _destChainId,
      options: [
        for (final account in options)
          ChainOption(
            chain: account.chain,
            trailing: reach.containsKey(account.chain.chainId) ? 'direct' : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _destChainId = picked;
      _recipient.clear();
      _otherAddress = false;
      _error = null;
      _resetRoute();
    });
  }

  Future<void> _pickToken(ChainEntry chain, List<TokenOption> options, bool hidden) async {
    final picked = await showTokenSheet(context, options: options, selectedDenom: _denom ?? chain.coinMinimalDenom, hidden: hidden);
    if (picked == null || !mounted) return;
    setState(() {
      _denom = picked;
      _amount.clear();
      _error = null;
      _resetRoute();
    });
  }

  Future<void> _scanRecipient() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen(title: 'Scan address', extractAddress: true)),
    );
    if (!mounted || raw == null) return;
    setState(() {
      _recipient.text = extractBech32Address(raw) ?? raw;
      _otherAddress = true;
    });
  }

  Future<void> _pickContact(String? prefix) async {
    final address = await showContactSheet(context, ref, expectedPrefix: prefix);
    if (!mounted || address == null) return;
    setState(() {
      _recipient.text = address;
      _otherAddress = true;
    });
  }

  void _setPercent(int percent, BigInt spendable, AmountScale scale) {
    setState(() => _amount.text = percentText(spendable, percent, scale));
  }

  /// Plans after the user stops typing; an answer for inputs that have since
  /// changed is never shown as the current route.
  void _schedulePlan(String key, PlanInput input) {
    if (_requestedKey == key) return;
    _requestedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 450), () async {
        final result = await ref.read(transferPlannerProvider).planTransfer(input);
        if (!mounted || _requestedKey != key) return;
        setState(() {
          _plan = result;
          _planKey = key;
        });
      });
    });
  }

  Future<void> _editRoute(ChainEntry source, ChainEntry dest) async {
    final pins = await Navigator.of(context).push<List<ManualChannel>>(
      MaterialPageRoute(
        builder: (_) => RouteEditorScreen(
          sourceChainId: source.chainId,
          destChainId: dest.chainId,
          plan: _plan?.best,
          pins: _pins,
        ),
      ),
    );
    if (pins == null || !mounted) return;
    setState(() {
      _pins = pins;
      _plan = null;
      _planKey = null;
      _requestedKey = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final feePrefs = ref.watch(feePrefsProvider);
    final accounts = ref.watch(chainAccountsProvider);
    final portfolio = ref.watch(portfolioProvider);
    final contacts = ref.watch(addressBookProvider);
    ref.watch(identityGenerationProvider);

    if (accounts.isEmpty) {
      return _Page(
        title: 'Send',
        body: const Padding(
          padding: EdgeInsets.all(16),
          child: ZuniaEmptyState(
            title: 'No networks enabled',
            description: 'Enable a network before sending.',
          ),
        ),
      );
    }

    final account = accounts.firstWhere(
      (a) => a.chain.chainId == _chainId,
      orElse: () => accounts.first,
    );
    final chain = account.chain;
    final read = portfolio.chains[chain.chainId];
    final balance = read?.balance;
    final checking = balance == null && (read?.loading ?? portfolio.loadingAny);

    // Every token held here: the chain's own coin first, then the rest.
    final options = <TokenOption>[
      TokenOption(
        identity: nativeIdentity(chain),
        amount: balance?.available ?? '0',
        amountKnown: balance != null,
      ),
      for (final token in balance?.tokens ?? const <HeldToken>[])
        if (token.denom != chain.coinMinimalDenom && token.amount != '0')
          TokenOption(identity: rowIdentity(chain, token), amount: token.amount, amountKnown: true),
    ];
    final selected = options.firstWhere(
      (option) => option.identity.denom == (_denom ?? chain.coinMinimalDenom),
      orElse: () => options.first,
    );
    final identity = selected.identity;
    final scale = AmountScale.of(identity);
    final scaleKey = '${identity.key}|${identity.decimals}|${identity.decimalsKnown}';
    if (_amountScaleKey != null && _amountScaleKey != scaleKey && _amount.text.isNotEmpty) {
      // A text typed against another exponent reads as nothing, never as
      // another amount.
      _amount.clear();
    }
    _amountScaleKey = scaleKey;
    final maxOnly = !canTypeAmount(scale);
    final available = selected.amountKnown ? BigInt.tryParse(selected.amount) : null;
    final reserve = reservedFeeUnits(chain, identity.denom, feePrefs);
    final spendable = available == null ? null : maxSendable(available, reserve);
    final amount = checkAmount(text: _amount.text, scale: scale, spendable: spendable);

    // Destination, for another chain.
    final destOptions = [for (final a in accounts) if (a.chain.chainId != chain.chainId) a];
    final planner = ref.read(transferPlannerProvider);
    final reach = _cross ? planner.directReach(chain.chainId, destOptions.map((a) => a.chain.chainId)) : const <String, RoutePath>{};
    final sortedDest = [...destOptions]
      ..sort((a, b) => (reach.containsKey(a.chain.chainId) ? 0 : 1) - (reach.containsKey(b.chain.chainId) ? 0 : 1));
    final destAccount = !_cross || sortedDest.isEmpty
        ? null
        : sortedDest.firstWhere((a) => a.chain.chainId == _destChainId, orElse: () => sortedDest.first);
    final dest = destAccount?.chain;
    final selfOnDest = destAccount?.address;
    final usingSelf = _cross && !_otherAddress && (selfOnDest ?? '').isNotEmpty;
    final expectedPrefix = _cross ? dest?.bech32Prefix : chain.bech32Prefix;
    final recipientText = usingSelf ? '' : _recipient.text;
    final recipient = checkRecipient(
      value: recipientText,
      expectedPrefix: expectedPrefix,
      cross: _cross,
      ownAddress: account.address,
      selfOnDestination: usingSelf ? selfOnDest : null,
      contacts: contacts,
      destName: dest?.chainName,
    );
    final effectiveRecipient = usingSelf ? selfOnDest! : _recipient.text.trim();

    // Plan the route once the inputs that change it are settled.
    String? planKey;
    if (_cross && prefs.liveReads && dest != null && recipient.valid && amount.units != null &&
        amount.units! > BigInt.zero && !amount.overBalance) {
      final pins = withRegistryEnds(_pins);
      planKey = [
        chain.chainId,
        dest.chainId,
        identity.denom,
        amount.units.toString(),
        effectiveRecipient,
        for (final pin in pins) '${pin.fromChainId}>${pin.toChainId}:${pin.channelId}',
        _retry,
      ].join('~');
      _schedulePlan(
        planKey,
        PlanInput(
          sourceChainId: chain.chainId,
          destChainId: dest.chainId,
          inputDenom: identity.denom,
          amountBaseUnits: amount.units.toString(),
          sender: account.address,
          recipient: effectiveRecipient,
          manualChannels: pins,
          resolveAddresses: ref.read(intermediateAddressesProvider),
        ),
      );
    }
    final plan = _planKey == planKey && planKey != null ? _plan : null;
    final planning = planKey != null && _planKey != planKey;
    final best = plan?.best;

    final blocked = sendBlockedReason(
      hasChain: true,
      cross: _cross,
      liveReads: prefs.liveReads,
      hasDestination: dest != null,
      hasRecipient: !_cross || usingSelf || _recipient.text.trim().isNotEmpty || (selfOnDest ?? '').isNotEmpty,
      recipient: recipient,
      amount: amount,
      amountText: _amount.text,
      maxOnly: maxOnly,
      planning: planning,
      planError: plan?.error,
      planBlocked: best?.blockedReason,
      hasPlan: best != null,
      destName: dest?.chainName,
      sourceName: chain.chainName,
    );
    final canReview = blocked == null && !_busy;

    return _Page(
      title: 'Send',
      trailing: Text(truncateAddress(account.address, left: 6, right: 4),
          style: zuniaMono(fontSize: 10.5, color: s.fgDim)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _InFlightBanner(onOpen: (record) => _openTracked(record)),
          ZuniaSegmented<bool>(
            value: _cross,
            onChanged: (value) => setState(() {
              _cross = value;
              _recipient.clear();
              _otherAddress = false;
              _error = null;
              _resetRoute();
            }),
            options: const {false: 'Same chain', true: 'Other chain'},
          ),
          const SizedBox(height: 16),
          _ChainField(
            label: _cross ? 'From network' : 'Network',
            chain: chain,
            detail: balance == null
                ? (checking ? 'Reading balance…' : 'Balance not read')
                : formatTokenAmount(balance.available, AmountScale.of(nativeIdentity(chain)),
                        TokenAmountVariant.list,
                        hidden: prefs.hideAmounts, unit: true),
            onTap: () => _pickChain(accounts, portfolio.balances, prefs.hideAmounts),
          ),
          if (_cross) ...[
            const SizedBox(height: 10),
            if (dest == null)
              Text('Enable a second network to send to another chain.',
                  style: zuniaSans(fontSize: 13, color: s.fgMuted))
            else
              _ChainField(
                label: 'To network',
                chain: dest,
                detail: reach.containsKey(dest.chainId) ? 'Direct channel known' : 'No direct channel known yet',
                onTap: () => _pickDest(sortedDest, reach),
              ),
          ],
          const SizedBox(height: 16),
          if (usingSelf)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Arrives in this wallet on ${dest?.chainName ?? 'the destination'}.',
                    style: zuniaSans(fontSize: 13, color: s.fgMuted),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _otherAddress = true),
                  child: const Text('Use another address'),
                ),
              ],
            )
          else
            _RecipientField(
              controller: _recipient,
              hint: '${expectedPrefix ?? 'cosmos'}1…',
              check: recipient,
              onChanged: () => setState(() => _error = null),
              onScan: _scanRecipient,
              onBook: () => _pickContact(expectedPrefix),
              onUseSelf: _cross && (selfOnDest ?? '').isNotEmpty
                  ? () => setState(() {
                        _recipient.clear();
                        _otherAddress = false;
                      })
                  : null,
              contacts: [
                for (final contact in contacts)
                  if (expectedPrefix == null || contact.address.startsWith('${expectedPrefix}1')) contact,
              ],
            ),
          const SizedBox(height: 16),
          _AmountCard(
            controller: _amount,
            identity: identity,
            scale: scale,
            available: available,
            spendable: spendable,
            reserve: reserve,
            checking: checking,
            hidden: prefs.hideAmounts,
            maxOnly: maxOnly,
            check: amount,
            onChanged: () => setState(() => _error = null),
            onPercent: (percent) => _setPercent(percent, spendable!, scale),
            onPickToken: () => _pickToken(chain, options, prefs.hideAmounts),
          ),
          if (balance == null && !checking && read?.failure != null) ...[
            const SizedBox(height: 10),
            ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: 'Balance not available',
              body: '${read!.failure!.message} This is not a statement that the account is empty; '
                  'the amount cannot be checked against your holdings until the read succeeds.',
            ),
            // Retrying helps only when there is a request to repeat.
            if (read.failure!.kind != ChainReadFailureKind.readsDisabled &&
                read.failure!.kind != ChainReadFailureKind.noEndpoint) ...[
              const SizedBox(height: 6),
              ZuniaButton(
                label: 'Retry balance read',
                size: ZuniaButtonSize.sm,
                variant: ZuniaButtonVariant.secondary,
                onPressed: () => ref.read(portfolioProvider.notifier).refresh(force: true),
              ),
            ],
          ],
          if (identity.denom == chain.coinMinimalDenom &&
              balance != null &&
              balance.available == '0' &&
              balance.otherDenoms.isNotEmpty &&
              isUserAddedChain(chain.chainId)) ...[
            const SizedBox(height: 10),
            ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: 'No ${identity.ticker} in this account',
              body: 'The endpoint listed ${balance.otherDenoms.length} other '
                  '${balance.otherDenoms.length == 1 ? 'denomination' : 'denominations'} for this address '
                  'but nothing under ${chain.coinMinimalDenom}. If this network was added by hand, check '
                  'its minimal denom before sending.',
            ),
          ],
          if (available == null && amount.units != null) ...[
            const SizedBox(height: 8),
            Text(
              checking
                  ? 'Your ${identity.ticker} balance is still being read, so this amount has not been checked against it.'
                  : 'Your ${identity.ticker} balance could not be read, so this amount has not been checked against it.',
              style: zuniaSans(fontSize: 12, color: s.warning),
            ),
          ],
          if (_cross && dest != null) ...[
            const SizedBox(height: 16),
            _RouteSection(
              source: chain,
              dest: dest,
              plan: plan,
              planning: planning,
              liveReads: prefs.liveReads,
              userPins: _pins,
              previewPath: reach[dest.chainId],
              onRetry: () => setState(() {
                planner.reset();
                _retry += 1;
              }),
              onEdit: () => _editRoute(chain, dest),
            ),
          ],
          if (!_cross) ...[
            const SizedBox(height: 16),
            ZuniaInput(
              controller: _memo,
              label: 'MEMO (OPTIONAL)',
              hint: 'Leave empty for a Zunia default',
              inputFormatters: [_MaxLengthFormatter(256)],
              onChanged: (_) => setState(() {}),
            ),
          ],
          if (chain.isTestnet) ...[
            const SizedBox(height: 12),
            const Align(alignment: Alignment.centerLeft, child: ZuniaPill('Testnet funds')),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            ZuniaCallout(tone: ZuniaCalloutTone.danger, title: 'Could not prepare the send', body: _error!),
          ],
          const SizedBox(height: 14),
          Text(
            'SIGNED ON THIS DEVICE',
            textAlign: TextAlign.center,
            style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim),
          ),
        ],
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZuniaButton(
            label: _busy ? 'Preparing…' : 'Review',
            size: ZuniaButtonSize.lg,
            loading: _busy,
            onPressed: canReview
                ? () => _review(
                      account: account,
                      chain: chain,
                      dest: dest,
                      identity: identity,
                      units: amount.units!,
                      recipient: effectiveRecipient,
                      usingSelf: usingSelf,
                      plan: best,
                    )
                : null,
          ),
          if (blocked != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                blocked,
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openTracked(PendingTransfer record) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendResultScreen.tracked(record: record)));
  }

  Future<void> _review({
    required ChainAccount account,
    required ChainEntry chain,
    required ChainEntry? dest,
    required TokenIdentity identity,
    required BigInt units,
    required String recipient,
    required bool usingSelf,
    required RoutePlanView? plan,
  }) async {
    final phrase = ref.read(phraseProvider);
    final index = ref.read(walletProvider).active?.index;
    if (phrase == null || index == null) {
      setState(() => _error = 'Unlock the wallet to sign.');
      return;
    }
    final coin = TxCoin(identity.denom, units.toString());
    final List<TxMsg> msgs;
    final String memo;
    if (_cross) {
      if (plan == null || dest == null) return;
      final hop = plan.plan.hops.first;
      msgs = [
        TxMsg.transfer(
          sourcePort: hop.port,
          sourceChannel: hop.channelId,
          token: coin,
          sender: account.address,
          receiver: plan.receiver,
          timeoutTimestampNanos: timeoutNanos(DateTime.now(), kTransferTimeoutMinutes),
          memo: plan.plan.memo,
        ),
      ];
      memo = resolveTxMemo('', msgs, chain.chainId);
    } else {
      msgs = [TxMsg.send(from: account.address, to: recipient, amount: [coin])];
      memo = resolveTxMemo(_memo.text, msgs, chain.chainId);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fee = ref.read(feePrefsProvider);
      final quote = await TxEngine.instance.quote(
        phrase: phrase,
        accountIndex: index,
        chain: chain,
        signer: account.address,
        msgs: msgs,
        memo: memo,
        speed: fee.speed,
        gasAdjustment: fee.gasAdjustment,
      );
      if (!mounted) return;
      final contact = ref.read(addressBookProvider).where((c) => c.address == recipient).firstOrNull;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SendReviewScreen(
          review: SendReview(
            chain: chain,
            dest: _cross ? dest : null,
            sender: account.address,
            identity: identity,
            units: units,
            recipient: recipient,
            recipientLabel: contact?.label ?? (usingSelf ? 'Your own address' : null),
            usingSelf: usingSelf,
            quote: quote,
            plan: plan,
            userPins: _pins,
          ),
        ),
      ));
    } on Object catch (error) {
      if (!mounted) return;
      ZuniaHaptics.error();
      setState(() => _error = plainSendError(error, chain.chainName));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Unix nanoseconds [minutes] from [now], as ICS20 wants it.
String timeoutNanos(DateTime now, int minutes) =>
    (BigInt.from(now.add(Duration(minutes: minutes)).microsecondsSinceEpoch) * BigInt.from(1000)).toString();

/// A failure while preparing or signing, in plain words.
String plainSendError(Object error, String chainName) {
  final text = '$error';
  if (text.contains('Account query HTTP 404')) {
    return 'This address has never received funds on $chainName, so it cannot pay a fee yet.';
  }
  return explainChainError(text);
}

/* -------------------------------------------------------------------------- *
 * Pieces
 * -------------------------------------------------------------------------- */

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.body, this.footer, this.trailing});

  final String title;
  final Widget body;
  final Widget? footer;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: title,
            onBack: () => Navigator.of(context).maybePop(),
            trailing: trailing,
            body: body,
            footer: footer,
          ),
        ),
      );
}

class _ChainField extends StatelessWidget {
  const _ChainField({required this.label, required this.chain, required this.detail, required this.onTap});

  final String label;
  final ChainEntry chain;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Semantics(
      button: true,
      label: '$label: ${chain.chainName}, $detail. Change',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim)),
          const SizedBox(height: 6),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  gradient: s.surfaceRaisedGradient,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: s.line),
                ),
                child: Row(
                  children: [
                    ChainAvatar(chain: chain, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(chain.chainName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg)),
                          Text(detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: zuniaMono(fontSize: 10.5, color: s.fgMuted)),
                        ],
                      ),
                    ),
                    Icon(Icons.unfold_more, size: 18, color: s.fgMuted),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipientField extends StatelessWidget {
  const _RecipientField({
    required this.controller,
    required this.hint,
    required this.check,
    required this.onChanged,
    required this.onScan,
    required this.onBook,
    required this.contacts,
    this.onUseSelf,
  });

  final TextEditingController controller;
  final String hint;
  final RecipientCheck check;
  final VoidCallback onChanged;
  final VoidCallback onScan;
  final VoidCallback onBook;
  final VoidCallback? onUseSelf;
  final List<AddressBookEntry> contacts;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final color = switch (check.tone) {
      RecipientTone.error => s.danger,
      RecipientTone.valid => s.success,
      RecipientTone.empty => s.fgMuted,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('TO', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim))),
            if (onUseSelf != null)
              TextButton(onPressed: onUseSelf, child: const Text('Use this wallet')),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          style: zuniaMono(fontSize: 13, color: s.fg),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: zuniaMono(fontSize: 13, color: s.fgDim),
            filled: true,
            fillColor: s.glass,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: s.line)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: check.tone == RecipientTone.error ? s.dangerLine : s.line),
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Scan an address',
                  onPressed: onScan,
                  icon: Icon(Icons.qr_code_scanner, size: 20, color: s.fgMuted),
                ),
                IconButton(
                  tooltip: 'Address book',
                  onPressed: onBook,
                  icon: Icon(Icons.contacts_outlined, size: 20, color: s.fgMuted),
                ),
              ],
            ),
          ),
        ),
        if (check.hint != null) ...[
          const SizedBox(height: 6),
          Text(check.hint!, style: zuniaMono(fontSize: 10.5, color: color)),
        ],
        if (controller.text.isEmpty && contacts.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final contact in contacts.take(8))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: ZuniaWalletAvatar(seed: contact.address, size: 18, semanticLabel: ''),
                      label: Text(contact.label, style: zuniaSans(fontSize: 12, color: s.fg)),
                      onPressed: () {
                        controller.text = contact.address;
                        onChanged();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({
    required this.controller,
    required this.identity,
    required this.scale,
    required this.available,
    required this.spendable,
    required this.reserve,
    required this.checking,
    required this.hidden,
    required this.maxOnly,
    required this.check,
    required this.onChanged,
    required this.onPercent,
    required this.onPickToken,
  });

  final TextEditingController controller;
  final TokenIdentity identity;
  final AmountScale scale;
  final BigInt? available;
  final BigInt? spendable;
  final BigInt reserve;
  final bool checking;
  final bool hidden;
  final bool maxOnly;
  final AmountCheck check;
  final VoidCallback onChanged;
  final ValueChanged<int> onPercent;
  final VoidCallback onPickToken;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final availableText = available == null
        ? (checking ? 'Reading balance…' : 'Balance unknown')
        : '${formatTokenAmount(available!, scale, TokenAmountVariant.picker, hidden: hidden)} available';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: s.glass,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: check.error != null ? s.dangerLine : s.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOU SEND', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.3, color: s.fgDim)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  availableText,
                  textAlign: TextAlign.end,
                  style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  readOnly: maxOnly,
                  onChanged: (_) => onChanged(),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: const [DecimalDigitFormatter()],
                  style: zuniaSans(
                    fontSize: 30,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1,
                    color: maxOnly ? s.fgMuted : s.fg,
                    tabular: const FontFeature.tabularFigures(),
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '0',
                    hintStyle: zuniaSans(fontSize: 30, fontWeight: FontWeight.w500, color: s.fgFaint),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: 'Token: ${tokenText(identity, TokenTextVariant.a11y)}${identity.proven ? ', verified' : ''}. Change',
                excludeSemantics: true,
                child: InkWell(
                  onTap: onPickToken,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 160),
                    padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
                    decoration: BoxDecoration(
                      color: s.glass2,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: s.line),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TokenAvatar(identity: identity, size: 26),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TokenTicker.of(identity,
                                  style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w600, color: s.fg)),
                              Text(
                                tokenText(identity, TokenTextVariant.pill),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: zuniaMono(fontSize: 9.5, color: s.fgMuted),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.expand_more, size: 16, color: s.fgMuted),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (maxOnly) ...[
            const SizedBox(height: 6),
            Text(maxOnlyNote, style: zuniaSans(fontSize: 12, color: s.fgMuted)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              for (final percent in const [25, 50, 75, 100])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: percent == 100 ? 0 : 6),
                    child: _PercentChip(
                      label: percent == 100 ? 'MAX' : '$percent%',
                      semantics: percent == 100 ? 'Send the maximum' : 'Send $percent percent',
                      onTap: spendable == null || (maxOnly && percent != 100)
                          ? null
                          : () {
                              ZuniaHaptics.selection();
                              onPercent(percent);
                            },
                    ),
                  ),
                ),
            ],
          ),
          if (reserve > BigInt.zero && available != null) ...[
            const SizedBox(height: 6),
            Text(
              'Max keeps ${formatTokenAmount(reserve, scale, TokenAmountVariant.confirm, hidden: hidden, unit: true)} back for the network fee.',
              style: zuniaSans(fontSize: 11.5, color: s.fgDim),
            ),
          ],
          if (check.error != null) ...[
            const SizedBox(height: 6),
            Text(check.error!, style: zuniaMono(fontSize: 10.5, color: s.danger)),
          ],
        ],
      ),
    );
  }
}

class _PercentChip extends StatelessWidget {
  const _PercentChip({required this.label, required this.semantics, required this.onTap});

  final String label;
  final String semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: s.line),
          ),
          child: Text(label, style: zuniaMono(fontSize: 11, color: enabled ? s.fg : s.fgDim)),
        ),
      ),
    );
  }
}

class _RouteSection extends ConsumerWidget {
  const _RouteSection({
    required this.source,
    required this.dest,
    required this.plan,
    required this.planning,
    required this.liveReads,
    required this.userPins,
    required this.previewPath,
    required this.onRetry,
    required this.onEdit,
  });

  final ChainEntry source;
  final ChainEntry dest;
  final TransferPlanResult? plan;
  final bool planning;
  final bool liveReads;
  final List<ManualChannel> userPins;
  final RoutePath? previewPath;
  final VoidCallback onRetry;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final planner = ref.read(transferPlannerProvider);
    final best = plan?.best;
    if (!liveReads) {
      return const ZuniaCallout(
        tone: ZuniaCalloutTone.info,
        title: 'Live reads are off',
        body: 'Sending to another chain plans and checks the route on public endpoints. '
            'Turn on live reads in Settings.',
      );
    }
    final hops = best?.hops ?? (previewPath == null ? const <RouteHopView>[] : planner.pathHopViews(previewPath!.links));
    final warnings = best != null
        ? routeNotes(best.warnings, const [], userPins, planner.chainName)
        : (plan?.warnings ?? const <String>[]);
    return ZuniaRoutePreview(
      compact: MediaQuery.sizeOf(context).width < 360,
      hops: [for (final hop in hops) routePreviewHop(hop)],
      estimatedDurationSeconds: best?.plan.estimatedDurationSeconds,
      warnings: warnings,
      requiresPfm: best?.plan.requiresPfm ?? false,
      gasChainName: source.chainName,
      loading: planning && best == null,
      error: plan?.error,
      onRetry: onRetry,
      emptyTitle: 'No route yet',
      emptyDescription:
          'Enter the recipient and an amount, and Zunia plans the transfer from ${source.chainName} to ${dest.chainName}.',
      footer: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (best?.failedCheck?.verdict == ChannelHopVerdict.inconclusive)
              ZuniaButton(
                label: 'Check again',
                size: ZuniaButtonSize.sm,
                variant: ZuniaButtonVariant.secondary,
                onPressed: onRetry,
              ),
            ZuniaButton(
              label: userPins.isEmpty ? 'Edit route' : 'Edit route (${userPins.length} set by you)',
              size: ZuniaButtonSize.sm,
              variant: ZuniaButtonVariant.ghost,
              onPressed: onEdit,
            ),
            if (best == null && !planning && plan != null)
              Text(
                'Discovery reads each chain\'s channel list; if you know the channel, enter it.',
                style: zuniaSans(fontSize: 11.5, color: s.fgDim),
              ),
          ],
        ),
      ),
    );
  }
}

/// A planned hop as the route preview draws it.
ZuniaRoutePreviewHop routePreviewHop(RouteHopView hop) => ZuniaRoutePreviewHop(
      chainId: hop.chainId,
      chainName: hop.chainName,
      chainIconUrl: ChainCatalog.isLoaded ? ChainCatalog.instance.find(hop.chainId)?.iconUrl : null,
      counterpartyChainId: hop.counterpartyChainId,
      counterpartyChainName: hop.counterpartyChainName,
      counterpartyChainIconUrl: hop.counterpartyChainId == null || !ChainCatalog.isLoaded
          ? null
          : ChainCatalog.instance.find(hop.counterpartyChainId!)?.iconUrl,
      channelId: hop.channelId,
      port: hop.port,
      kind: switch (hop.kind) {
        RouteHopKind.forward => ZuniaRouteHopKind.forward,
        RouteHopKind.swap => ZuniaRouteHopKind.swap,
        RouteHopKind.transfer => ZuniaRouteHopKind.transfer,
      },
      channelSource: switch (hop.channelSource) {
        ChannelLinkSource.manual => ZuniaChannelSource.manual,
        ChannelLinkSource.verified => ZuniaChannelSource.discovered,
        _ => ZuniaChannelSource.seed,
      },
      channelVerified: hop.channelVerified,
      channelState: switch (hop.channelState) {
        IbcChannelState.open => ZuniaChannelState.open,
        IbcChannelState.closed => ZuniaChannelState.closed,
        IbcChannelState.init => ZuniaChannelState.init,
        IbcChannelState.tryopen => ZuniaChannelState.tryopen,
        IbcChannelState.unknown => ZuniaChannelState.unknown,
        null => null,
      },
    );

/// Transfers still on their way, so a send that is still moving is one tap away.
class _InFlightBanner extends ConsumerWidget {
  const _InFlightBanner({required this.onOpen});

  final ValueChanged<PendingTransfer> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final state = ref.watch(pendingTransfersProvider);
    final open = [
      for (final record in state.records)
        if (record.kind == 'transfer' && !(state.tracked[record.txHash]?.finished ?? false)) record,
    ];
    if (open.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          for (final record in open.take(2))
            Material(
              color: s.infoFill,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onOpen(record),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.sync_alt, size: 18, color: s.info),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'In flight: ${record.label}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(fontSize: 13, color: s.fg),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: s.fgMuted),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MaxLengthFormatter extends TextInputFormatter {
  _MaxLengthFormatter(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.text.length > max ? oldValue : newValue;
}
