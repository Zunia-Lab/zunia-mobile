/// Every transaction the wallet itself sends goes through here, in the order
/// the extension uses (zunia-extension/lib/tx-kernel.ts):
///
/// 1. read the signer's account number and sequence;
/// 2. simulate with a zero signature to learn the gas;
/// 3. price the gas at the chosen speed and adjustment;
/// 4. have the kernel describe the exact transaction ([TxQuote.preview]);
/// 5. after the user approves, have the kernel derive, sign and assemble it;
/// 6. broadcast.
///
/// The fee and sequence the user saw are the ones signed: [signAndBroadcast]
/// takes the [TxQuote] and refuses one whose sign bytes no longer match.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:zunia_core/zunia_core.dart';

import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/services/broadcast_service.dart';
import 'package:zunia_mobile/tx/tx_msg.dart';

enum FeeSpeed { low, average, high }

extension FeeSpeedLabel on FeeSpeed {
  String get label => switch (this) {
        FeeSpeed.low => 'Low',
        FeeSpeed.average => 'Mid',
        FeeSpeed.high => 'High',
      };
}

/// Gas used when a chain will not simulate, as in the extension.
const fallbackGasLimit = 400000;

/// The extension's default: 40% over what the simulation measured.
const defaultGasAdjustment = 1.4;

class TxQuote {
  const TxQuote({
    required this.chain,
    required this.signer,
    required this.msgs,
    required this.memo,
    required this.accountNumber,
    required this.sequence,
    required this.fee,
    required this.speed,
    required this.gasAdjustment,
    required this.preview,
    required this.publicKeyHex,
    this.gasUsed,
    this.feeNote,
  });

  final ChainEntry chain;
  final String signer;
  final List<TxMsg> msgs;
  final String memo;
  final int accountNumber;
  final int sequence;
  final ZuniaFee fee;
  final FeeSpeed speed;
  final double gasAdjustment;

  /// What the kernel will sign, in its own words.
  final ZuniaSigningPreview preview;

  /// The signer's key, which a Direct `AuthInfo` carries.
  final String publicKeyHex;

  /// Null when the chain would not simulate.
  final int? gasUsed;

  /// Set when the fee is a guess, with the reason.
  final String? feeNote;

  /// The fee in base units of the chain's fee denom (one coin, or none).
  ZuniaCoin? get feeCoin => fee.amount.isEmpty ? null : fee.amount.first;
}

class TxException implements Exception {
  const TxException(this.message, {this.txhash});
  final String message;
  final String? txhash;

  @override
  String toString() => message;
}

class TxEngine {
  TxEngine({BroadcastService? broadcast, WalletKernel? kernel})
      : _broadcast = broadcast ?? BroadcastService.instance,
        _kernelOverride = kernel;

  static final instance = TxEngine();

  final BroadcastService _broadcast;
  final WalletKernel? _kernelOverride;

  WalletKernel get _kernel => _kernelOverride ?? WalletKernel.instance;

  /// Reads the account, simulates and prices the transaction, and returns
  /// what the review screen shows. Nothing is signed.
  Future<TxQuote> quote({
    required String phrase,
    required int accountIndex,
    required ChainEntry chain,
    required String signer,
    required List<TxMsg> msgs,
    String memo = '',
    FeeSpeed speed = FeeSpeed.average,
    double gasAdjustment = defaultGasAdjustment,
  }) async {
    if (msgs.isEmpty) throw const TxException('A transaction needs at least one message.');
    final derived = _kernel.deriveAddress(
      phrase: phrase,
      chain: chain,
      accountIndex: accountIndex,
    );
    if (derived.address != signer) {
      throw TxException(
        'This account signs as ${derived.address}, not $signer. Switch account and try again.',
      );
    }
    final account = await _broadcast.fetchAccount(
      chainId: chain.chainId,
      address: signer,
    );
    final accountNumber = int.parse(account.accountNumber);
    final sequence = int.parse(account.sequence);
    final msgJson = [for (final m in msgs) m.toJson()];
    final core = _kernel.core;

    int? gasUsed;
    String? feeNote;
    int gasLimit;
    try {
      final simulateHex = core.buildSimulateTx(
        chainId: chain.chainId,
        msgs: msgJson,
        fee: ZuniaFee(amount: const [], gasLimit: fallbackGasLimit),
        memo: memo,
        accountNumber: accountNumber,
        sequence: sequence,
        publicKeyHex: derived.publicKeyHex,
        ethKeyType: chain.usesEthKeySign,
      );
      gasUsed = await _simulate(chain, base64Encode(bytesOfHex(simulateHex)));
      gasLimit = (gasUsed * gasAdjustment).ceil();
    } on TxException catch (e) {
      gasLimit = fallbackGasLimit;
      feeNote = '${chain.chainName} would not simulate this transaction (${e.message}). '
          'The fee below uses a fixed $gasLimit gas limit and may be wrong.';
    }

    final fee = feeFor(chain, gasLimit, speed);
    final preview = core.previewTx(
      chainId: chain.chainId,
      msgs: msgJson,
      fee: fee,
      memo: memo,
      accountNumber: accountNumber,
      sequence: sequence,
      publicKeyHex: derived.publicKeyHex,
      ethKeyType: chain.usesEthKeySign,
      mode: ZuniaSignMode.direct,
    );
    return TxQuote(
      chain: chain,
      signer: signer,
      msgs: msgs,
      memo: memo,
      accountNumber: accountNumber,
      sequence: sequence,
      fee: fee,
      speed: speed,
      gasAdjustment: gasAdjustment,
      preview: preview,
      publicKeyHex: derived.publicKeyHex,
      gasUsed: gasUsed,
      feeNote: feeNote,
    );
  }

