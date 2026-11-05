/// Waits for a broadcast transaction to land in a block.
///
/// [TxEngine.signAndBroadcast] returns once the node accepted the transaction
/// into its mempool (sync mode). That is not "staked" or "voted": the block
/// can still refuse it. The result screen says "Confirming" until this sees
/// the transaction in a block, then reports what the block decided, which is
/// what the extension's `waitForInclusion` does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';

sealed class Inclusion {
  const Inclusion();
}

/// In a block and executed.
final class Included extends Inclusion {
  const Included(this.height);
  final String height;
}

/// In a block, and the chain refused it there. The fee was still paid.
final class FailedInBlock extends Inclusion {
  const FailedInBlock(this.code, this.message);
  final int code;

  /// In plain words, see [explainChainError].
  final String message;
}

/// Not seen within the wait. It may still land; the explorer will tell.
final class NotYetSeen extends Inclusion {
  const NotYetSeen();
}

/// Ask [chain] about [hash] every [every] until [within] has passed.
///
/// Not gated on live reads: the user has just sent this transaction to the
/// same endpoint, and reporting whether it worked is part of sending it.
Future<Inclusion> waitForInclusion(
  ChainEntry chain,
  String hash, {
  Duration within = const Duration(seconds: 60),
  Duration every = const Duration(milliseconds: 2500),
  @visibleForTesting LcdFetch? fetch,
}) async {
  final rest = chain.rest?.trim().replaceAll(RegExp(r'/+$'), '');
  if (rest == null || rest.isEmpty) return const NotYetSeen();
  final client = HttpLcdClient(
    chainId: chain.chainId,
    endpoints: [rest],
    retries: 0,
    timeout: const Duration(seconds: 8),
    fetch: fetch,
  );
  final deadline = DateTime.now().add(within);
  while (true) {
    try {
      final body = await client.getJson('/cosmos/tx/v1beta1/txs/$hash');
      final response = asMap(asMap(body)['tx_response']);
      if (response.isNotEmpty) {
        final code = int.tryParse(asString(response['code'], '0')) ?? 0;
        if (code == 0) return Included(asString(response['height']));
        return FailedInBlock(
          code,
          explainChainError(asString(response['raw_log'])),
        );
      }
    } on Object {
      // 404 until indexed, or a node hiccup: ask again.
    }
    if (DateTime.now().add(every).isAfter(deadline)) return const NotYetSeen();
    await Future<void>.delayed(every);
  }
}
