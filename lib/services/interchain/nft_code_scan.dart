/// Finds the CW721 collections on a CosmWasm chain from the chain's own wasm
/// code list, as the extension does (`scanCw721Contracts` in its lib/nft.ts).
///
/// CosmWasm keeps no index of NFTs by owner, so with no indexer and no list of
/// known collections there is otherwise no question to ask. Contracts of one
/// code run the same bytecode, so "is this a CW721?" is asked once per code,
/// with the exact `tokens` query discovery then sends, and the verdict is kept
/// for good because wasm code never changes. Instances are listed only for the
/// codes that turned out to be collections, newest first, within a budget.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lcd.dart';
import 'nft.dart';
import 'types.dart';

/// Codes looked at per run, newest first: a code uploaded recently is far more
/// likely to be a live collection than code 1.
const int kNftScanMaxCodes = 40;

/// CW721 instances collected per run.
const int kNftScanMaxContracts = 50;

/// Instances listed per CW721 code, so one popular code cannot use the whole
/// budget.
const int kNftScanMaxContractsPerCode = 25;

/// How long a run's contract list is reused before the chain is listed again.
const Duration kNftScanContractsTtl = Duration(hours: 6);

/// What one chain's scan remembers between runs.
class NftCodeScanRecord {
  const NftCodeScanRecord({
    this.codes = const {},
    this.contracts = const [],
    this.contractsAt,
  });

  /// Code id to `true` (CW721) or `false` (anything else). Permanent.
  final Map<String, bool> codes;

  /// The CW721 instances the last run collected.
  final List<String> contracts;
  final DateTime? contractsAt;

  Map<String, Object?> toJson() => {
    'codes': codes,
    'contracts': contracts,
    if (contractsAt != null) 'contractsAt': contractsAt!.millisecondsSinceEpoch,
  };

  static NftCodeScanRecord fromJson(Object? value) {
    if (value is! Map) return const NftCodeScanRecord();
    final codes = <String, bool>{
      for (final entry
          in (value['codes'] is Map ? value['codes'] as Map : const {}).entries)
        if (entry.value is bool) '${entry.key}': entry.value as bool,
    };
    final contracts = [
      for (final row
          in (value['contracts'] is List
              ? value['contracts'] as List
              : const []))
        if (row is String && row.isNotEmpty) row,
    ];
    final at = value['contractsAt'];
    return NftCodeScanRecord(
      codes: codes,
      contracts: contracts,
      contractsAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

/// Where scan records live. A store that fails costs requests, never results.
abstract class NftCodeScanStore {
  Future<NftCodeScanRecord> read(String chainId);
  Future<void> write(String chainId, NftCodeScanRecord record);
}

/// The app's store: one SharedPreferences entry, versioned so a format change
/// (or a run recorded under a bug) can be dropped wholesale.
class SharedPrefsNftCodeScanStore implements NftCodeScanStore {
  const SharedPrefsNftCodeScanStore();

  static const _key = 'zunia.nft.wasmScan';
  static const _version = 1;

  Future<Map<String, Object?>> _chains(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded['version'] == _version &&
          decoded['chains'] is Map) {
        return Map<String, Object?>.from(decoded['chains'] as Map);
      }
    } on FormatException {
      // Dropped: a cache is rebuilt, not repaired.
    }
    return {};
  }

  @override
  Future<NftCodeScanRecord> read(String chainId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return NftCodeScanRecord.fromJson((await _chains(prefs))[chainId]);
    } on Object {
      return const NftCodeScanRecord();
    }
  }

  @override
  Future<void> write(String chainId, NftCodeScanRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final chains = await _chains(prefs);
      chains[chainId] = record.toJson();
      await prefs.setString(
        _key,
        jsonEncode({'version': _version, 'chains': chains}),
      );
    } on Object {
      // Failing to write a cache costs requests, not truth.
    }
  }
}

/// What one scan produced.
@immutable
class NftCodeScanResult {
  const NftCodeScanResult({
    this.contracts = const [],
    this.codesScanned = 0,
    this.fromCache = false,
  });

  /// CW721 instances, newest code first. Candidates, not holdings: discovery
  /// still asks each one what [owner] holds.
  final List<String> contracts;

  /// Codes whose verdict this run used, cached or fresh. Zero means the chain
  /// was never asked, which the gallery must not report as "nothing found".
  final int codesScanned;

  final bool fromCache;
}

