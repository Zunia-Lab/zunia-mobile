/// Shared pieces for the swap tests: real bundled data, real-looking
/// addresses, and LCDs that answer from a script instead of the network.
library;

import 'package:bech32/bech32.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/swap/swap_data.dart';

/// A valid bech32 address with [prefix], [bytes] long, every byte [fill].
String bech(String prefix, int fill, [int bytes = 20]) {
  final data = Uint8List(bytes)..fillRange(0, bytes, fill);
  final words = <int>[];
  var acc = 0;
  var bits = 0;
  for (final byte in data) {
    acc = (acc << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      words.add((acc >> bits) & 31);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) words.add((acc << (5 - bits)) & 31);
  return const Bech32Codec().encode(Bech32(prefix, words), 1023);
}

SwapData? _data;

/// The data the app bundles, loaded once per test file.
Future<SwapData> loadTestSwapData() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (_data != null) return _data!;
  await ChainCatalog.load();
  return _data = await SwapData.load(rootBundle);
}

typedef LcdAnswer = Object? Function(String path, Map<String, Object?> query);

/// An LCD that answers from [answer], recording every path it is asked. An
/// answer that throws is the endpoint's error.
class ScriptedLcd implements LcdClient {
  ScriptedLcd(this.chainId, this.answer);

  @override
  final String chainId;
  final LcdAnswer answer;
  final List<String> calls = [];

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    final query = options?.query ?? const <String, Object?>{};
    calls.add(
      query.isEmpty
          ? path
          : '$path?${query.entries.map((e) => '${e.key}=${e.value}').join('&')}',
    );
    return answer(path, query);
  }
}

/// The error an LCD client raises for a 404.
InterchainError notFound(String chainId, String path) => InterchainError(
  InterchainErrorCode.lcdUnreachable,
  '$chainId: $path answered HTTP 404',
  chainId: chainId,
  httpStatus: 404,
);
