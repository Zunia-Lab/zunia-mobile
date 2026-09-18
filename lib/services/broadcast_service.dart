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
    return _parseAccount(body);
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

  ({String accountNumber, String sequence}) _parseAccount(
    Map<String, dynamic> body,
  ) {
    if (body['account'] == null && body.containsKey('account')) {
      return (accountNumber: '0', sequence: '0');
    }
    final envelope = (body['account'] as Map<String, dynamic>?) ??
        (body['info'] as Map<String, dynamic>?) ??
        body;
    final nested =
        (envelope['base_account'] as Map<String, dynamic>?) ?? envelope;
    return (
      accountNumber: '${nested['account_number'] ?? '0'}',
      sequence: '${nested['sequence'] ?? '0'}',
    );
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
