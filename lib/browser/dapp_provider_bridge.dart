/// Native side of the in-app dApp provider bridge.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/browser/dapp_browser_store.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

class DappProviderBridge {
  DappProviderBridge(this.ref);

  final WidgetRef ref;

  Future<Map<String, dynamic>> handle({
    required BuildContext context,
    required String origin,
    required String method,
    required List<dynamic> args,
  }) async {
    try {
      final result = await _dispatch(
        context: context,
        origin: origin,
        method: method,
        args: args,
      );
      return {'result': result};
    } catch (e) {
      return {'error': e.toString().replaceFirst('Exception: ', '')};
    }
  }

  Future<dynamic> _dispatch({
    required BuildContext context,
    required String origin,
    required String method,
    required List<dynamic> args,
  }) async {
    final phrase = ref.read(phraseProvider);
    if (phrase == null) {
      throw Exception('Wallet is locked. Unlock Zunia and try again.');
    }
    final wallet = ref.read(walletProvider);
    final account = wallet.active;
    if (account == null) {
      throw Exception('No wallet account available.');
    }

    switch (method) {
      case 'enable':
        return _enable(context, origin, args);
      case 'disable':
        await DappBrowserStore.instance.revoke(origin);
        return null;
      case 'getKey':
        return _getKey(origin, phrase, account, _requireChainId(args));
      case 'getAccounts':
        final chainId = args.isEmpty || args.first == null
            ? (wallet.enabledChainIds.isEmpty
                ? 'cosmoshub-4'
                : wallet.enabledChainIds.first)
            : args.first.toString();
        final key = await _getKey(origin, phrase, account, chainId);
        return [
          {
            'address': key['bech32Address'],
            'algo': 'secp256k1',
            'pubkey': key['pubKey'],
          },
        ];
      case 'signAmino':
        return _signAmino(context, origin, phrase, account, args);
      case 'signDirect':
        throw Exception(
          'signDirect is not available in this build. Use amino signing.',
        );
      case 'signArbitrary':
        return _signArbitrary(context, origin, phrase, account, args);
      case 'verifyArbitrary':
        return false;
      case 'experimentalSuggestChain':
        return _suggestChain(context, args);
      case 'getChainInfos':
      case 'getChainInfosWithoutEndpoints':
        return _chainInfos();
      case 'sendTx':
        throw Exception(
          'sendTx is not supported from the browser. Sign then broadcast from the dApp.',
        );
      default:
        throw Exception('Method not supported: $method');
    }
  }

  String _requireChainId(List<dynamic> args) {
    if (args.isEmpty || args.first == null) {
      throw Exception('chainId required');
    }
    return args.first.toString();
  }

  List<String> _normalizeChainIds(dynamic raw) {
    if (raw == null) return const [];
    if (raw is String) return [raw];
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return [raw.toString()];
  }

  Future<void> _enable(
    BuildContext context,
    String origin,
    List<dynamic> args,
  ) async {
    final requested = _normalizeChainIds(args.isEmpty ? null : args.first);
    final wallet = ref.read(walletProvider);
    final chainIds = requested.isEmpty
        ? (wallet.enabledChainIds.isEmpty
            ? const ['cosmoshub-4']
            : wallet.enabledChainIds)
        : requested;

    for (final id in chainIds) {
      if (ChainCatalog.instance.find(id) == null && ChainCatalog.isLoaded) {
        // Unknown chains are still grantable if the dApp will suggest later.
      }
    }

    final already = <String>[];
    final missing = <String>[];
    for (final id in chainIds) {
      if (await DappBrowserStore.instance.isEnabled(origin, id)) {
        already.add(id);
      } else {
        missing.add(id);
      }
    }
    if (missing.isEmpty) return;

    if (!context.mounted) throw Exception('Browser closed');
    final approved = await _confirmConnect(
      context,
      origin: origin,
      chains: [...already, ...missing],
    );
    if (approved != true) {
      throw Exception('Request rejected');
    }
    await DappBrowserStore.instance.grant(origin, missing);
  }