  /// The same quote at another speed, without simulating again.
  TxQuote reprice(TxQuote quote, FeeSpeed speed) {
    final fee = feeFor(quote.chain, quote.fee.gasLimit, speed);
    final preview = _kernel.core.previewTx(
      chainId: quote.chain.chainId,
      msgs: [for (final m in quote.msgs) m.toJson()],
      fee: fee,
      memo: quote.memo,
      accountNumber: quote.accountNumber,
      sequence: quote.sequence,
      publicKeyHex: quote.publicKeyHex,
      ethKeyType: quote.chain.usesEthKeySign,
      mode: ZuniaSignMode.direct,
    );
    return TxQuote(
      chain: quote.chain,
      signer: quote.signer,
      msgs: quote.msgs,
      memo: quote.memo,
      accountNumber: quote.accountNumber,
      sequence: quote.sequence,
      fee: fee,
      speed: speed,
      gasAdjustment: quote.gasAdjustment,
      preview: preview,
      publicKeyHex: quote.publicKeyHex,
      gasUsed: quote.gasUsed,
      feeNote: quote.feeNote,
    );
  }

  /// Signs exactly what [quote] described and broadcasts it. Returns the
  /// transaction hash.
  Future<String> signAndBroadcast({
    required String phrase,
    required int accountIndex,
    required TxQuote quote,
  }) async {
    final core = _kernel.core;
    final msgJson = [for (final m in quote.msgs) m.toJson()];
    // The bytes about to be signed must be the ones the user was shown.
    final signBytes = core.buildSignBytes(
      chainId: quote.chain.chainId,
      msgs: msgJson,
      fee: quote.fee,
      memo: quote.memo,
      accountNumber: quote.accountNumber,
      sequence: quote.sequence,
      publicKeyHex: quote.publicKeyHex,
      ethKeyType: quote.chain.usesEthKeySign,
      mode: ZuniaSignMode.direct,
    );
    final shown = quote.preview.signBytesHash.toLowerCase().replaceFirst('0x', '');
    if (sha256.convert(bytesOfHex(signBytes)).toString() != shown) {
      throw const TxException(
        'The transaction changed after you reviewed it. Review it again before signing.',
      );
    }
    final txHex = core.signTx(
      phrase: phrase,
      chainJson: quote.chain.toChainJson(),
      accountIndex: accountIndex,
      chainId: quote.chain.chainId,
      msgs: msgJson,
      fee: quote.fee,
      memo: quote.memo,
      accountNumber: quote.accountNumber,
      sequence: quote.sequence,
      mode: ZuniaSignMode.direct,
    );
    try {
      final result = await _broadcast.broadcast(
        chainId: quote.chain.chainId,
        txBytesBase64: base64Encode(bytesOfHex(txHex)),
      );
      return result.txhash;
    } on BroadcastException catch (e) {
      throw TxException(explainChainError(e.message), txhash: e.txhash);
    }
  }

  /// Quote and send in one go, for flows whose review screen already showed
  /// the messages and fee estimate.
  Future<String> send({
    required String phrase,
    required int accountIndex,
    required ChainEntry chain,
    required String signer,
    required List<TxMsg> msgs,
    String memo = '',
    FeeSpeed speed = FeeSpeed.average,
    double gasAdjustment = defaultGasAdjustment,
  }) async {
    final q = await quote(
      phrase: phrase,
      accountIndex: accountIndex,
      chain: chain,
      signer: signer,
      msgs: msgs,
      memo: memo,
      speed: speed,
      gasAdjustment: gasAdjustment,
    );
    return signAndBroadcast(phrase: phrase, accountIndex: accountIndex, quote: q);
  }

