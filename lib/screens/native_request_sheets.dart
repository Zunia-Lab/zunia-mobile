/// The prompts a dApp request opens, shared by the in-app browser, Zunia
/// Connect and WalletConnect, so a request reads the same whichever way it
/// arrived (extension 0.1.5's ApproveScreen):
/// - a header with the kind of request, what approving does and a countdown;
/// - the action in the kernel's words: one headline for a single send, else
///   "Approve N messages", unknown messages in red;
/// - warnings (lookalike site, first-time recipient, undecoded message),
///   the account and every fee coin, a fee tier picker when the site allows it;
/// - "Transaction details" and "Raw transaction" folded, the latter whole;
/// - Reject and the action at the bottom, in reach of a thumb.
///
/// On iPhone the prompt is a page sheet; on Android a Material bottom sheet.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/approval_queue.dart';
import 'package:zunia_mobile/browser/dapp_provider_bridge.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/known_recipients.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/browser/signature_gate.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/config/nft_config.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/pair_device.dart';
import 'package:zunia_mobile/screens/dapp_connect_sheet.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/review_widgets.dart';
import 'package:zunia_mobile/util/amounts.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Routes a scanned code: pairing codes (Zunia Connect, WalletConnect), wake
/// links, sites and addresses. See `routeScannedCode` in pair_device.dart.
Future<void> handleScannedCode(
  BuildContext context,
  WidgetRef ref,
  String code,
) =>
    routeScannedCode(context, ref, code);

String _messageOf(Object error) => switch (error) {
      ConnectException(:final message) => message,
      ProviderError(:final message) => message,
      _ => 'Something went wrong. Ask the site for a new code.',
    };

/* -------------------------------------------------------------------------- *
 * What a prompt shows
 * -------------------------------------------------------------------------- */

enum ReviewKind { connect, transaction, message, signIn, addChain }

/// The site asking, as the wallet knows it.
class ReviewSite {
  const ReviewSite({required this.origin, this.name, this.pill});

  /// `https://host[:port]`: the page's origin, or the one the relay verified.
  final String origin;

  /// The name the site gives itself (Zunia Connect, WalletConnect).
  final String? name;

  /// A verdict on the origin shown beside the name (Zunia Connect's relay).
  final (String, ZuniaPillTone)? pill;

  String get host => webHost(origin) ?? origin.replaceFirst(RegExp(r'^[a-z]+://'), '');
}

class ReviewSheetData {
  const ReviewSheetData({
    required this.kind,
    required this.label,
    required this.effect,
    required this.site,
    required this.approveLabel,
    this.chainIds = const [],
    this.accountName,
    this.signer,
    this.expiresAt,
    this.queued = 0,
    this.review,
    this.feeChoice,
    this.rawJson,
    this.messagePreview,
    this.signIn,
    this.signInText,
    this.draft,
    this.warnings = const [],
    this.extras = const [],
    this.rows = const [],
    this.cannotApprove,
  });

  final ReviewKind kind;

  /// The header: "Signature request", "Sign-in request", ...
  final String label;

  /// What approving does, in one or two sentences.
  final String effect;
  final ReviewSite site;
  final String approveLabel;
  final List<String> chainIds;
  final String? accountName;

  /// The address that would sign, or that the site will see.
  final String? signer;

  /// The countdown; null for a request that does not lapse here.
  final DateTime? expiresAt;

  /// Requests waiting behind this one.
  final int queued;

  final SignReview? review;

  /// Offered only when the site allows another fee (`preferNoSetFee` unset).
  final FeeChoice? feeChoice;

  /// The "Raw transaction", whole.
  final String? rawJson;
  final String? messagePreview;
  final SignInMessage? signIn;
  final String? signInText;
  final ChainEntry? draft;

  /// Every warning for this request: the origin's and the transaction's.
  final List<String> warnings;

  /// Shown under the site: a verification code, an origin callout.
  final List<Widget> extras;

  /// Extra facts for the account card (Zunia Connect's session, expiry).
  final List<(String, String)> rows;

  /// Why this request cannot be approved at all; the action is off and the
  /// reason is shown (a WalletConnect build without a project id).
  final String? cannotApprove;

  bool get signs => kind == ReviewKind.transaction || kind == ReviewKind.message || kind == ReviewKind.signIn;
}

String _chainName(String chainId) =>
    (ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId)?.chainName : null) ?? chainId;

String _short(String address, {int left = 10, int right = 6}) =>
    address.length <= left + right + 1 ? address : '${address.substring(0, left)}…${address.substring(address.length - right)}';

