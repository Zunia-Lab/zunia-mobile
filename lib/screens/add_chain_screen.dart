import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/chains/chain_draft.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/state/custom_chains.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/widgets/chain_avatar.dart';
import 'package:zunia_tokens/zunia_tokens.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum _Mode { registry, manual }

/// What the node at [rest] says its chain id is, so a typo in the chain ID or
/// a REST URL for the wrong network shows up before anything is saved.
/// Asked only when the user taps Test, never in the background.
Future<String?> nodeNetworkOf(String rest, {LcdFetch? fetch}) async {
  final base = rest.trim().replaceAll(RegExp(r'/+$'), '');
  final client = HttpLcdClient(
    chainId: 'custom',
    endpoints: [base],
    retries: 0,
    fetch: fetch,
  );
  final body = await client.getJson('/cosmos/base/tendermint/v1beta1/node_info');
  final info = asMap(asMap(body)['default_node_info']);
  final network = asString(info['network']);
  return network.isEmpty ? null : network;
}

/// Two ways to add a network: switch on one the bundled registry already
/// knows, or type one in. A typed chain is checked here (https endpoints,
/// prefix, denom, decimals, no registry chain id) and stored on this device.
class AddChainScreen extends ConsumerStatefulWidget {
  const AddChainScreen({super.key});

  @override
  ConsumerState<AddChainScreen> createState() => _AddChainScreenState();
}

class _AddChainScreenState extends ConsumerState<AddChainScreen> {
  _Mode _mode = _Mode.registry;
  final _search = TextEditingController();
  String _query = '';

  final _name = TextEditingController();
  final _chainId = TextEditingController();
  final _rpc = TextEditingController();
  final _rest = TextEditingController();
  final _prefix = TextEditingController();
  final _coinType = TextEditingController(text: '118');
  final _symbol = TextEditingController();
  final _denom = TextEditingController();
  final _decimals = TextEditingController(text: '6');
  final _gasPrice = TextEditingController(text: '0.025');
  bool _testnet = false;

  String? _error;
  String? _tested;
  bool _testing = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _search,
      _name,
      _chainId,
      _rpc,
      _rest,
      _prefix,
      _coinType,
      _symbol,
      _denom,
      _decimals,
      _gasPrice,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  CustomChainDraft _draft() {
    final denom = _denom.text.trim();
    final symbol = _symbol.text.trim().isEmpty
        ? denom.replaceFirst(RegExp('^u'), '').toUpperCase()
        : _symbol.text.trim().toUpperCase();
    return CustomChainDraft(
      chainName: _name.text,
      chainId: _chainId.text,
      rpc: _rpc.text,
      rest: _rest.text,
      bech32Prefix: _prefix.text.trim().toLowerCase(),
      coinType: int.tryParse(_coinType.text.trim()) ?? -1,
      coinDenom: symbol,
      coinMinimalDenom: denom,
      coinDecimals: int.tryParse(_decimals.text.trim()) ?? -1,
      gasPrice: double.tryParse(_gasPrice.text.trim()) ?? -1,
      testnet: _testnet,
    );
  }