  /// `gasLimit × price` at [speed], rounded up, in the chain's fee denom.
  static ZuniaFee feeFor(ChainEntry chain, int gasLimit, FeeSpeed speed) {
    final step = chain.gasPriceStep;
    final price = step?[speed.name] ?? step?['average'] ?? 0.025;
    final denom =
        chain.feeMinimalDenom.isEmpty ? chain.coinMinimalDenom : chain.feeMinimalDenom;
    final amount = ceilMul(gasLimit, price);
    return ZuniaFee(
      amount: amount == BigInt.zero
          ? const []
          : [ZuniaCoin(denom: denom, amount: amount.toString())],
      gasLimit: gasLimit,
    );
  }

  /// `ceil(gas × price)` without losing an 18-decimal chain's precision: the
  /// price is scaled to an integer before multiplying.
  static BigInt ceilMul(int gas, double price) {
    if (price <= 0 || !price.isFinite) return BigInt.zero;
    const scale = 1000000000000; // 1e12
    final scaled = BigInt.from((price * scale).round());
    final product = BigInt.from(gas) * scaled;
    final whole = product ~/ BigInt.from(scale);
    return product % BigInt.from(scale) == BigInt.zero ? whole : whole + BigInt.one;
  }

  Future<int> _simulate(ChainEntry chain, String txBytesBase64) async {
    final rest = chain.rest?.replaceAll(RegExp(r'/$'), '');
    if (rest == null || rest.isEmpty) {
      throw const TxException('no REST endpoint');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(Uri.parse('$rest/cosmos/tx/v1beta1/simulate'))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode({'tx_bytes': txBytesBase64})));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final text = await response.transform(utf8.decoder).join();
      final body = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      if (response.statusCode != 200 || body is! Map<String, dynamic>) {
        final message = body is Map<String, dynamic>
            ? (body['message'] as String? ?? 'HTTP ${response.statusCode}')
            : 'HTTP ${response.statusCode}';
        throw TxException(explainChainError(message));
      }
      final used = (body['gas_info'] as Map<String, dynamic>?)?['gas_used'];
      final gas = int.tryParse('$used');
      if (gas == null || gas <= 0) throw const TxException('no gas estimate');
      return math.max(gas, 1);
    } on TimeoutException {
      throw const TxException('the node did not answer');
    } on SocketException catch (e) {
      throw TxException('could not reach the node: ${e.message}');
    } on FormatException {
      throw const TxException('the node answered something that is not JSON');
    } finally {
      client.close(force: true);
    }
  }
}

/// A chain's refusal in plain words, with the raw text kept at the end for
/// anyone who needs it.
String explainChainError(String raw) {
  final text = raw.trim();
  final lower = text.toLowerCase();
  String? plain;
  if (lower.contains('insufficient funds') || lower.contains('insufficient balance')) {
    plain = 'Not enough funds for the amount plus the network fee.';
  } else if (lower.contains('insufficient fee') || lower.contains('fee too low')) {
    plain = 'The fee is below what the network accepts. Pick a higher fee speed.';
  } else if (lower.contains('out of gas')) {
    plain = 'The transaction ran out of gas. Try again with a higher gas adjustment.';
  } else if (lower.contains('account sequence mismatch') || lower.contains('incorrect account sequence')) {
    plain = 'Another transaction from this account went through first. Try again.';
  } else if (lower.contains('tx already exists in cache') || lower.contains('tx already in mempool')) {
    plain = 'This transaction was already sent and is waiting to be included.';
  } else if (lower.contains('mempool is full')) {
    plain = 'The network is busy. Try again in a moment.';
  } else if (lower.contains('unauthorized') && lower.contains('signature')) {
    plain = 'The network did not accept the signature.';
  } else if (lower.contains('account') && lower.contains('not found')) {
    plain = 'This address has never received funds on this network, so it cannot pay a fee yet.';
  } else if (lower.contains('timeout') && lower.contains('packet')) {
    plain = 'The transfer timed out before the other network received it.';
  } else if (lower.contains('channel') && (lower.contains('closed') || lower.contains('not found'))) {
    plain = 'That IBC channel is not open.';
  } else if (lower.contains('slippage') || lower.contains('token is lesser than min amount') || lower.contains('less than min')) {
    plain = 'The price moved past your slippage limit, so the swap did not happen.';
  } else if (lower.contains('validator does not exist')) {
    plain = 'That validator does not exist on this network.';
  } else if (lower.contains('inactive proposal') || lower.contains('voting period')) {
    plain = 'This proposal is no longer open for votes.';
  }
  if (plain == null) return text;
  return text.isEmpty ? plain : '$plain ($text)';
}