/// "Send 1 uosmo to osmo1..." splits so the address wraps on its own line.
({String lead, String? address}) _splitRecipient(String summary) {
  final at = summary.lastIndexOf(' to ');
  if (at < 0) return (lead: summary, address: null);
  final address = summary.substring(at + 4);
  if (!RegExp(r'^[a-z0-9]{20,}$').hasMatch(address)) return (lead: summary, address: null);
  return (lead: summary.substring(0, at), address: address);
}

String _expiryLabel(String iso) {
  final at = DateTime.tryParse(iso);
  if (at == null) return iso;
  final minutes = (at.difference(DateTime.now()).inSeconds / 60).round();
  if (minutes < 1) return 'In less than a minute';
  if (minutes < 60) return 'In $minutes min';
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

/* -------------------------------------------------------------------------- *
 * Presenting
 * -------------------------------------------------------------------------- */

/// Shows [data] and waits until the user answers or the prompt closes. A
/// prompt closed without an answer is a rejection, as the extension rejects a
/// request whose window closes.
///
/// [onApprove] signs or connects; when it throws, the prompt stays open with
/// the error unless [stillPending] says the request is gone.
Future<void> showReviewSheet(
  BuildContext context, {
  required ReviewSheetData data,
  required Future<void> Function(FeeTier? tier) onApprove,
  required Future<void> Function() onReject,
  bool Function()? stillPending,
}) async {
  var answered = false;
  Widget sheet(BuildContext ctx) => _ReviewSheet(
        data: data,
        stillPending: stillPending,
        onApprove: (tier) async {
          await onApprove(tier);
          answered = true;
        },
        onReject: () async {
          answered = true;
          await onReject();
        },
      );
  if (ZuniaPlatform.isCupertino(context)) {
    await showCupertinoSheet<void>(context: context, builder: sheet);
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: ZuniaSemanticsExt.of(context).surface,
      builder: sheet,
    );
  }
  if (!answered) {
    try {
      await onReject();
    } catch (e) {
      debugPrint('reject on close: $e');
    }
  }
}