  Future<Map<String, dynamic>> _getKey(
    String origin,
    String phrase,
    WalletAccount account,
    String chainId,
  ) async {
    if (!await DappBrowserStore.instance.isEnabled(origin, chainId)) {
      throw Exception('Chain $chainId is not enabled for this site. Call enable() first.');
    }
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) {
      throw Exception('Unknown chain: $chainId');
    }
    final derived = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: chain,
      accountIndex: account.index,
    );
    return {
      'name': account.name,
      'algo': 'secp256k1',
      'pubKey': derived.publicKey.toList(),
      'address': derived.address,
      'bech32Address': derived.address,
      'isNanoLedger': false,
      'isKeystone': false,
    };
  }

  Future<Map<String, dynamic>> _signAmino(
    BuildContext context,
    String origin,
    String phrase,
    WalletAccount account,
    List<dynamic> args,
  ) async {
    if (args.length < 3) throw Exception('signAmino requires chainId, signer, signDoc');
    final chainId = args[0].toString();
    final signer = args[1].toString();
    final signDocRaw = args[2];
    if (!await DappBrowserStore.instance.isEnabled(origin, chainId)) {
      throw Exception('Not connected. Call enable($chainId) first.');
    }
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');

    final derived = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: chain,
      accountIndex: account.index,
    );
    if (derived.address != signer) {
      throw Exception('Signer mismatch');
    }

    if (signDocRaw is! Map || signDocRaw['chain_id'] != chainId) {
      throw Exception('The document to sign is not for $chainId');
    }

    if (!context.mounted) throw Exception('Browser closed');
    final approved = await _confirmSign(
      context,
      origin: origin,
      title: 'Sign transaction',
      detail: const JsonEncoder.withIndent('  ').convert(signDocRaw),
      chainId: chainId,
      address: signer,
    );
    if (approved != true) throw Exception('Request rejected');

    final key = _signingKey(phrase, chain, account, signer);
    return signAminoResult(key, Map<String, dynamic>.from(signDocRaw));
  }

  /// Chains with Ethermint keys (coin type 60) hash with Keccak, which this
  /// signer does not do: their addresses do not match and the request is refused.
  CosmosSigningKey _signingKey(
    String phrase,
    ChainEntry chain,
    WalletAccount account,
    String signer,
  ) {
    final key = CosmosKeyring(phrase).key(
      coinType: chain.coinType,
      accountIndex: account.index,
    );
    if (key.address(chain.bech32Prefix) != signer) {
      throw Exception('Signing for ${chain.chainName} accounts is not supported yet');
    }
    return key;
  }

  /// Keplr passes a string or a Uint8Array, which reaches the bridge as a
  /// list or an index-keyed object.
  Uint8List _arbitraryBytes(Object? data) {
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    if (data is List && data.every((v) => v is int && v >= 0 && v < 256)) {
      return Uint8List.fromList(data.cast<int>());
    }
    if (data is Map) {
      final values = [
        for (var i = 0; i < data.length; i++) data['$i'],
      ];
      if (values.every((v) => v is int && v >= 0 && v < 256)) {
        return Uint8List.fromList(values.cast<int>());
      }
    }
    throw Exception('signArbitrary data must be a string or bytes');
  }

  Future<Map<String, dynamic>> _signArbitrary(
    BuildContext context,
    String origin,
    String phrase,
    WalletAccount account,
    List<dynamic> args,
  ) async {
    if (args.length < 3) {
      throw Exception('signArbitrary requires chainId, signer, data');
    }
    final chainId = args[0].toString();
    final signer = args[1].toString();
    final data = args[2];
    if (!await DappBrowserStore.instance.isEnabled(origin, chainId)) {
      throw Exception('Not connected. Call enable($chainId) first.');
    }
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');
    final derived = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: chain,
      accountIndex: account.index,
    );
    if (derived.address != signer) throw Exception('Signer mismatch');

    final bytes = _arbitraryBytes(data);
    final text = data is String ? data : null;
    var title = 'Sign message';
    if (text != null && looksLikeSignIn(text)) {
      final message = parseSignInMessage(text);
      checkSignInBinding(
        message,
        origin: webOrigin(origin) ?? origin,
        chainId: chainId,
        signer: signer,
      );
      title = 'Sign in to ${message.domain}';
    }

    if (!context.mounted) throw Exception('Browser closed');
    final approved = await _confirmSign(
      context,
      origin: origin,
      title: title,
      detail: text ?? base64Encode(bytes),
      chainId: chainId,
      address: signer,
    );
    if (approved != true) throw Exception('Request rejected');

    final key = _signingKey(phrase, chain, account, signer);
    return signArbitraryResult(key, signer, bytes);
  }

  Future<void> _suggestChain(BuildContext context, List<dynamic> args) async {
    if (args.isEmpty || args.first is! Map) {
      throw Exception('Invalid chain info');
    }
    final info = Map<String, dynamic>.from(args.first as Map);
    final chainId = info['chainId']?.toString() ?? '';
    final chainName = info['chainName']?.toString() ?? chainId;
    if (chainId.isEmpty) throw Exception('chainId required');
    if (ChainCatalog.instance.find(chainId) != null) return;

    final approved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final s = ZuniaSemanticsExt.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: s.surfaceRaised,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Add network?',
                      style: zuniaSans(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      chainName,
                      style: zuniaSans(fontSize: 15, color: s.fg),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chainId,
                      style: zuniaMono(fontSize: 12, color: s.fgMuted),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Suggested networks are not auto-added yet. Enable a matching chain in Networks, or use a catalog chain.',
                      style: zuniaSans(fontSize: 13, color: s.fgMuted),
                    ),
                    const SizedBox(height: 18),
                    ZuniaButton(
                      label: 'OK',
                      onPressed: () => Navigator.pop(ctx, true),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    if (approved != true) throw Exception('Request rejected');
  }

  List<Map<String, dynamic>> _chainInfos() {
    if (!ChainCatalog.isLoaded) return const [];
    return ChainCatalog.instance.all
        .map(
          (c) => {
            'chainId': c.chainId,
            'chainName': c.chainName,
            'bech32Config': {
              'bech32PrefixAccAddr': c.bech32Prefix,
            },
            'bip44': {'coinType': c.coinType},
            'currencies': [
              {
                'coinDenom': c.coinDenom,
                'coinMinimalDenom': c.coinMinimalDenom,
                'coinDecimals': c.coinDecimals,
              },
            ],
          },
        )
        .toList();
  }

  Future<bool?> _confirmConnect(
    BuildContext context, {
    required String origin,
    required List<String> chains,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final s = ZuniaSemanticsExt.of(ctx);
        final host = Uri.tryParse(origin)?.host ?? origin;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: s.surfaceRaised,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Connect to dApp',
                      style: zuniaSans(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      host,
                      style: zuniaMono(fontSize: 13, color: s.accent),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'This site wants access to:',
                      style: zuniaSans(fontSize: 13, color: s.fgMuted),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final id in chains)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: s.glass,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              id,
                              style: zuniaMono(fontSize: 11, color: s.fg),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Keys stay in Zunia. The page only receives addresses and asks you to approve signatures.',
                      style: zuniaSans(fontSize: 12.5, color: s.fgMuted),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: ZuniaButton(
                            label: 'Reject',
                            variant: ZuniaButtonVariant.secondary,
                            onPressed: () => Navigator.pop(ctx, false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ZuniaButton(
                            label: 'Connect',
                            onPressed: () => Navigator.pop(ctx, true),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool?> _confirmSign(
    BuildContext context, {
    required String origin,
    required String title,
    required String detail,
    required String chainId,
    required String address,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final s = ZuniaSemanticsExt.of(ctx);
        final host = Uri.tryParse(origin)?.host ?? origin;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Material(
              color: s.surfaceRaised,
              borderRadius: BorderRadius.circular(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.78,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: zuniaSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: s.fg,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(host, style: zuniaMono(fontSize: 12, color: s.accent)),
                      const SizedBox(height: 4),
                      Text(
                        '$chainId · $address',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: zuniaMono(fontSize: 11, color: s.fgMuted),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: s.glass,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: SingleChildScrollView(
                            child: Text(
                              detail,
                              style: zuniaMono(fontSize: 11, color: s.fg),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ZuniaButton(
                              label: 'Reject',
                              variant: ZuniaButtonVariant.secondary,
                              onPressed: () => Navigator.pop(ctx, false),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ZuniaButton(
                              label: 'Approve',
                              onPressed: () => Navigator.pop(ctx, true),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
