import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// WalletConnect-style approval sheet shown after a QR or pasted URI.
///
/// Pairing is only attempted when a project id is configured. Otherwise the
/// sheet still decodes the URI so the user can see what was scanned.
Future<void> showDappConnectSheet(
  BuildContext context, {
  required String uri,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DappConnectSheet(uri: uri),
  );
}

class _DappConnectSheet extends ConsumerWidget {
  const _DappConnectSheet({required this.uri});

  final String uri;

  bool get _looksLikeWc =>
      uri.startsWith('wc:') || uri.contains('relay-protocol');

  String get _host {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return uri;
    if (parsed.host.isNotEmpty) return parsed.host;
    if (uri.startsWith('wc:')) return 'WalletConnect pairing';
    return uri;
  }

  String get _initials {
    final host = _host;
    final parts = host.split(RegExp(r'[.\-_]')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return 'WC';
    final first = parts.first;
    if (parts.length == 1) {
      return first.length >= 2
          ? first.substring(0, 2).toUpperCase()
          : first.toUpperCase();
    }
    return (first[0] + parts.elementAt(1)[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ZuniaSemanticsExt.of(context);
    final wallet = ref.watch(walletProvider);
    final chains = ref.watch(chainAccountsProvider);

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
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      color: s.glass2,
                      border: Border.all(color: s.line),
                    ),
                    child: Text(
                      _initials,
                      style: zuniaMono(fontSize: 11, color: s.fg),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _looksLikeWc && _host.contains(' ')
                              ? 'WalletConnect'
                              : _host.split('.').first.capitalizeWords(),
                          overflow: TextOverflow.ellipsis,
                          style: zuniaSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: s.fg,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _looksLikeWc
                              ? '$_host · pairing'
                              : '$_host · scanned',
                          overflow: TextOverflow.ellipsis,
                          style: zuniaMono(fontSize: 10.5, color: s.info),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                _looksLikeWc
                    ? 'This site wants to connect to your wallet. It can see '
                        'your addresses and ask you to sign. It cannot move '
                        'funds without a signature.'
                    : 'Scanned value. Approve only if you trust the source.',
                style: zuniaSans(
                  fontSize: 13,
                  height: 1.6,
                  color: s.fgMuted,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: s.surfaceRaisedGradient,
                ),
                child: Column(
                  children: [
                    ZuniaKeyValueRow(
                      label: 'Wallet',
                      value: wallet.active?.name ?? 'Wallet',
                    ),
                    const SizedBox(height: 11),
                    ZuniaKeyValueRow(
                      label: 'Chains',
                      value: chains.isEmpty
                          ? 'none enabled'
                          : chains
                              .take(2)
                              .map((a) => a.chain.chainId)
                              .join(', '),
                    ),
                    const SizedBox(height: 11),
                    ZuniaKeyValueRow(
                      label: 'Session',
                      value:
                          _looksLikeWc ? 'WalletConnect v2' : 'raw payload',
                    ),
                    const SizedBox(height: 11),
                    const ZuniaKeyValueRow(
                      label: 'Expires',
                      value: '7 days',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: s.glass,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.info,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'No WalletConnect project id is configured, so Connect '
                        'will not open a session. The URI stays on this device.',
                        style: zuniaSans(
                          fontSize: 11,
                          height: 1.45,
                          color: s.fgMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ZuniaButton(
                      label: 'Reject',
                      variant: ZuniaButtonVariant.secondary,
                      size: ZuniaButtonSize.lg,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZuniaButton(
                      label: 'Connect',
                      size: ZuniaButtonSize.lg,
                      onPressed: () {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'WalletConnect is not configured. Nothing was shared.',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  String capitalizeWords() {
    if (isEmpty) return this;
    return split(RegExp(r'[\s.\-_]'))
        .where((p) => p.isNotEmpty)
        .map((p) => '${p[0].toUpperCase()}${p.substring(1)}')
        .join(' ');
  }
}