  /// The first problem with the form, or null when it would save.
  String? _problem() {
    try {
      validateCustomChainDraft(_draft(), isRegistryChainId: registryHasChainId);
      return null;
    } on ChainDraftError catch (e) {
      return e.message;
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _tested = null;
    });
    String result;
    try {
      final rest = cleanEndpoint(_rest.text, 'REST');
      final network = await nodeNetworkOf(rest);
      final typed = _chainId.text.trim();
      if (network == null) {
        result = 'The node answered but did not name its chain.';
      } else if (typed.isEmpty) {
        result = 'The node runs $network.';
        if (mounted && _chainId.text.trim().isEmpty) _chainId.text = network;
      } else if (network == typed) {
        result = 'The node runs $network, as entered.';
      } else {
        result = 'The node runs $network, not $typed. Check the chain ID and '
            'the REST URL.';
      }
    } on ChainDraftError catch (e) {
      result = e.message;
    } on Object {
      result = 'The REST endpoint did not answer.';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _tested = result;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry =
          await ref.read(customChainsProvider.notifier).addDraft(_draft());
      final enabled = ref.read(walletProvider).enabledChainIds;
      if (!enabled.contains(entry.chainId)) {
        await ref
            .read(walletProvider.notifier)
            .setEnabledChains([...enabled, entry.chainId]);
      }
      unawaited(ZuniaHaptics.success());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.chainName} added and enabled')),
      );
      Navigator.of(context).maybePop();
    } on ChainDraftError catch (e) {
      unawaited(ZuniaHaptics.error());
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final enabled = ref.watch(walletProvider).enabledChainIds;
    final custom = ref.watch(customChainsProvider);
    final problem = _mode == _Mode.manual ? _problem() : null;
    final touched = _chainId.text.isNotEmpty ||
        _rest.text.isNotEmpty ||
        _rpc.text.isNotEmpty ||
        _name.text.isNotEmpty;

    return Scaffold(
      backgroundColor: s.screenMid,
      body: SafeArea(
        bottom: false,
        child: ZuniaScreenScaffold(
          title: 'Add network',
          onBack: () => Navigator.of(context).maybePop(),
          footer: _mode == _Mode.registry
              ? null
              : Row(
                  children: [
                    Expanded(
                      child: ZuniaButton(
                        label: 'Test',
                        variant: ZuniaButtonVariant.secondary,
                        loading: _testing,
                        onPressed: _rest.text.trim().isEmpty || _testing
                            ? null
                            : _test,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ZuniaButton(
                        label: 'Save',
                        loading: _saving,
                        onPressed: problem != null || _saving ? null : _save,
                      ),
                    ),
                  ],
                ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              ZuniaSegmented<_Mode>(
                value: _mode,
                onChanged: (m) => setState(() => _mode = m),
                options: const {
                  _Mode.registry: 'Registry',
                  _Mode.manual: 'Manual',
                },
              ),
              const SizedBox(height: 14),
              if (_mode == _Mode.registry)
                ..._registry(s, enabled)
              else
                ..._manual(s, custom, problem, touched),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _registry(ZuniaSemantic s, List<String> enabled) {
    final rows = ChainCatalog.isLoaded
        ? ChainCatalog.instance
            .sorted(ChainCatalog.instance.registryOnly)
            .where((c) => c.matches(_query))
            .take(40)
            .toList()
        : const <ChainEntry>[];
    return [
      ZuniaSearchField(
        controller: _search,
        hintText: 'Search name, chain ID or token',
        onChanged: (v) => setState(() => _query = v),
      ),
      const SizedBox(height: 8),
      for (final chain in rows)
        Semantics(
          toggled: enabled.contains(chain.chainId),
          label: chain.chainName,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: ChainAvatar(chain: chain, size: 32),
            title: Text(
              chain.chainName,
              overflow: TextOverflow.ellipsis,
              style: zuniaSans(fontSize: 15, color: s.fg),
            ),
            subtitle: Text(
              chain.chainId,
              overflow: TextOverflow.ellipsis,
              style: zuniaMono(fontSize: 11.5, color: s.fgDim),
            ),
            trailing: ZuniaSwitch(
              value: enabled.contains(chain.chainId),
              onChanged: (on) {
                final next = on
                    ? [...enabled, chain.chainId]
                    : enabled.where((id) => id != chain.chainId).toList();
                if (next.isEmpty) return;
                unawaited(
                  ref.read(walletProvider.notifier).setEnabledChains(next),
                );
              },
            ),
          ),
        ),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing in the registry matches “${_query.trim()}”. Switch to '
            'Manual to add it yourself.',
            textAlign: TextAlign.center,
            style: zuniaSans(fontSize: 13.5, color: s.fgMuted),
          ),
        ),
    ];
  }

  List<Widget> _manual(
    ZuniaSemantic s,
    List<ChainEntry> custom,
    String? problem,
    bool touched,
  ) {
    void changed(String _) => setState(() {
          _error = null;
          _tested = null;
        });
    Widget field(
      TextEditingController c,
      String label, {
      String? hint,
      TextInputType? keyboard,
    }) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ZuniaInput(
            controller: c,
            label: label,
            hint: hint,
            keyboardType: keyboard,
            onChanged: changed,
          ),
        );
    return [
      const ZuniaCallout(
        tone: ZuniaCalloutTone.warning,
        title: 'Not in the registry',
        body: 'A custom network is only as trustworthy as its endpoints. Add '
            'hosts you run or know, never ones a website handed you. A wrong '
            'coin type or prefix derives a different address.',
      ),
      const SizedBox(height: 14),
      field(_name, 'Name', hint: 'Safrochain Devnet'),
      field(_chainId, 'Chain ID', hint: 'safro-devnet-2'),
      field(_rpc, 'RPC', hint: 'https://rpc.example.com', keyboard: TextInputType.url),
      field(_rest, 'REST', hint: 'https://api.example.com', keyboard: TextInputType.url),
      if (_tested != null) ...[
        Text(_tested!, style: zuniaSans(fontSize: 13, color: s.fgMuted)),
        const SizedBox(height: 12),
      ],
      Row(
        children: [
          Expanded(child: field(_prefix, 'Address prefix', hint: 'cosmos')),
          const SizedBox(width: 10),
          Expanded(
            child: field(_coinType, 'Coin type', keyboard: TextInputType.number),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(child: field(_denom, 'Base denom', hint: 'uatom')),
          const SizedBox(width: 10),
          Expanded(child: field(_symbol, 'Symbol', hint: 'ATOM')),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: field(_decimals, 'Decimals', keyboard: TextInputType.number),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: field(
              _gasPrice,
              'Gas price',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
            ),
          ),
        ],
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _testnet,
        onChanged: (v) => setState(() => _testnet = v),
        title: Text('Testnet', style: zuniaSans(fontSize: 15, color: s.fg)),
        subtitle: Text(
          'Listed under Testnets in Networks',
          style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
        ),
      ),
      if (_error != null || (touched && problem != null)) ...[
        const SizedBox(height: 8),
        ZuniaCallout(
          tone: ZuniaCalloutTone.danger,
          body: _error ?? problem!,
        ),
      ],
      if (custom.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text(
          'YOUR NETWORKS',
          style: zuniaMono(fontSize: 10.5, letterSpacing: 1.4, color: s.fgDim),
        ),
        const SizedBox(height: 4),
        for (final chain in custom)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: ChainAvatar(chain: chain, size: 30),
            title: Text(chain.chainName, style: zuniaSans(fontSize: 15, color: s.fg)),
            subtitle: Text(
              chain.chainId,
              style: zuniaMono(fontSize: 11.5, color: s.fgDim),
            ),
            trailing: IconButton(
              tooltip: 'Remove ${chain.chainName}',
              icon: Icon(Icons.delete_outline, color: s.fgMuted),
              onPressed: () async {
                final ok = await showZuniaConfirm(
                  context,
                  title: 'Remove ${chain.chainName}?',
                  message: 'Funds on it stay on the chain; add it again to '
                      'see them.',
                  confirmLabel: 'Remove',
                  destructive: true,
                );
                if (!ok) return;
                final enabled = ref.read(walletProvider).enabledChainIds;
                if (enabled.contains(chain.chainId)) {
                  final rest =
                      enabled.where((id) => id != chain.chainId).toList();
                  await ref.read(walletProvider.notifier).setEnabledChains(rest);
                }
                await ref.read(customChainsProvider.notifier).remove(chain.chainId);
              },
            ),
          ),
      ],
    ];
  }
}