class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.data,
    required this.onApprove,
    required this.onReject,
    this.stillPending,
  });

  final ReviewSheetData data;
  final Future<void> Function(FeeTier? tier) onApprove;
  final Future<void> Function() onReject;
  final bool Function()? stillPending;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  FeeTier? _tier;
  bool _busy = false;
  bool _expired = false;
  String? _error;

  ReviewSheetData get data => widget.data;

  @override
  void initState() {
    super.initState();
    final expires = data.expiresAt;
    _expired = expires != null && !expires.isAfter(DateTime.now());
  }

  bool get _blocked => data.review?.requiresBlindSigning ?? false;

  Future<void> _approve() async {
    if (_busy || _expired || _blocked || data.cannotApprove != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The one place a dApp signature waits for the security gate (password
      // on every signature): see lib/browser/signature_gate.dart.
      if (data.signs &&
          !await confirmDappSignature(context, reason: '${data.label} from ${data.site.host}')) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      unawaited(ZuniaHaptics.medium());
      // A frame for the button to show it is working before key derivation blocks.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await widget.onApprove(_tier);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      unawaited(ZuniaHaptics.error());
      final message = _messageOf(error);
      if (widget.stillPending != null && !widget.stillPending!()) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop();
        messenger?.showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      setState(() {
        _busy = false;
        _error = message;
      });
    }
  }

  Future<void> _reject() async {
    if (_busy) return;
    setState(() => _busy = true);
    unawaited(ZuniaHaptics.error());
    try {
      await widget.onReject();
    } catch (e) {
      debugPrint('reject: $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    final risk = assessOrigin(data.site.origin);
    final suspicious = risk.suspicious;
    final local = data.warnings.contains(kLocalSiteWarning);
    // The origin's own warnings get the banner; the rest stay in the list.
    final warnings = data.warnings
        .where((w) => w != kLocalSiteWarning && !(suspicious && risk.warnings.contains(w)))
        .toList();

    final body = <Widget>[
      if (suspicious) ...[
        ZuniaCallout(
          tone: ZuniaCalloutTone.danger,
          title: "This site's address looks suspicious",
          body: '${data.site.origin}\n${risk.warnings.join('\n')}\n'
              'Reject unless you opened this address yourself and trust it.',
        ),
        const SizedBox(height: 12),
      ],
      if (_expired) ...[
        const ZuniaCallout(
          tone: ZuniaCalloutTone.warning,
          title: 'This request expired',
          body: 'Nothing was signed. Ask the site to send the request again.',
        ),
        const SizedBox(height: 12),
      ],
      if (data.cannotApprove != null) ...[
        ZuniaCallout(tone: ZuniaCalloutTone.info, title: 'Cannot connect', body: data.cannotApprove!),
        const SizedBox(height: 12),
      ],
      if (_blocked) ...[
        const ZuniaCallout(
          tone: ZuniaCalloutTone.danger,
          title: 'Blind signing required',
          body: 'This request contains messages Zunia could not decode. Turn on blind '
              'signing in Settings if you trust this dApp, or reject.',
        ),
        const SizedBox(height: 12),
      ],
      ...switch (data.kind) {
        ReviewKind.connect => _connectBody(context, local, warnings),
        ReviewKind.signIn => _signInBody(context, local, warnings),
        ReviewKind.transaction => _transactionBody(context, local, warnings),
        ReviewKind.message => _messageBody(context, local, warnings),
        ReviewKind.addChain => _addChainBody(context, warnings),
      },
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 14, color: s.fgDim),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              data.signs ? 'Signed on this device. The key never leaves it.' : 'Keys stay in Zunia.',
              textAlign: TextAlign.center,
              style: zuniaSans(fontSize: 11.5, color: s.fgDim),
            ),
          ),
        ],
      ),
    ];

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          data: data,
          suspicious: suspicious,
          onExpired: () {
            if (mounted) setState(() => _expired = true);
          },
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
          ),
        ),
        _Footer(
          busy: _busy,
          error: _error,
          approveLabel: data.approveLabel,
          canApprove: !_expired && !_blocked && data.cannotApprove == null,
          onApprove: _approve,
          onReject: _reject,
        ),
      ],
    );

    if (cupertino) {
      return Material(
        color: s.surface,
        child: SafeArea(top: false, child: content),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
      child: content,
    );
  }

  Widget _accountCard(BuildContext context, {List<(String, String)> extra = const [], bool fees = false}) {
    final s = ZuniaSemanticsExt.of(context);
    final review = data.review;
    final choice = data.feeChoice;
    // A picked tier is named in the fee coin's own words, which the choice carries.
    final feeRows = [
      for (final (label, value) in review?.fees ?? const <(String, String)>[])
        label == 'Fee' && choice != null
            ? ('Fee', '${formatBaseUnitsExact(choice.amountFor(_tier), decimals: choice.decimals)} ${choice.symbol}')
            : (label, value),
    ];
    return ReviewCard(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ACCOUNT', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.4, color: s.fgDim)),
            const SizedBox(height: 4),
            Text(
              data.accountName ?? 'Wallet',
              overflow: TextOverflow.ellipsis,
              style: zuniaSans(fontSize: 14, fontWeight: FontWeight.w500, color: s.fg),
            ),
            if (data.signer != null) ...[
              const SizedBox(height: 2),
              Text(
                _short(data.signer!, left: 12, right: 8),
                semanticsLabel: data.signer,
                style: zuniaMono(fontSize: 11.5, color: s.fgMuted),
              ),
            ],
          ],
        ),
        for (final (label, value) in [...extra, ...data.rows]) ReviewRow(label: label, value: value),
        if (fees)
          for (final (label, value) in feeRows) ReviewRow(label: label, value: value),
        if (fees && choice != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZuniaSegmented<String>(
                options: {
                  'site': 'Site',
                  for (final tier in FeeTier.values) tier.name: tier.label,
                },
                value: _tier?.name ?? 'site',
                onChanged: (value) => setState(() => _tier = FeeTier.parse(value)),
              ),
              const SizedBox(height: 6),
              Text(
                _tier?.hint ?? kSiteFeeHint,
                style: zuniaSans(fontSize: 11.5, color: s.fgDim, height: 1.35),
              ),
            ],
          ),
      ],
    );
  }

  List<Widget> _intro(BuildContext context, {required String headline, String? sub, String? note}) {
    final s = ZuniaSemanticsExt.of(context);
    return [
      const SizedBox(height: 8),
      Center(
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: s.glass,
            border: Border.all(color: s.line),
          ),
          child: Icon(Icons.language_rounded, size: 24, color: s.fg),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        headline,
        textAlign: TextAlign.center,
        style: zuniaSans(fontSize: 20, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: s.fg),
      ),
      if (sub != null) ...[
        const SizedBox(height: 4),
        Text(
          sub.toUpperCase(),
          textAlign: TextAlign.center,
          style: zuniaMono(fontSize: 10, letterSpacing: 1.4, color: s.fgDim),
        ),
      ],
      if (note != null) ...[
        const SizedBox(height: 12),
        Text(note, textAlign: TextAlign.center, style: zuniaSans(fontSize: 13.5, height: 1.5, color: s.fgMuted)),
      ],
    ];
  }

  Widget _localNote(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Running on this device.',
        textAlign: TextAlign.center,
        style: zuniaSans(fontSize: 12, color: s.fgDim),
      ),
    );
  }

  List<Widget> _connectBody(BuildContext context, bool local, List<String> warnings) {
    return [
      if (data.site.name != null || data.site.pill != null) ...[
        _SiteHeader(site: data.site),
        const SizedBox(height: 12),
      ] else
        ..._intro(
          context,
          headline: data.site.host,
          sub: data.chainIds.map(_chainName).join(' · '),
          note: 'This site can see your address. It cannot move funds.',
        ),
      for (final extra in data.extras) ...[extra, const SizedBox(height: 12)],
      if (data.site.name != null || data.site.pill != null) ...[
        Text(data.effect, style: _bodyStyle(context)),
        const SizedBox(height: 12),
      ],
      if (local) _localNote(context),
      if (warnings.isNotEmpty) ...[const SizedBox(height: 12), ReviewWarnings(warnings: warnings)],
      const SizedBox(height: 14),
      _accountCard(
        context,
        extra: [
          if (data.site.name != null || data.site.pill != null) ('Chains', data.chainIds.join(', ')),
        ],
      ),
    ];
  }

  List<Widget> _signInBody(BuildContext context, bool local, List<String> warnings) {
    final s = ZuniaSemanticsExt.of(context);
    final message = data.signIn!;
    return [
      if (data.site.name != null) ...[_SiteHeader(site: data.site), const SizedBox(height: 8)],
      ..._intro(
        context,
        headline: 'Sign in to ${message.domain}',
        sub: _chainName(message.chainId),
      ),
      const SizedBox(height: 12),
      Text(
        message.statement ?? 'Sign in with this account.',
        textAlign: TextAlign.center,
        style: zuniaSans(fontSize: 14.5, height: 1.5, color: s.fg),
      ),
      for (final extra in data.extras) ...[const SizedBox(height: 12), extra],
      if (local) _localNote(context),
      if (warnings.isNotEmpty) ...[const SizedBox(height: 12), ReviewWarnings(warnings: warnings)],
      const SizedBox(height: 14),
      _accountCard(
        context,
        extra: [
          if (message.expirationTime != null) ('Expires', _expiryLabel(message.expirationTime!)),
        ],
      ),
      if (data.signInText != null) ...[
        const SizedBox(height: 12),
        ReviewDisclosure(
          title: 'Show the signed message',
          child: RawTextBlock(text: data.signInText!, maxHeight: 180),
        ),
      ],
    ];
  }

  List<Widget> _messageBody(BuildContext context, bool local, List<String> warnings) {
    final s = ZuniaSemanticsExt.of(context);
    return [
      if (data.site.name != null) ...[_SiteHeader(site: data.site), const SizedBox(height: 12)],
      Text(
        'Sign a message',
        style: zuniaSans(fontSize: 20, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: s.fg),
      ),
      const SizedBox(height: 12),
      ReviewCard(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('MESSAGE', style: zuniaMono(fontSize: 9.5, letterSpacing: 1.4, color: s.fgDim)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: SelectableText(
                    data.messagePreview ?? '',
                    style: zuniaMono(fontSize: 12, height: 1.5, color: s.fg),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      for (final extra in data.extras) ...[const SizedBox(height: 12), extra],
      if (local) _localNote(context),
      if (warnings.isNotEmpty) ...[const SizedBox(height: 12), ReviewWarnings(warnings: warnings)],
      const SizedBox(height: 14),
      _accountCard(context, extra: [if (data.chainIds.isNotEmpty) ('Network', _chainName(data.chainIds.first))]),
    ];
  }

  List<Widget> _transactionBody(BuildContext context, bool local, List<String> warnings) {
    final s = ZuniaSemanticsExt.of(context);
    final review = data.review!;
    final messages = review.messages;
    final single = messages.length == 1 && !messages.single.unknown ? messages.single : null;
    final split = single == null ? null : _splitRecipient(single.summary);

    Widget resolvedLines(int index, double size) {
      final lines = index < review.resolved.length ? review.resolved[index] : const <String>[];
      if (lines.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(lines.join('\n'), style: zuniaSans(fontSize: size, color: s.fgMuted, height: 1.4)),
      );
    }

    return [
      if (data.site.name != null) ...[_SiteHeader(site: data.site), const SizedBox(height: 12)],
      if (split != null) ...[
        Text(
          split.lead,
          style: zuniaSans(fontSize: 21, fontWeight: FontWeight.w500, letterSpacing: -0.5, height: 1.2, color: s.fg),
        ),
        resolvedLines(0, 13),
        if (split.address != null) ...[
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'to ', style: zuniaSans(fontSize: 13.5, color: s.fgMuted)),
                TextSpan(text: split.address, style: zuniaMono(fontSize: 12.5, color: s.fg, height: 1.45)),
              ],
            ),
          ),
        ],
      ] else ...[
        Text(
          messages.isEmpty
              ? 'Sign transaction'
              : 'Approve ${messages.length} message${messages.length == 1 ? '' : 's'}',
          style: zuniaSans(fontSize: 19, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: s.fg),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < messages.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _MessageTile(index: i, message: messages[i], resolved: resolvedLines(i, 12)),
        ],
      ],
      if (local) _localNote(context),
      if (warnings.isNotEmpty) ...[const SizedBox(height: 12), ReviewWarnings(warnings: warnings)],
      const SizedBox(height: 14),
      _accountCard(
        context,
        fees: true,
        extra: [if (data.chainIds.isNotEmpty) ('Network', _chainName(data.chainIds.first))],
      ),
      const SizedBox(height: 12),
      ReviewDisclosure(
        title: 'Transaction details',
        hint: (review.memo ?? '').isNotEmpty ? 'account, memo' : 'account',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.signer != null) ReviewRow(label: 'Signs with', value: data.signer!, mono: true),
            const SizedBox(height: 8),
            ReviewRow(label: 'Chain', value: review.chainId, mono: true),
            if ((review.memo ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              ReviewRow(label: 'Memo', value: review.memo!),
            ],
          ],
        ),
      ),
      if (data.rawJson != null) ...[
        const SizedBox(height: 8),
        ReviewDisclosure(
          title: 'Raw transaction',
          hint: 'JSON',
          child: RawTextBlock(text: data.rawJson!),
        ),
      ],
    ];
  }

  List<Widget> _addChainBody(BuildContext context, List<String> warnings) {
    final s = ZuniaSemanticsExt.of(context);
    final draft = data.draft!;
    return [
      Text(
        'Add ${draft.chainName}?',
        style: zuniaSans(fontSize: 20, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: s.fg),
      ),
      const SizedBox(height: 4),
      Text('Suggested by ${data.site.host}', style: zuniaSans(fontSize: 13, color: s.fgMuted)),
      const SizedBox(height: 12),
      Text(data.effect, style: _bodyStyle(context)),
      if (warnings.isNotEmpty) ...[const SizedBox(height: 12), ReviewWarnings(warnings: warnings)],
      const SizedBox(height: 14),
      ReviewCard(
        children: [
          ReviewRow(label: 'Name', value: draft.chainName),
          ReviewRow(label: 'Chain ID', value: draft.chainId, mono: true),
          ReviewRow(
            label: 'Token',
            value: '${draft.coinDenom} (${draft.coinMinimalDenom}, ${draft.coinDecimals} decimals)',
          ),
          ReviewRow(label: 'Address prefix', value: draft.bech32Prefix, mono: true),
          ReviewRow(label: 'Coin type', value: '${draft.coinType}', mono: true),
          ReviewRow(label: 'RPC', value: draft.rpc ?? '', mono: true),
          ReviewRow(label: 'REST', value: draft.rest ?? '', mono: true),
        ],
      ),
    ];
  }

  TextStyle _bodyStyle(BuildContext context) =>
      zuniaSans(fontSize: 13, height: 1.5, color: ZuniaSemanticsExt.of(context).fgMuted);
}

