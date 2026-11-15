/// LCD broadcast + account lookup for wallet-originated txs.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zunia_mobile/chains/chain_catalog.dart';

const _timeout = Duration(seconds: 20);

class BroadcastResult {
  const BroadcastResult({
    required this.txhash,
    required this.code,
    required this.rawLog,
  });

  final String txhash;
  final int code;
  final String rawLog;

  bool get success => code == 0;
}

class BroadcastException implements Exception {
  BroadcastException(this.message, {this.txhash, this.code});
  final String message;
  final String? txhash;
  final int? code;

  @override
  String toString() => message;
}

class BroadcastService {
  BroadcastService._();
  static final instance = BroadcastService._();

  Future<({String accountNumber, String sequence})> fetchAccount({
    required String chainId,
    required String address,
  }) async {
    final rest = _restOf(chainId);
    final uri = Uri.parse(
      '$rest/cosmos/auth/v1beta1/accounts/${Uri.encodeComponent(address)}',
    );
    final res = await _request('GET', uri);
    if (res.statusCode == 404) {
      return (accountNumber: '0', sequence: '0');
    }
    final body = res.body;
    if (res.statusCode != 200) {
      if (body['code'] == 5) {
        return (accountNumber: '0', sequence: '0');
      }
      throw BroadcastException('Account query HTTP ${res.statusCode}');
    }
    return parseAccountNumbers(body);
  }

  Future<BroadcastResult> broadcast({
    required String chainId,
    required String txBytesBase64,
    String mode = 'BROADCAST_MODE_SYNC',
  }) async {
    final rest = _restOf(chainId);
    final uri = Uri.parse('$rest/cosmos/tx/v1beta1/txs');
    final res = await _request('POST', uri, {
      'tx_bytes': txBytesBase64,
      'mode': mode,
    });
    final body = res.body;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BroadcastException(
        body['message'] as String? ?? 'Broadcast HTTP ${res.statusCode}',
      );
    }
    final response = (body['tx_response'] as Map<String, dynamic>?) ?? body;
    final txhash =
        (response['txhash'] ?? response['hash'] ?? '').toString().toUpperCase();
    if (txhash.isEmpty) {
      throw BroadcastException('Broadcast response has no txhash');
    }
    final code = response['code'] is int ? response['code'] as int : 0;
    final rawLog = (response['raw_log'] ?? '').toString();
    if (code != 0) {
      throw BroadcastException(
        rawLog.isEmpty ? 'Rejected (code $code)' : rawLog,
        txhash: txhash,
        code: code,
      );
    }
    return BroadcastResult(txhash: txhash, code: code, rawLog: rawLog);
  }

  String _restOf(String chainId) {
    final chain = ChainCatalog.instance.find(chainId);
    final rest = chain?.rest?.replaceAll(RegExp(r'/$'), '');
    if (rest == null || rest.isEmpty) {
      throw BroadcastException('No REST endpoint for $chainId');
    }
    return rest;
  }


  Future<({int statusCode, Map<String, dynamic> body})> _request(
    String method,
    Uri uri, [
    Map<String, dynamic>? payload,
  ]) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(_timeout)
          : await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(payload)));
      }
      final response = await request.close().timeout(_timeout);
      final text =
          await response.transform(utf8.decoder).join().timeout(_timeout);
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(text.isEmpty ? '{}' : text);
        body = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{'value': decoded};
      } on FormatException {
        body = {'message': text};
      }
      return (statusCode: response.statusCode, body: body);
    } on TimeoutException {
      throw BroadcastException('Network timeout talking to $uri');
    } on SocketException catch (e) {
      throw BroadcastException('Could not reach chain REST: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}

/// The account number and sequence in a `/cosmos/auth/v1beta1/accounts/{addr}`
/// answer, whatever kind of account it is.
///
/// The two numbers sit at different depths: on a `BaseAccount` itself; under
/// `base_account` on an Ethermint or Injective `EthAccount` and on a module
/// account; under `base_vesting_account.base_account` on every vesting
/// account (continuous, periodic, delayed, permanent-locked, Evmos clawback).
/// Reading only `base_account` took a vesting account for number 0, sequence
/// 0. About half of Safrochain's accounts are vesting accounts, and every
/// transaction they signed was refused ("signature verification failed;
/// please verify account number … and sequence"), since the number is part of
/// what is signed and simulation does not check it.
///
/// An absent account (`{"account": null}`) is a new one: 0 and 0. An account
/// whose numbers cannot be found throws rather than guess: a guessed number
/// signs a transaction the chain refuses.
({String accountNumber, String sequence}) parseAccountNumbers(Map<String, dynamic> body) {
  if (body.containsKey('account') && body['account'] == null) {
    return (accountNumber: '0', sequence: '0');
  }
  final envelope = body['account'] ?? body['info'] ?? body;
  final holder = _numbersHolder(envelope, 0);
  if (holder == null) {
    throw BroadcastException('The account answer has no account number');
  }
  final number = '${holder['account_number']}';
  final sequence = '${holder['sequence'] ?? '0'}';
  if (!RegExp(r'^\d+$').hasMatch(number) || !RegExp(r'^\d+$').hasMatch(sequence)) {
    throw BroadcastException('The account answer has an unreadable account number or sequence');
  }
  return (accountNumber: number, sequence: sequence);
}

/// The first map that carries `account_number`: depth-first, through the
/// known wrappers before any other nested map.
Map<String, dynamic>? _numbersHolder(Object? node, int depth) {
  if (node is! Map || depth > 4) return null;
  final map = node.cast<String, dynamic>();
  if (map.containsKey('account_number')) return map;
  for (final key in const ['base_account', 'base_vesting_account', 'account']) {
    final found = _numbersHolder(map[key], depth + 1);
    if (found != null) return found;
  }
  for (final value in map.values) {
    final found = _numbersHolder(value, depth + 1);
    if (found != null) return found;
  }
  return null;
}
