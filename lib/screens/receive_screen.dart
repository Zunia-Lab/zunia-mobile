import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_picker.dart';
import 'package:zunia_mobile/widgets/qr_code.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Receive: the derived address for one chain, as text and as a QR code.
class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, this.chainId});

  final String? chainId;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  late String? _chainId = widget.chainId;

  Future<void> _copy(BuildContext context, String address) async {
    await ClipboardGuard.copy(address);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final accounts = ref.watch(chainAccountsProvider);

    if (accounts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ZuniaScreenScaffold(
            title: 'Receive',
            onBack: () => Navigator.of(context).pop(),
            body: const ZuniaEmptyState(
              title: 'No networks enabled',
              description:
                  'Enable a chain to derive a receiving address for it.',
            ),
          ),
        ),
      );
    }

    final chainId = accounts.any((a) => a.chain.chainId == _chainId)
        ? _chainId!
        : accounts.first.chain.chainId;
    final account = accounts.firstWhere((a) => a.chain.chainId == chainId);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Receive',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ChainPicker(
                value: chainId,
                onChanged: (v) => setState(() => _chainId = v),
              ),
              const SizedBox(height: 28),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F5F7),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: QrCode(data: account.address, size: 168),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SelectableText(
                account.address,
                textAlign: TextAlign.center,
                style: zuniaMono(
                  fontSize: 12,
                  height: 1.6,
                  color: s.fgMuted,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ActionPill(
                    label: 'Copy',
                    onTap: () => _copy(context, account.address),
                  ),
                  const SizedBox(width: 9),
                  _ActionPill(
                    label: 'Share',
                    onTap: () => _copy(context, account.address),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Send only ${account.chain.coinDenom} on '
                    '${account.chain.chainName}',
                body:
                    'Assets sent from another network without a bridge do not '
                    'arrive and cannot be recovered.',
              ),
            ],
          ),
          footer: ZuniaButton(
            label: 'Copy address',
            size: ZuniaButtonSize.lg,
            variant: ZuniaButtonVariant.secondary,
            leading: const Icon(Icons.copy_outlined),
            onPressed: () => _copy(context, account.address),
          ),
        ),
      ),
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Material(
      color: s.glass2,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Text(
            label,
            style: zuniaMono(fontSize: 11.5, color: s.fgMuted),
          ),
        ),
      ),
    );
  }
}
