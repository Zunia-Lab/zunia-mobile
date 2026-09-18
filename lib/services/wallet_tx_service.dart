/// Sign + broadcast wallet-originated amino txs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/broadcast_service.dart';

/// Gas limit for a set of messages.
///
/// Public because the review screen shows the fee this produces: a screen that
/// computed its own number would eventually show one the wallet does not pay.
/// These are ceilings, not measurements — the chain refunds nothing — so they
/// are deliberately generous.
int defaultGasFor(List<AminoMsg> msgs) {
  if (msgs.any((m) => m.type == 'wasm/MsgExecuteContract')) return 350000;
  if (msgs.any((m) => m.type == 'cosmos-sdk/MsgTransfer')) {
    // A transfer carrying an ibc-hooks or packet-forward memo costs more to
    // encode and store than a bare one, and the memo is the whole point of a
    // cross-chain swap.
    final memoBytes = msgs
        .where((m) => m.type == 'cosmos-sdk/MsgTransfer')
        .map((m) => (m.value['memo'] as String? ?? '').length)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return memoBytes > 0 ? 400000 : 250000;
  }
  if (msgs.any(
    (m) => m.type.contains('Delegate') || m.type.contains('Withdraw'),
  )) {
    return 250000;
  }
  if (msgs.length > 1) return 200000 + msgs.length * 80000;
  return 200000;
}

class WalletTxService {
  WalletTxService._();
  static final instance = WalletTxService._();

  Future<String> signAndBroadcast({
    required String phrase,
    required ChainEntry chain,
    required String signerAddress,
    required List<AminoMsg> msgs,
    int accountIndex = 0,
    String memo = '',
    int? gasLimit,
    StdFee? fee,
  }) async {
    final limit = gasLimit ?? defaultGasFor(msgs);
    final resolvedFee = fee ??
        estimateFee(
          gasLimit: limit,
          gasPrice: chain.averageGasPrice,
          denom: chain.feeMinimalDenom.isEmpty
              ? chain.coinMinimalDenom
              : chain.feeMinimalDenom,
        );
    final account = await BroadcastService.instance.fetchAccount(
      chainId: chain.chainId,
      address: signerAddress,
    );
    final signDoc = makeStdSignDoc(
      chainId: chain.chainId,
      accountNumber: account.accountNumber,
      sequence: account.sequence,
      fee: resolvedFee,
      msgs: msgs,
      memo: memo,
    );

    final derived = WalletKernel.instance.deriveAddress(
      phrase: phrase,
      chain: chain,
      accountIndex: accountIndex,
    );
    if (derived.address != signerAddress) {
      throw BroadcastException(
        'Signer mismatch: expected $signerAddress, derived ${derived.address}',
      );
    }

    final signature = _signAmino(
      phrase: phrase,
      coinType: chain.coinType,
      accountIndex: accountIndex,
      signDoc: signDoc,
    );
    final txRaw = assembleAminoTxRaw(
      signDoc: signDoc,
      pubKey: derived.publicKey,
      signature: signature,
    );
    final result = await BroadcastService.instance.broadcast(
      chainId: chain.chainId,
      txBytesBase64: base64Encode(txRaw),
    );
    return result.txhash;
  }


  /// SHA-256(signDoc) → secp256k1 compact r||s with low-s normalisation.
  Uint8List _signAmino({
    required String phrase,
    required int coinType,
    required int accountIndex,
    required StdSignDoc signDoc,
  }) {
    final seed = bip39.mnemonicToSeed(phrase.trim());
    final path = "m/44'/$coinType'/$accountIndex'/0/0";
    final node = bip32.BIP32.fromSeed(seed).derivePath(path);
    final digest = Uint8List.fromList(
      sha256.convert(serializeAminoSignDoc(signDoc)).bytes,
    );
    return Uint8List.fromList(node.sign(digest) as List<int>);
  }
}