class _Header extends StatelessWidget {
  const _Header({required this.data, required this.suspicious, required this.onExpired});

  final ReviewSheetData data;
  final bool suspicious;
  final VoidCallback onExpired;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final cupertino = ZuniaPlatform.isCupertino(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(18, cupertino ? 16 : 0, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    data.label.toUpperCase(),
                    style: zuniaMono(fontSize: 10.5, letterSpacing: 1.4, color: s.fgStrong),
                  ),
                ),
              ),
              if (data.expiresAt != null) ExpiryCountdown(expiresAt: data.expiresAt!, onExpired: onExpired),
              if (data.queued > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: s.line),
                  ),
                  child: Text('+${data.queued} queued', style: zuniaMono(fontSize: 10, color: s.fgDim)),
                ),
              ],
            ],
          ),
          if (data.kind == ReviewKind.transaction || data.kind == ReviewKind.message) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  suspicious ? Icons.gpp_maybe_rounded : Icons.language_rounded,
                  size: 18,
                  color: suspicious ? s.danger : s.fgMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    data.site.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: suspicious ? s.dangerFg : s.fg,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (data.kind != ReviewKind.connect && data.kind != ReviewKind.addChain) ...[
            const SizedBox(height: 8),
            Text(data.effect, style: zuniaSans(fontSize: 12, height: 1.45, color: s.fgDim)),
          ],
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.index, required this.message, required this.resolved});

  final int index;
  final ReviewMessage message;
  final Widget resolved;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: message.unknown ? s.dangerFill : s.glass,
        border: Border.all(color: message.unknown ? s.dangerLine : s.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: s.line)),
            child: Text('${index + 1}', style: zuniaMono(fontSize: 10, color: s.fgDim)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.summary,
                  style: zuniaSans(
                    fontSize: 13.5,
                    height: 1.4,
                    color: message.unknown ? s.dangerFg : s.fg,
                  ),
                ),
                resolved,
                if (message.type.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    message.type,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: zuniaMono(fontSize: 10, color: message.unknown ? s.danger : s.fgDim),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.busy,
    required this.error,
    required this.approveLabel,
    required this.canApprove,
    required this.onApprove,
    required this.onReject,
  });

  final bool busy;
  final String? error;
  final String approveLabel;
  final bool canApprove;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.surface,
        border: Border(top: BorderSide(color: s.line, width: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(error!, style: zuniaSans(fontSize: 12.5, height: 1.4, color: s.danger)),
              ),
              const SizedBox(height: 10),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final reject = ZuniaButton(
                  label: 'Reject',
                  variant: ZuniaButtonVariant.secondary,
                  size: ZuniaButtonSize.lg,
                  onPressed: busy ? null : onReject,
                );
                final approve = ZuniaButton(
                  label: busy ? 'Working…' : approveLabel,
                  size: ZuniaButtonSize.lg,
                  loading: busy,
                  onPressed: busy || !canApprove ? null : onApprove,
                );
                // Side by side when they fit; stacked on a narrow phone or
                // with large text, the action last, nearest the thumb.
                final stacked = constraints.maxWidth < 340 || MediaQuery.textScalerOf(context).scale(10) > 11.5;
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [reject, const SizedBox(height: 8), approve],
                  );
                }
                return Row(
                  children: [
                    Expanded(flex: 5, child: reject),
                    const SizedBox(width: 10),
                    Expanded(flex: 7, child: approve),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SiteHeader extends StatelessWidget {
  const _SiteHeader({required this.site});

  final ReviewSite site;

  String get _initials {
    final parts = (site.name ?? site.host).split(RegExp(r'[.\-_\s]')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'DA';
    if (parts.length == 1) {
      final first = parts.first;
      return (first.length >= 2 ? first.substring(0, 2) : first).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: s.glass2,
            border: Border.all(color: s.line),
          ),
          child: Text(_initials, style: zuniaMono(fontSize: 11, color: s.fg)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                site.name ?? site.host,
                overflow: TextOverflow.ellipsis,
                style: zuniaSans(fontSize: 15, fontWeight: FontWeight.w500, color: s.fg),
              ),
              const SizedBox(height: 3),
              Text(site.host, overflow: TextOverflow.ellipsis, style: zuniaMono(fontSize: 10.5, color: s.info)),
            ],
          ),
        ),
        if (site.pill != null) ...[
          const SizedBox(width: 8),
          ZuniaPill(site.pill!.$1, tone: site.pill!.$2),
        ],
      ],
    );
  }
}

