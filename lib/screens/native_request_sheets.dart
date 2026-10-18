import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/pair_device.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Routes a scanned code: pairing codes (Zunia Connect, WalletConnect), wake
/// links, sites and addresses. See `routeScannedCode` in pair_device.dart.
Future<void> handleScannedCode(
  BuildContext context,
  WidgetRef ref,
  String code,
) =>
    routeScannedCode(context, ref, code);

String _messageOf(Object error) => error is ConnectException
    ? error.message
    : 'Something went wrong. Ask the site for a new code.';

Future<void> showNativeConnectSheet(
  BuildContext context, {
  required NativeConnectRequest request,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NativeConnectSheet(request: request),
    );

Future<void> showNativeSignSheet(
  BuildContext context, {
  required NativeSignRequest request,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NativeSignSheet(request: request),
    );

class _NativeConnectSheet extends ConsumerStatefulWidget {
  const _NativeConnectSheet({required this.request});

  final NativeConnectRequest request;

  @override
  ConsumerState<_NativeConnectSheet> createState() => _NativeConnectSheetState();
}

class _NativeConnectSheetState extends ConsumerState<_NativeConnectSheet> {
  bool _busy = false;
  String? _error;

  NativeConnectRequest get request => widget.request;

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref.read(nativeConnectProvider).rejectConnect(request);
    } catch (e) {
      debugPrint('reject connect: $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final phrase = ref.read(phraseProvider);
      final account = ref.read(walletProvider).active;
      if (phrase == null || account == null) {
        throw const ConnectException('LOCKED', 'Unlock the wallet first');
      }
      // Key derivation blocks for a moment; let the button show it first.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final accounts = connectAccountsFor(
        phrase: phrase,
        accountIndex: account.index,
        chainIds: request.chains,
        accountName: account.name,
      );
      if (accounts.isEmpty) {
        throw ConnectException(
          'UNKNOWN_CHAIN',
          'Zunia cannot sign on ${request.chains.join(', ')} yet',
        );
      }
      await ref.read(nativeConnectProvider).approveConnect(
            request,
            accounts: accounts,
            accountIndex: account.index,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Connected to ${request.dapp.host}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageOf(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final dapp = request.dapp;
    final description = dapp.metadata.description;
    final callout = _originCallout(dapp);

    return _SheetFrame(
      children: [
        _SiteHeader(dapp: dapp),
        if (description != null) ...[
          const SizedBox(height: 12),
          Text(
            description,
            style: zuniaSans(fontSize: 12.5, height: 1.45, color: s.fgMuted),
          ),
        ],
        if (callout != null) ...[const SizedBox(height: 14), callout],
        const SizedBox(height: 16),
        // WalletConnect has no code to compare.
        if (request.verificationCode.isNotEmpty) ...[
          _VerificationCode(request.verificationCode),
          const SizedBox(height: 16),
        ],
        Text(
          'The site will see your addresses on the chains below and can ask '
          'you to sign. Nothing is signed without your approval here.',
          style: zuniaSans(fontSize: 13, height: 1.6, color: s.fgMuted),
        ),
        const SizedBox(height: 14),
        _Rows(
          rows: [
            ('Wallet', wallet.active?.name ?? 'Wallet'),
            ('Chains', request.chains.join(', ')),
            ('Session', request.transportLabel),
            ('Expires', request.expiryLabel),
            if (request.returnLabel != null) ('Then', request.returnLabel!),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: zuniaSans(fontSize: 12, color: s.danger, height: 1.4),
          ),
        ],
        const SizedBox(height: 18),
        _Actions(
          busy: _busy,
          approveLabel: 'Connect',
          busyLabel: 'Connecting…',
          onReject: _reject,
          onApprove: _approve,
        ),
      ],
    );
  }
}

class _NativeSignSheet extends ConsumerStatefulWidget {
  const _NativeSignSheet({required this.request});

  final NativeSignRequest request;

  @override
  ConsumerState<_NativeSignSheet> createState() => _NativeSignSheetState();
}

class _NativeSignSheetState extends ConsumerState<_NativeSignSheet> {
  bool _busy = false;
  String? _error;

  NativeSignRequest get request => widget.request;

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref.read(nativeConnectProvider).rejectSign(request);
    } catch (e) {
      debugPrint('reject sign: $e');
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final native = ref.read(nativeConnectProvider);
    try {
      final phrase = ref.read(phraseProvider);
      if (phrase == null) {
        throw const ConnectException('LOCKED', 'Unlock the wallet first');
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final Map<String, Object?> result;
      try {
        result = signNativeRequest(request, phrase: phrase);
      } on ConnectException catch (e) {
        // This request cannot be signed as asked: tell the site why.
        await native.rejectSign(request, code: e.code, message: e.message);
        rethrow;
      }
      await native.approveSign(request, result);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      if (!native.isPending(request)) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(SnackBar(content: Text(_messageOf(e))));
        return;
      }
      setState(() {
        _busy = false;
        _error = _messageOf(e);
      });
    }
  }

  String get _title => switch (request.kind) {
        NativeSignKind.signIn => 'Sign in to ${request.signIn!.domain}',
        NativeSignKind.message => 'Sign a message',
        NativeSignKind.amino || NativeSignKind.direct => 'Approve a transaction',
      };

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final callout = _originCallout(request.dapp);

    return _SheetFrame(
      children: [
        Text(
          _title,
          style: zuniaSans(fontSize: 17, fontWeight: FontWeight.w500, color: s.fg),
        ),
        const SizedBox(height: 12),
        _SiteHeader(dapp: request.dapp, compact: true),
        if (callout != null) ...[const SizedBox(height: 14), callout],
        const SizedBox(height: 14),
        ..._body(context, wallet.active?.name),
        if (request.returnLabel != null) ...[
          const SizedBox(height: 12),
          Text(
            'Then: ${request.returnLabel}',
            style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: zuniaSans(fontSize: 12, color: s.danger, height: 1.4),
          ),
        ],
        const SizedBox(height: 18),
        _Actions(
          busy: _busy,
          approveLabel: request.kind == NativeSignKind.signIn ? 'Sign in' : 'Sign',
          busyLabel: 'Signing…',
          onReject: _reject,
          onApprove: _approve,
        ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, String? accountName) {
    final s = ZuniaSemanticsExt.of(context);
    final account = accountName == null
        ? truncateAddress(request.signer)
        : '$accountName · ${truncateAddress(request.signer)}';
    Widget note(String text) => Text(
          text,
          style: zuniaSans(fontSize: 12.5, height: 1.5, color: s.fgMuted),
        );

    switch (request.kind) {
      case NativeSignKind.signIn:
        final message = request.signIn!;
        return [
          if (message.statement != null) ...[
            Text(
              message.statement!,
              style: zuniaSans(fontSize: 14, height: 1.5, color: s.fg),
            ),
            const SizedBox(height: 12),
          ],
          _Rows(
            rows: [
              ('Account', account),
              ('Chain', message.chainId),
              ('Site', message.uri),
              ('Issued', message.issuedAt),
              ('Expires', message.expirationTime ?? 'No expiry'),
            ],
          ),
          const SizedBox(height: 12),
          note(
            'Signing in proves you own this account. It does not move funds '
            'or approve any transaction.',
          ),
        ];
      case NativeSignKind.message:
        final text = request.text;
        final data = request.data!;
        return [
          _Rows(rows: [('Account', account), ('Chain', request.chainId)]),
          const SizedBox(height: 12),
          _Preview(
            text ?? 'Binary data, ${data.length} bytes\n${base64Encode(data)}',
          ),
          const SizedBox(height: 12),
          note(
            'Signing a message does not move funds. Only sign text you '
            'understand.',
          ),
        ];
      case NativeSignKind.amino || NativeSignKind.direct:
        final summary = request.kind == NativeSignKind.amino
            ? TxSummary.fromAmino(request.aminoDoc)
            : TxSummary.fromDirect(request.directDoc!);
        String coins(List<CoinAmount> amounts) => amounts.isEmpty
            ? 'None'
            : amounts.map((c) => '${c.amount} ${c.denom}').join(', ');
        return [
          _Rows(
            rows: [
              ('Account', account),
              ('Chain', request.chainId),
              if (summary != null) ...[
                (
                  summary.messages.length == 1 ? 'Action' : 'Actions',
                  summary.messages.isEmpty
                      ? 'None'
                      : summary.messages.map(_shortType).join(', '),
                ),
                ('Fee', coins(summary.fee)),
                if (summary.gas != null) ('Gas', summary.gas!),
                if (summary.memo.isNotEmpty) ('Memo', summary.memo),
              ],
            ],
          ),
          if (summary == null) ...[
            const SizedBox(height: 12),
            const ZuniaCallout(
              tone: ZuniaCalloutTone.warning,
              title: 'Unreadable transaction',
              body: 'Zunia could not read this transaction. Only approve it '
                  'if you trust the site.',
            ),
          ],
          if (request.aminoDoc != null) ...[
            const SizedBox(height: 12),
            _Preview(const JsonEncoder.withIndent('  ').convert(request.aminoDoc)),
          ],
        ];
    }
  }

  static String _shortType(String type) => type.split(RegExp(r'[./]')).last;
}

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

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: s.sheetGradient,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: s.lineStrong)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.86,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: s.lineStrong,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SiteHeader extends StatelessWidget {
  const _SiteHeader({required this.dapp, this.compact = false});

  final NativeDappIdentity dapp;
  final bool compact;

  String get _initials {
    final parts = dapp.metadata.name
        .split(RegExp(r'[.\-_\s]'))
        .where((p) => p.isNotEmpty)
        .toList();
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
    final size = compact ? 34.0 : 42.0;
    final (label, tone) = dapp.originMismatch
        ? ('Origin mismatch', ZuniaPillTone.danger)
        : dapp.verifiedOrigin != null
            ? ('Verified origin', ZuniaPillTone.accent)
            : ('Origin unknown', ZuniaPillTone.neutral);
    return Row(
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.31),
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
                dapp.metadata.name,
                overflow: TextOverflow.ellipsis,
                style: zuniaSans(
                  fontSize: compact ? 13.5 : 15,
                  fontWeight: FontWeight.w500,
                  color: s.fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                dapp.host,
                overflow: TextOverflow.ellipsis,
                style: zuniaMono(fontSize: 10.5, color: s.info),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ZuniaPill(label, tone: tone),
      ],
    );
  }
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

class _Rows extends StatelessWidget {
  const _Rows({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: s.surfaceRaisedGradient,
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 11),
            ZuniaKeyValueRow(label: rows[i].$1, value: rows[i].$2),
          ],
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: s.glass,
        border: Border.all(color: s.line),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: zuniaMono(fontSize: 10.5, color: s.fgMuted, height: 1.45),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.approveLabel,
    required this.busyLabel,
    required this.onReject,
    required this.onApprove,
  });

  final bool busy;
  final String approveLabel;
  final String busyLabel;
  final VoidCallback onReject;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ZuniaButton(
            label: 'Reject',
            variant: ZuniaButtonVariant.secondary,
            size: ZuniaButtonSize.lg,
            onPressed: busy ? null : onReject,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ZuniaButton(
            label: busy ? busyLabel : approveLabel,
            size: ZuniaButtonSize.lg,
            onPressed: busy ? null : onApprove,
          ),
        ),
      ],
    );
  }
}
