import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Add a chain the registry does not carry. Everything entered here is stored
/// locally and used exactly like a registry row.
class AddChainScreen extends ConsumerStatefulWidget {
  const AddChainScreen({super.key});

  @override
  ConsumerState<AddChainScreen> createState() => _AddChainScreenState();
}

class _AddChainScreenState extends ConsumerState<AddChainScreen> {
  final _name = TextEditingController();
  final _chainId = TextEditingController();
  final _prefix = TextEditingController();
  final _denom = TextEditingController();
  final _minimalDenom = TextEditingController();
  final _decimals = TextEditingController(text: '6');
  final _coinType = TextEditingController(text: '118');
  final _rest = TextEditingController();
  final _rpc = TextEditingController();

  String _mode = 'manual';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _chainId,
      _prefix,
      _denom,
      _minimalDenom,
      _decimals,
      _coinType,
      _rest,
      _rpc,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final chainId = _chainId.text.trim();
    final prefix = _prefix.text.trim();
    if (chainId.isEmpty || prefix.isEmpty) {
      setState(() => _error = 'Chain ID and bech32 prefix are required');
      return;
    }
    if (ChainCatalog.isLoaded && ChainCatalog.instance.find(chainId) != null) {
      setState(() => _error = '$chainId already exists');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final decimals = int.tryParse(_decimals.text.trim()) ?? 6;
    final entry = ChainEntry(
      chainId: chainId,
      chainName: _name.text.trim().isEmpty ? chainId : _name.text.trim(),
      bech32Prefix: prefix,
      coinType: int.tryParse(_coinType.text.trim()) ?? 118,
      network: 'mainnet',
      coinDenom: _denom.text.trim(),
      coinMinimalDenom: _minimalDenom.text.trim(),
      coinDecimals: decimals,
      feeDenom: _denom.text.trim(),
      feeMinimalDenom: _minimalDenom.text.trim(),
      feeDecimals: decimals,
      rest: _rest.text.trim().isEmpty ? null : _rest.text.trim(),
      rpc: _rpc.text.trim().isEmpty ? null : _rpc.text.trim(),
    );

    await ref.read(customChainsProvider.notifier).add(entry);
    await ref.read(walletProvider.notifier).toggleChain(chainId);
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: 'Add network',
          onBack: () => Navigator.of(context).pop(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            children: [
              ZuniaSegmented<String>(
                value: _mode,
                onChanged: (v) {
                  if (v == 'registry') {
                    Navigator.of(context).pop();
                    return;
                  }
                  setState(() => _mode = v);
                },
                options: const {
                  'registry': 'Registry',
                  'manual': 'Manual',
                },
              ),
              const SizedBox(height: 16),
              ZuniaInput(
                controller: _name,
                label: 'Chain name',
                hint: 'Safrochain Devnet',
              ),
              const SizedBox(height: 12),
              ZuniaInput(
                controller: _chainId,
                label: 'Chain ID',
                hint: 'safro-devnet-2',
              ),
              const SizedBox(height: 12),
              ZuniaInput(
                controller: _rpc,
                label: 'RPC endpoint',
                hint: 'https://rpc.devnet.example',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ZuniaInput(
                      controller: _prefix,
                      label: 'Prefix',
                      hint: 'safro',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZuniaInput(
                      controller: _coinType,
                      label: 'Coin type',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ZuniaInput(
                      controller: _minimalDenom,
                      label: 'Denom',
                      hint: 'usaf',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZuniaInput(
                      controller: _decimals,
                      label: 'Decimals',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ZuniaInput(
                controller: _denom,
                label: 'Symbol',
                hint: 'SAF',
              ),
              const SizedBox(height: 12),
              ZuniaInput(
                controller: _rest,
                label: 'REST endpoint',
                hint: 'https://api.devnet.example',
              ),
              const SizedBox(height: 14),
              const ZuniaCallout(
                tone: ZuniaCalloutTone.warning,
                title: 'Not in the chain registry',
                body:
                    'Only add endpoints you trust. A wrong coin type or prefix '
                    'derives a different address, and funds sent there cannot '
                    'be recovered from this wallet.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ZuniaCallout(body: _error!, tone: ZuniaCalloutTone.danger),
              ],
            ],
          ),
          footer: Row(
            children: [
              const Expanded(
                child: ZuniaButton(
                  label: 'Test',
                  variant: ZuniaButtonVariant.secondary,
                  onPressed: null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ZuniaButton(
                  label: 'Save chain',
                  loading: _busy,
                  onPressed: _busy ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