/* -------------------------------------------------------------------------- *
 * The in-app browser
 * -------------------------------------------------------------------------- */

/// The prompt for one of the browser's queued requests. Answers through
/// [queue]; closing it rejects the request.
Future<void> showBrowserApprovalSheet(
  BuildContext context, {
  required ApprovalRequest request,
  required ApprovalQueue queue,
  required String accountName,
  String? accountAddress,
}) {
  final kind = switch (request.kind) {
    ApprovalKind.enable => ReviewKind.connect,
    ApprovalKind.signAmino || ApprovalKind.signDirect => ReviewKind.transaction,
    ApprovalKind.signArbitrary => request.signIn != null ? ReviewKind.signIn : ReviewKind.message,
    ApprovalKind.suggestChain => ReviewKind.addChain,
  };
  final data = ReviewSheetData(
    kind: kind,
    label: request.signIn != null ? 'Sign-in request' : request.kind.label,
    effect: approvalEffect(request.kind, signIn: request.signIn != null),
    site: ReviewSite(origin: request.origin),
    approveLabel: switch (kind) {
      ReviewKind.connect => 'Connect',
      ReviewKind.signIn => 'Sign in',
      ReviewKind.addChain => 'Add network',
      _ => 'Approve',
    },
    chainIds: request.chainIds,
    accountName: accountName,
    signer: request.signer ?? accountAddress,
    expiresAt: request.expiresAt,
    queued: queue.pending.length - 1,
    review: request.review,
    feeChoice: request.feeChoice,
    rawJson: request.json,
    messagePreview: request.messagePreview,
    signIn: request.signIn,
    signInText: request.signInText,
    draft: request.draft,
    warnings: request.warnings,
  );
  return showReviewSheet(
    context,
    data: data,
    stillPending: () => queue.isPending(request.id),
    onApprove: (tier) async {
      if (!queue.resolve(request.id, ApprovalAnswer.approve(feeTier: tier))) {
        throw const ProviderError(
          ProviderErrorCode.userRejected,
          'This request expired before it was answered. Nothing was signed.',
        );
      }
    },
    onReject: () async {
      queue.reject(request.id);
    },
  );
}