/// Lists CW721 contracts from the chain's code list.
///
/// Deliberately not an [NftIndexer]: discovery marks a list "complete" when an
/// indexer answers, and a budgeted scan of the newest codes is never that. The
/// gallery passes [NftCodeScanResult.contracts] as candidates instead, as the
/// extension does.
class NftCodeScanner {
  NftCodeScanner(this.ctx, {required this.store, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final NftChainContext ctx;
  final NftCodeScanStore store;
  final DateTime Function() _now;

  /// Scan, or reuse the last run while it is younger than
  /// [kNftScanContractsTtl]. [force] skips that reuse; code verdicts are kept
  /// either way, because wasm code never changes.
  ///
  /// Throws only `aborted`, `readsDisabled` and the code list's own failure:
  /// one code or instance that will not answer is skipped, not fatal.
  Future<NftCodeScanResult> scan(String owner, {bool force = false}) async {
    final chainId = ctx.chain.chainId;
    final stored = await store.read(chainId);
    final at = stored.contractsAt;
    if (!force && at != null && _now().difference(at) < kNftScanContractsTtl) {
      return NftCodeScanResult(
        contracts: stored.contracts,
        codesScanned: stored.codes.length,
        fromCache: true,
      );
    }

    final codes = Map<String, bool>.from(stored.codes);
    final addresses = <String>[];
    var scanned = 0;
    for (final codeId in await _codeIds()) {
      if (addresses.length >= kNftScanMaxContracts) break;
      // A code known not to be a CW721 costs nothing.
      if (codes[codeId] == false) {
        scanned += 1;
        continue;
      }
      final List<String> instances;
      try {
        instances = await _instances(codeId);
      } on InterchainError catch (error) {
        if (_isFinal(error)) rethrow;
        continue;
      }
      if (instances.isEmpty) continue;
      final verdict = codes[codeId] ?? await _classify(instances, owner);
      if (verdict == null) continue;
      codes[codeId] = verdict;
      scanned += 1;
      if (!verdict) continue;
      for (final address in instances) {
        if (addresses.contains(address)) continue;
        addresses.add(address);
        if (addresses.length >= kNftScanMaxContracts) break;
      }
    }

    await store.write(
      chainId,
      NftCodeScanRecord(
        codes: codes,
        contracts: addresses,
        contractsAt: _now(),
      ),
    );
    return NftCodeScanResult(contracts: addresses, codesScanned: scanned);
  }

  /// Code ids, newest first. A node behind a trimming proxy may reject the
  /// pagination flags; it is then asked once more without them.
  Future<List<String>> _codeIds() async {
    const base = '/cosmwasm/wasm/v1/code';
    Object? body;
    try {
      body = await ctx.lcd.getJson(
        base,
        const LcdRequestOptions(
          query: {
            'pagination.limit': '$kNftScanMaxCodes',
            'pagination.reverse': 'true',
          },
        ),
      );
    } on InterchainError catch (error) {
      if (_isFinal(error)) rethrow;
      body = await ctx.lcd.getJson(
        base,
        const LcdRequestOptions(
          query: {'pagination.limit': '$kNftScanMaxCodes'},
        ),
      );
    }
    final rows = body is Map && body['code_infos'] is List
        ? body['code_infos'] as List
        : const [];
    final ids = <String>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = '${row['code_id'] ?? row['id'] ?? ''}';
      if (id.isEmpty || id == 'null' || ids.contains(id)) continue;
      ids.add(id);
    }
    return ids;
  }

  Future<List<String>> _instances(String codeId) async {
    final body = await ctx.lcd.getJson(
      '/cosmwasm/wasm/v1/code/${Uri.encodeComponent(codeId)}/contracts',
      const LcdRequestOptions(
        query: {
          'pagination.limit': '$kNftScanMaxContractsPerCode',
          'pagination.reverse': 'true',
        },
      ),
    );
    final rows = body is Map && body['contracts'] is List
        ? body['contracts'] as List
        : const [];
    return [
      for (final row in rows)
        if (row is String && row.isNotEmpty) row,
    ];
  }

  /// Whether a code is a CW721, from up to two of its instances: one dead
  /// contract must not condemn a whole collection's code. Null when the node
  /// would not answer either way, because a verdict cached from an outage
  /// would be permanent.
  Future<bool?> _classify(List<String> instances, String owner) async {
    for (final address in instances.take(2)) {
      try {
        await listOwnedTokenIds(ctx, address, owner);
        return true;
      } on InterchainError catch (error) {
        if (_isFinal(error)) rethrow;
        if (_isNotCw721(error)) return false;
      }
    }
    return null;
  }

  static bool _isFinal(InterchainError error) =>
      error.code == InterchainErrorCode.aborted ||
      error.code == InterchainErrorCode.readsDisabled;

  static bool _isNotCw721(InterchainError error) =>
      error.code == InterchainErrorCode.contractError ||
      error.code == InterchainErrorCode.malformedResponse ||
      error.httpStatus == 400;
}
