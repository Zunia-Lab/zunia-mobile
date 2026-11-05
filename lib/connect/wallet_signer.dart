/// Accounts and signatures the wallet gives to dApps paired over
/// zunia.connect.v2 (and WalletConnect, which feeds the same requests), derived
/// and signed by the kernel exactly as the in-app browser and the extension do.
library;

import 'dart:convert';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';

/// The account at [accountIndex] on each of [chainIds]. Chains missing from
/// the catalog, or that the kernel refuses to derive for, are skipped, so a
/// site is never handed an account it could not get signatures from.
///
/// Ethermint-style chains (Evmos, Injective) are included: the kernel derives
/// and signs them with keccak, which the Dart signer this replaced could not.
List<NativeConnectAccount> connectAccountsFor({
  required String phrase,
  required int accountIndex,
  required Iterable<String> chainIds,
  String? accountName,
}) {
  if (!ChainCatalog.isLoaded) return const [];
  final accounts = <NativeConnectAccount>[];
  for (final chainId in chainIds) {
    final chain = ChainCatalog.instance.find(chainId);
    if (chain == null) continue;
    try {
      final key = CosmosSigningKey(phrase: phrase, chain: chain, accountIndex: accountIndex);
      accounts.add(
        NativeConnectAccount(
          chainId: chainId,
          address: key.address(),
          pubKey: base64Encode(key.publicKey),
          algo: key.algo,
          name: accountName,
        ),
      );
    } catch (_) {
      continue;
    }
  }
  return accounts;
}

/// Signs what the user approved, over the bytes the review described.
///
/// [aminoDoc] / [directDoc] replace the request's own document when the user
/// picked another fee tier; nothing else may differ. Throws [ConnectException]
/// when the account the site asked for is not one this phrase derives, or the
/// document is for another chain than the request.
Map<String, Object?> signNativeRequest(
  NativeSignRequest request, {
  required String phrase,
  Map<String, dynamic>? aminoDoc,
  DirectSignDoc? directDoc,
}) {
  final chain =
      ChainCatalog.isLoaded ? ChainCatalog.instance.find(request.chainId) : null;
  if (chain == null) {
    throw ConnectException('UNKNOWN_CHAIN', '${request.chainId} is not in the chain list');
  }
  final key = CosmosSigningKey(
    phrase: phrase,
    chain: chain,
    accountIndex: request.accountIndex,
  );
  if (key.address() != request.signer) {
    throw const ConnectException(
      'INVALID_PARAMS',
      'The account the site asked for is not in this wallet',
    );
  }
  switch (request.kind) {
    case NativeSignKind.amino:
      final doc = aminoDoc ?? request.aminoDoc;
      if (doc == null || doc['chain_id'] != request.chainId) {
        throw ConnectException(
          'INVALID_PARAMS',
          'The document is for another chain than ${request.chainId}',
        );
      }
      return signAminoResult(key, doc);
    case NativeSignKind.direct:
      final doc = directDoc ?? request.directDoc;
      if (doc == null || doc.chainId != request.chainId) {
        throw ConnectException(
          'INVALID_PARAMS',
          'The document is for another chain than ${request.chainId}',
        );
      }
      return signDirectResult(key, doc);
    case NativeSignKind.message || NativeSignKind.signIn:
      final data = request.data!;
      if (!adr36PayloadIsSafe(data)) {
        throw const ConnectException(
          'INVALID_PARAMS',
          'ADR-36 data looks like a transaction sign doc; refusing to sign',
        );
      }
      return signArbitraryResult(key, request.signer, data);
  }
}