/* -------------------------------------------------------------------------- *
 * Zunia Connect (and WalletConnect, which feeds the same requests)
 * -------------------------------------------------------------------------- */

(String, ZuniaPillTone) _originPill(NativeDappIdentity dapp) => dapp.originMismatch
    ? ('Origin mismatch', ZuniaPillTone.danger)
    : dapp.verifiedOrigin != null
        ? ('Verified origin', ZuniaPillTone.accent)
        : ('Origin unknown', ZuniaPillTone.neutral);

ReviewSite _siteOf(NativeDappIdentity dapp) => ReviewSite(
      origin: dapp.verifiedOrigin ?? dapp.declaredOrigin ?? dapp.metadata.url,
      name: dapp.metadata.name,
      pill: _originPill(dapp),
    );

Widget? _originCallout(NativeDappIdentity dapp) {
  if (dapp.originMismatch) {
    final claimed = webHost(dapp.declaredOrigin!) ?? dapp.metadata.url;
    return ZuniaCallout(
      tone: ZuniaCalloutTone.danger,
      title: 'This site is not where it says',
      body: 'It calls itself $claimed, but the relay saw the request come '
          'from ${dapp.host}. Only continue if you opened ${dapp.host} '
          'yourself.',
    );
  }
  if (dapp.verifiedOrigin == null) {
    return const ZuniaCallout(
      tone: ZuniaCalloutTone.warning,
      title: 'Origin not confirmed',
      body: 'The request did not come from a web page, so the relay could not '
          'confirm which site this is. Sign-in requests from it will be '
          'refused.',
    );
  }
  return null;
}

