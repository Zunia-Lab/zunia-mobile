import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/ibc_route_screen.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Send (same chain) or Cross-send (IBC) with a simple two-step flow.
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key, this.chainId});

  final String? chainId;

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  final _amount = TextEditingController();
  late String? _chainId = widget.chainId;
  String? _destChainId;
  String _mode = 'send';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// Scales the available balance in base units so no double rounding can
  /// creep in, then writes the canonical '.' form. The field accepts ',' as
  /// well, so a keyboard without a '.' key can still edit the result.
  void _setPercent(int percent, String available, int decimals) {
    final base = BigInt.tryParse(available) ?? BigInt.zero;
    final scaled = base * BigInt.from(percent) ~/ BigInt.from(100);
    _amount.text = formatBaseUnitsExact(scaled.toString(), decimals: decimals);
    setState(() {});
  }

  /// A mistake the user can see and fix. Null while the field is still empty
  /// or the amount is usable, so nothing turns red before anything is typed.
  ///
  /// [overBalance] may only be true when a balance was actually read. Deriving
  /// it from an unread balance is what let one rate-limited refresh tell a
  /// funded user the amount was more than they held.
  String? _amountError(
    AmountInput amount, {
    required bool overBalance,
    required String denom,
    required int decimals,
  }) {
    if (overBalance) return 'More than your $denom balance';
    switch (amount.issue) {
      case null:
      case AmountIssue.empty:
        return null;
      case AmountIssue.notANumber:
        return 'Use digits with , or . before the decimals';
      case AmountIssue.negative:
        return 'Enter a positive amount';
      case AmountIssue.notPositive:
        return 'Enter an amount above 0';
      case AmountIssue.tooManyDecimals:
        return '$denom carries $decimals decimals';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final prefs = ref.watch(preferencesProvider);
    final accounts = ref.watch(chainAccountsProvider);

    if (accounts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: ZuniaScreenScaffold(
            title: 'Send',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'No networks enabled',
              description: 'Enable a chain before sending.',
            ),
          ),
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;
    final account = accounts.firstWhere((a) => a.chain.chainId == chainId);
    final chain = account.chain;
    final destOptions =
        accounts.where((a) => a.chain.chainId != chainId).toList();
    final destId = destOptions.any((a) => a.chain.chainId == _destChainId)
        ? _destChainId!
        : (destOptions.isEmpty ? null : destOptions.first.chain.chainId);
    final balances = ref.watch(balancesProvider);
    final balance = balances.valueOrNull?[chainId];
    final failure = ref.watch(balanceFailuresProvider)[chainId];

    // Three states that must never collapse into one another: a number the
    // endpoint gave us, a read still in flight, and no number with a reason.
    // Only `available != null` is a fact about the account, so only that may
    // be compared against the typed amount.
    final available = balance?.available;
    final checking = available == null && balances.isLoading;
    final String? unknownReason;
    if (available != null || checking) {
      unknownReason = null;
    } else if (failure != null) {
      unknownReason = failure.message;
    } else if (balances.hasError) {
      unknownReason = 'The balance read did not complete.';
    } else {
      unknownReason = 'The wallet has not read this balance yet.';
    }
    // Retrying only helps when there is a request to repeat. Offering it for
    // reads that are switched off or have no endpoint would be a dead control.
    final retryable = unknownReason != null &&
        failure?.kind != ChainReadFailureKind.readsDisabled &&
        failure?.kind != ChainReadFailureKind.noEndpoint;
    // A read that came back with no row for this denom, on an account that
    // does hold other denoms, is far more likely a wrong coinMinimalDenom in
    // the chain entry than an empty account. Say so rather than let the user
    // read a bare 0 as their balance.
    final otherDenoms = balance?.otherDenoms ?? const <String>[];
    final denomMissing = available == '0' && otherDenoms.isNotEmpty;

    final cross = _mode == 'cross';
    final amount = parseAmount(_amount.text, decimals: chain.coinDecimals);
    final overBalance = amount.isValid &&
        available != null &&
        (BigInt.tryParse(amount.baseUnits) ?? BigInt.zero) >
            (BigInt.tryParse(available) ?? BigInt.zero);
    final amountError = _amountError(
      amount,
      overBalance: overBalance,
      denom: chain.coinDenom,
      decimals: chain.coinDecimals,
    );
    final ready = amount.isValid && !overBalance && (!cross || destId != null);
    // A disabled CTA has to say what is missing.
    final blocked = ready
        ? null
        : amountError ??
            (cross && destId == null
                ? 'Enable a second network to cross-send'
                : 'Enter an amount to continue');
    // The step stays passable when the balance is unknown - a flaky endpoint
    // is not a reason to lock the wallet - but the footer says the amount was
    // not checked instead of implying it was.
    final unchecked = ready && available == null;
    final availableLabel = available == null
        ? (checking ? 'Checking balance…' : 'Balance unavailable')
        : '${prefs.mask(formatBaseUnits(available, decimals: chain.coinDecimals))} available';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Send',
          onBack: () => Navigator.of(context).pop(),
          trailing: Text(
            '1 / 2',
            style: zuniaMono(fontSize: 11, color: s.fgDim),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaSegmented<String>(
                value: _mode,
                onChanged: (v) => setState(() => _mode = v),
                options: const {
                  'send': 'Send',
                  'cross': 'Cross-send',
                },
              ),
              const SizedBox(height: 28),
              Text(
                'AMOUNT',
                textAlign: TextAlign.center,
                style: zuniaMono(
                  fontSize: 10,
                  letterSpacing: 1.6,
                  color: s.fgMuted,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      // Separators are normalised on read, so both are let in.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9.,\u00A0\u202F ]'),
                        ),
                      ],
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 40,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -1.8,
                        height: 1,
                        color: s.fg,
                        tabular: FontFeature.tabularFigures(),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0.00',
                        hintStyle: zuniaSans(
                          fontSize: 40,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -1.8,
                          color: s.fgDim,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Text(
                    chain.coinDenom,
                    style: zuniaMono(fontSize: 15, color: s.fgMuted),
                  ),
                ],
              ),
              if (amountError != null) ...[
                const SizedBox(height: 12),
                Text(
                  amountError,
                  textAlign: TextAlign.center,
                  style: zuniaMono(fontSize: 10.5, color: s.danger),
                ),
              ],
              if (checking) ...[
                const SizedBox(height: 12),
                Text(
                  'Checking your ${chain.coinDenom} balance…',
                  textAlign: TextAlign.center,
                  style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                ),
              ],
              if (unknownReason != null) ...[
                const SizedBox(height: 18),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'Balance not available',
                  body: '$unknownReason This is not a statement that the '
                      'account is empty. The amount cannot be checked against '
                      'your holdings and the percentage shortcuts cannot be '
                      'worked out until the read succeeds.',
                ),
                if (retryable) ...[
                  const SizedBox(height: 10),
                  ZuniaButton(
                    label: 'Retry balance read',
                    size: ZuniaButtonSize.sm,
                    variant: ZuniaButtonVariant.secondary,
                    onPressed: () => ref.invalidate(balancesProvider),
                  ),
                ],
              ],
              if (denomMissing) ...[
                const SizedBox(height: 18),
                ZuniaCallout(
                  tone: ZuniaCalloutTone.warning,
                  title: 'No ${chain.coinDenom} in this account',
                  body: 'The endpoint listed '
                      '${otherDenoms.length} other '
                      '${otherDenoms.length == 1 ? 'denomination' : 'denominations'} '
                      'for this address but nothing under '
                      '${chain.coinMinimalDenom}. If this network was added by '
                      'hand, check its minimal denom before sending.',
                ),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  for (final percent in const [25, 50, 75, 100])
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: percent == 100 ? 0 : 7,
                        ),
                        child: _PercentChip(
                          label: percent == 100 ? 'MAX' : '$percent%',
                          accent: percent == 100,
                          // A share of a balance nobody has read is not a
                          // number this wallet has. Disabled, with the reason
                          // stated directly above.
                          onTap: available == null
                              ? null
                              : () => _setPercent(
                                    percent,
                                    available,
                                    chain.coinDecimals,
                                  ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 26),
              Text(
                cross ? 'From' : 'Network',
                style: zuniaMono(fontSize: 10, color: s.fgDim),
              ),
              const SizedBox(height: 8),
              ChainPicker(
                value: chainId,
                subtitle: availableLabel,
                onChanged: (v) => setState(() {
                  _chainId = v;
                  if (_destChainId == v) _destChainId = null;
                }),
              ),
              if (cross) ...[
                const SizedBox(height: 12),
                Text(
                  'To network',
                  style: zuniaMono(fontSize: 10, color: s.fgDim),
                ),
                const SizedBox(height: 8),
                if (destOptions.isEmpty)
                  Text(
                    'Enable a second network for Cross-send.',
                    style: zuniaSans(fontSize: 13, color: s.fgDim),
                  )
                else
                  ChainPicker(
                    value: destId!,
                    chains: destOptions.map((a) => a.chain).toList(),
                    onChanged: (v) => setState(() => _destChainId = v),
                  ),
              ],
              const SizedBox(height: 16),
              ZuniaCard(
                tone: ZuniaCardTone.glass,
                padding: const EdgeInsets.all(14),
                radius: 14,
                child: Column(
                  children: [
                    ZuniaKeyValueRow(
                      label: 'From',
                      value: truncateAddress(account.address),
                    ),
                    const SizedBox(height: 10),
                    ZuniaKeyValueRow(label: 'Chain', value: chain.chainId),
                    const SizedBox(height: 10),
                    ZuniaKeyValueRow(
                      label: 'Fee denom',
                      value: chain.feeDenom,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ZuniaCallout(
                tone: ZuniaCalloutTone.info,
                title: cross ? 'IBC transfer' : 'Same-chain send',
                body: cross
                    ? 'Next you pick a recipient on the destination chain and '
                        'confirm an open IBC channel.'
                    : 'Next you pick a recipient on this network.',
              ),
            ],
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaButton(
                label: 'Choose recipient',
                size: ZuniaButtonSize.lg,
                onPressed: ready
                    ? () {
                        final dest = destId == null
                            ? null
                            : ChainCatalog.instance.find(destId);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => IbcRouteScreen(
                              chainId: chain.chainId,
                              denom: chain.coinDenom,
                              // Normalised, so the review step and the message
                              // never show a different figure than was typed.
                              amount: amount.normalized,
                              fromAddress: account.address,
                              sourcePrefix: chain.bech32Prefix,
                              destChainId: cross ? destId : null,
                              destPrefix: cross ? dest?.bech32Prefix : null,
                              forceIbc: cross,
                            ),
                          ),
                        );
                      }
                    : null,
              ),
              if (blocked != null) ...[
                const SizedBox(height: 8),
                Text(
                  blocked,
                  textAlign: TextAlign.center,
                  style: zuniaMono(fontSize: 10.5, color: s.fgMuted),
                ),
              ],
              if (unchecked) ...[
                const SizedBox(height: 8),
                Text(
                  checking
                      ? 'Your ${chain.coinDenom} balance is still being read, '
                          'so this amount has not been checked against it.'
                      : 'Your ${chain.coinDenom} balance could not be read, so '
                          'this amount has not been checked against it.',
                  textAlign: TextAlign.center,
                  style: zuniaMono(fontSize: 10.5, color: s.warning),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PercentChip extends StatelessWidget {
  const _PercentChip({
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final String label;

  /// Null disables the chip: there is no share of a balance the wallet has not
  /// read. The screen states the reason next to the row.
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final enabled = onTap != null;
    final Color foreground;
    if (!enabled) {
      foreground = s.fgDim;
    } else {
      foreground = accent ? s.info : s.fgMuted;
    }
    return Semantics(
      enabled: enabled,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: accent || !enabled ? Colors.transparent : s.glass,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: accent && enabled
                    ? s.info.withValues(alpha: 0.55)
                    : enabled
                        ? Colors.transparent
                        : s.line,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: zuniaMono(fontSize: 10.5, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
