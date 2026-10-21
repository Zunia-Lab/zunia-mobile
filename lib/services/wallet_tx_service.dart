/// Sign and broadcast for screens built on the Amino message helpers.
///
/// Everything goes through [TxEngine]: the kernel signs Direct, after a
/// simulation sized the gas. The Amino builders only describe the messages.
library;

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/amino_tx.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

/// A gas ceiling for a set of messages, for screens that show an estimate
/// before the simulation has run. The signed fee comes from [TxEngine.quote].
int defaultGasFor(List<AminoMsg> msgs) {
  if (msgs.any((m) => m.type == 'wasm/MsgExecuteContract')) return 350000;
  if (msgs.any((m) => m.type == 'cosmos-sdk/MsgTransfer')) {
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

  /// Simulates, prices at [speed], signs with the kernel and broadcasts.
  /// Returns the transaction hash.
  Future<String> signAndBroadcast({
    required String phrase,
    required ChainEntry chain,
    required String signerAddress,
    required List<AminoMsg> msgs,
    int accountIndex = 0,
    String memo = '',
    FeeSpeed speed = FeeSpeed.average,
  }) {
    return TxEngine.instance.send(
      phrase: phrase,
      accountIndex: accountIndex,
      chain: chain,
      signer: signerAddress,
      msgs: [for (final m in msgs) TxMsg.fromAmino(m)],
      memo: memo,
      speed: speed,
    );
  }
}