List<String> _connectWarnings(NativeDappIdentity dapp) {
  final origin = dapp.verifiedOrigin ?? dapp.declaredOrigin;
  return origin == null ? const [] : assessOrigin(origin).warnings;
}

Future<void> showNativeConnectSheet(
  BuildContext context, {
  required NativeConnectRequest request,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final native = container.read(nativeConnectProvider);
  final wallet = container.read(walletProvider);
  final dapp = request.dapp;
  final callout = _originCallout(dapp);
  final description = dapp.metadata.description;
  final data = ReviewSheetData(
    kind: ReviewKind.connect,
    label: 'Connection request',
    effect: 'The site will see your addresses on the chains below and can ask you to '
        'sign. Nothing is signed without your approval here.',
    site: _siteOf(dapp),
    approveLabel: 'Connect',
    chainIds: request.chains,
    accountName: wallet.active?.name ?? 'Wallet',
    warnings: _connectWarnings(dapp),
    extras: [
      if (description != null) ReviewNote(description),
      ?callout,
      // WalletConnect has no code to compare.
      if (request.verificationCode.isNotEmpty) _VerificationCode(request.verificationCode),
    ],
    rows: [
      ('Session', request.transportLabel),
      ('Expires', request.expiryLabel),
      if (request.returnLabel != null) ('Then', request.returnLabel!),
    ],
  );
  return showReviewSheet(
    context,
    data: data,
    stillPending: () => native.isPending(request),
    onReject: () => native.rejectConnect(request),
    onApprove: (_) async {
      final phrase = container.read(phraseProvider);
      final account = container.read(walletProvider).active;
      if (phrase == null || account == null) {
        throw const ConnectException('LOCKED', 'Unlock the wallet first');
      }
      final accounts = connectAccountsFor(
        phrase: phrase,
        accountIndex: account.index,
        chainIds: request.chains,
        accountName: account.name,
      );
      if (accounts.isEmpty) {
        throw ConnectException('UNKNOWN_CHAIN', 'Zunia cannot sign on ${request.chains.join(', ')} yet');
      }
      await native.approveConnect(request, accounts: accounts, accountIndex: account.index);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Connected to ${dapp.host}')),
        );
      }
    },
  );
}

/// Signing context from the app's state: the chain, who was paid before,
/// blind signing, the NFT bridges this build knows.
Future<ReviewContext> reviewContextFor(ProviderContainer container, String chainId) async {
  final known = {
    ...await KnownRecipients.instance.load(),
    for (final entry in container.read(addressBookProvider)) entry.address,
  };
  final bridge = kIcs721Bridges[chainId];
  return ReviewContext(
    chain: ChainCatalog.isLoaded ? ChainCatalog.instance.find(chainId) : null,
    knownRecipients: known,
    blindSigning: container.read(signingSettingsProvider).blindSigning,
    nftBridges: {?bridge},
  );
}

