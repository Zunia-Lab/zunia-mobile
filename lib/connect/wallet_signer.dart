/// Accounts and signatures the wallet gives to dApps paired over
/// zunia.connect.v2, derived the way the rest of the app derives them.
library;

import 'dart:convert';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';

/// The account at [accountIndex] on each of [chainIds] the wallet can sign
/// for. Chains missing from the catalog are skipped, and so are chains whose
/// addresses this signer cannot produce (Ethermint-style keys), so a site is
/// never handed an account it could not get signatures from.
List<NativeConnectAccount> connectAccountsFor({
  required String phrase,
  required int accountIndex,
  required Iterable<String> chainIds,
  String? accountName,
}) {
  if (!ChainCatalog.isLoaded) return const [];
  final keyring = CosmosKeyring(phrase);
  final accounts = <NativeConnectAccount>[];
  for (final chainId in chainIds) {
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) continue;
    final key = keyring.key(coinType: chain.coinType, accountIndex: accountIndex);
    final address = key.address(chain.bech32Prefix);
    try {
      final shown = WalletKernel.instance
          .deriveAddress(phrase: phrase, chain: chain, accountIndex: accountIndex)
          .address;
      if (shown != address) continue;
    } catch (_) {
      continue;
    }
    accounts.add(
      NativeConnectAccount(
        chainId: chainId,
        address: address,
        pubKey: base64Encode(key.publicKey),
        name: accountName,
      ),
    );
  }
  return accounts;
}

/// Signs what the user approved. Throws [ConnectException] when the account
/// the site asked for is not one this phrase derives.
Map<String, Object?> signNativeRequest(
  NativeSignRequest request, {
  required String phrase,
}) {
  final chain =
      ChainCatalog.isLoaded ? ChainCatalog.instance.find(request.chainId) : null;
  if (chain == null) {
    throw ConnectException('UNKNOWN_CHAIN', '${request.chainId} is not in the chain list');
  }
  final key = CosmosKeyring(phrase).key(
    coinType: chain.coinType,
    accountIndex: request.accountIndex,
  );
  if (key.address(chain.bech32Prefix) != request.signer) {
    throw const ConnectException(
      'INVALID_PARAMS',
      'The account the site asked for is not in this wallet',
    );
  }
  return switch (request.kind) {
    NativeSignKind.amino => signAminoResult(key, request.aminoDoc),
    NativeSignKind.direct => signDirectResult(key, request.directDoc!),
    NativeSignKind.message ||
    NativeSignKind.signIn =>
      signArbitraryResult(key, request.signer, request.data!),
  };
}