Future<void> showNativeSignSheet(
  BuildContext context, {
  required NativeSignRequest request,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final native = container.read(nativeConnectProvider);
  final wallet = container.read(walletProvider);
  final dapp = request.dapp;

  // Decided before any prompt opens, as the extension does: a request Zunia
  // will not sign is refused with the reason, and the user is told.
  SignReview? review;
  String? rawJson;
  try {
    final reviewContext = await reviewContextFor(container, request.chainId);
    switch (request.kind) {
      case NativeSignKind.amino:
        review = reviewAminoSignDoc(
          expectedChainId: request.chainId,
          signDoc: request.aminoDoc!,
          context: reviewContext,
        );
        rawJson = previewJson(request.aminoDoc);
      case NativeSignKind.direct:
        review = reviewDirectSignBytes(
          expectedChainId: request.chainId,
          signBytes: request.directDoc!.signBytes,
          context: reviewContext,
        );
        rawJson = directPreviewJson(review);
      case NativeSignKind.message || NativeSignKind.signIn:
        if (!adr36PayloadIsSafe(request.data!)) {
          throw const ProviderError.invalid(
            'ADR-36 data looks like a transaction sign doc; refusing to sign',
          );
        }
    }
    if (review != null && review.requiresBlindSigning) throw blindSigningRefusal(review);
  } catch (error) {
    final refusal = asProviderError(error);
    try {
      await native.rejectSign(request, code: refusal.code, message: refusal.message);
    } catch (e) {
      debugPrint('refuse sign: $e');
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Zunia refused a request from ${dapp.host}: ${refusal.message}')),
      );
    }
    return;
  }
  if (!context.mounted) return;

  final kind = switch (request.kind) {
    NativeSignKind.amino || NativeSignKind.direct => ReviewKind.transaction,
    NativeSignKind.signIn => ReviewKind.signIn,
    NativeSignKind.message => ReviewKind.message,
  };
  final callout = _originCallout(dapp);
  final data = ReviewSheetData(
    kind: kind,
    label: switch (kind) {
      ReviewKind.signIn => 'Sign-in request',
      ReviewKind.message => 'Message signature',
      _ => 'Signature request',
    },
    effect: approvalEffect(
      kind == ReviewKind.transaction ? ApprovalKind.signAmino : ApprovalKind.signArbitrary,
      signIn: kind == ReviewKind.signIn,
    ),
    site: _siteOf(dapp),
    approveLabel: kind == ReviewKind.signIn ? 'Sign in' : 'Sign',
    chainIds: [request.chainId],
    accountName: wallet.active?.name,
    signer: request.signer,
    review: review,
    rawJson: rawJson,
    messagePreview: request.data == null ? null : previewText(request.data!),
    signIn: request.signIn,
    signInText: request.text,
    warnings: [..._connectWarnings(dapp), ...?review?.warnings],
    extras: [?callout],
    rows: [
      if (request.returnLabel != null) ('Then', request.returnLabel!),
    ],
  );

  final recipients = [for (final m in review?.messages ?? const <ReviewMessage>[]) ?m.recipient];
  await showReviewSheet(
    context,
    data: data,
    stillPending: () => native.isPending(request),
    onReject: () => native.rejectSign(request),
    onApprove: (_) async {
      final phrase = container.read(phraseProvider);
      if (phrase == null) throw const ConnectException('LOCKED', 'Unlock the wallet first');
      final Map<String, Object?> result;
      try {
        result = signNativeRequest(request, phrase: phrase);
      } on ConnectException catch (e) {
        // This request cannot be signed as asked: tell the site why.
        await native.rejectSign(request, code: e.code, message: e.message);
        rethrow;
      }
      await native.approveSign(request, result);
      await KnownRecipients.instance.rememberAll(recipients);
    },
  );
}

class _VerificationCode extends StatelessWidget {
  const _VerificationCode(this.code);

  final String code;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: s.surfaceRaisedGradient,
      ),
      child: Column(
        children: [
          Text(
            '${code.substring(0, 3)} ${code.substring(3)}',
            semanticsLabel: code.split('').join(' '),
            style: zuniaMono(fontSize: 28, letterSpacing: 4, color: s.fg),
          ),
          const SizedBox(height: 8),
          Text(
            'Check this code matches the site. If it does not, reject.',
            textAlign: TextAlign.center,
            style: zuniaSans(fontSize: 12, height: 1.45, color: s.fgMuted),
          ),
        ],
      ),
    );
  }
}
