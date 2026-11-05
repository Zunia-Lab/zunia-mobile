/// Validation for chains that do not come from the bundled registry: the ones
/// a user types into Add network and the ones a site proposes through
/// `experimentalSuggestChain`. Both end up deriving addresses and receiving
/// balance queries, so both go through the same checks before anything is
/// saved.
///
/// Dart mirror of zunia-extension/lib/chain-draft.ts. Pure on purpose: no
/// storage and no catalog singleton, so the rules are tested directly.
library;

import 'package:zunia_mobile/chains/chain_catalog.dart';

/// Gas price used when a draft names none, as in the extension.
const defaultCustomGasPrice = 0.025;

class ChainDraftError implements Exception {
  const ChainDraftError(this.message);

  /// One sentence naming the first field that is wrong, fit to show as is.
  final String message;

  @override
  String toString() => message;
}

/// What a person (or a site) supplies to add a chain.
class CustomChainDraft {
  const CustomChainDraft({
    required this.chainName,
    required this.chainId,
    required this.rpc,
    required this.rest,
    required this.bech32Prefix,
    required this.coinType,
    required this.coinDenom,
    required this.coinMinimalDenom,
    required this.coinDecimals,
    this.gasPrice = defaultCustomGasPrice,
    this.testnet = false,
  });

  final String chainName;
  final String chainId;
  final String rpc;
  final String rest;
  final String bech32Prefix;
  final int coinType;

  /// Ticker, e.g. `SAF`.
  final String coinDenom;

  /// Base denom, e.g. `usaf`.
  final String coinMinimalDenom;
  final int coinDecimals;

  /// Average gas price in [coinMinimalDenom].
  final double gasPrice;

  /// Lists the chain under Testnets rather than Mainnets.
  final bool testnet;

  /// The catalog row this draft becomes. Fees are paid in the staking coin
  /// and the high step is twice the average, as the extension saves them.
  ChainEntry toEntry() => ChainEntry(
        chainId: chainId,
        chainName: chainName,
        bech32Prefix: bech32Prefix,
        coinType: coinType,
        network: testnet ? 'testnet' : 'mainnet',
        coinDenom: coinDenom,
        coinMinimalDenom: coinMinimalDenom,
        coinDecimals: coinDecimals,
        feeDenom: coinDenom,
        feeMinimalDenom: coinMinimalDenom,
        feeDecimals: coinDecimals,
        gasPriceStep: {
          'low': gasPrice,
          'average': gasPrice,
          'high': gasPrice * 2,
        },
        rpc: rpc,
        rest: rest,
      );
}

final _chainIdRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

/// Lowercase letters first, then letters, digits or `_` (Safrochain's
/// `addr_safro` has one). Uppercase never: bech32 prefixes are lowercase.
final _prefixRe = RegExp(r'^[a-z][a-z0-9_]{1,19}$');

/// The Cosmos SDK base-denom rule, which also admits IBC and factory paths.
final _denomRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9/:._-]{1,127}$');

final _controlRe = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);

const _maxCoinType = 0x7fffffff;

String _cleanLabel(Object? value, String field, int max) {
  if (value is! String || value.trim().isEmpty) {
    throw ChainDraftError('$field is required');
  }
  final trimmed = value.trim();
  if (trimmed.length > max) {
    throw ChainDraftError('$field must be $max characters or fewer');
  }
  if (_controlRe.hasMatch(trimmed)) {
    throw ChainDraftError('$field contains hidden or control characters');
  }
  return trimmed;
}

/// An endpoint the wallet will send the user's addresses to: https only, no
/// credentials in it, trailing slashes trimmed.
String cleanEndpoint(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw ChainDraftError('$field is required');
  }
  final raw = value.trim();
  if (raw.length > 2048) throw ChainDraftError('$field is too long');
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ChainDraftError('$field is not a valid URL');
  }
  if (uri.scheme != 'https') {
    throw ChainDraftError('$field must be an https:// URL');
  }
  if (uri.userInfo.isNotEmpty) {
    throw ChainDraftError('$field must not contain a username or password');
  }
  return raw.replaceAll(RegExp(r'/+$'), '');
}

int _wholeNumber(Object? value, String field, int min, int max) {
  final n = value is String ? int.tryParse(value.trim()) : value;
  if (n is! int || n < min || n > max) {
    throw ChainDraftError('$field must be a whole number from $min to $max');
  }
  return n;
}

/// Normalise [draft] or throw a [ChainDraftError] naming the first bad field.
///
/// [isRegistryChainId] answers whether the bundled registry already carries a
/// chain id. A custom row must never shadow a registry one: a site suggesting
/// `cosmoshub-4` with its own endpoints would otherwise redirect every Hub read
/// and broadcast to a host it controls.
CustomChainDraft validateCustomChainDraft(
  CustomChainDraft draft, {
  required bool Function(String chainId) isRegistryChainId,
}) {
  final chainId = draft.chainId.trim();
  if (chainId.isEmpty) throw const ChainDraftError('Chain ID is required');
  if (!_chainIdRe.hasMatch(chainId)) {
    throw const ChainDraftError(
      'Chain ID may use letters, digits, dot, dash and underscore (64 characters max)',
    );
  }
  if (isRegistryChainId(chainId)) {
    throw const ChainDraftError('That chain ID is already in the registry');
  }

  final prefix = draft.bech32Prefix.trim();
  if (!_prefixRe.hasMatch(prefix)) {
    throw const ChainDraftError(
      'Prefix must be lowercase letters, optionally followed by digits',
    );
  }

  final denom = draft.coinMinimalDenom.trim();
  if (!_denomRe.hasMatch(denom)) {
    throw const ChainDraftError('Base denom is not a valid Cosmos denom');
  }

  final gasPrice = draft.gasPrice;
  if (!gasPrice.isFinite || gasPrice < 0 || gasPrice > 1000000) {
    throw const ChainDraftError('Gas price must be a positive number');
  }

  return CustomChainDraft(
    chainId: chainId,
    chainName: _cleanLabel(draft.chainName, 'Name', 48),
    rpc: cleanEndpoint(draft.rpc, 'RPC'),
    rest: cleanEndpoint(draft.rest, 'REST'),
    bech32Prefix: prefix,
    coinType: _wholeNumber(draft.coinType, 'Coin type', 0, _maxCoinType),
    coinDenom: _cleanLabel(draft.coinDenom, 'Symbol', 16),
    coinMinimalDenom: denom,
    coinDecimals: _wholeNumber(draft.coinDecimals, 'Decimals', 0, 18),
    gasPrice: gasPrice,
    testnet: draft.testnet,
  );
}

Map<String, dynamic> _record(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

Map<String, dynamic> _firstRecord(Object? value) =>
    value is List && value.isNotEmpty ? _record(value.first) : const {};

int _intOr(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

double _doubleOr(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// Read a Keplr-style `ChainInfo` (the shape sites pass to
/// `experimentalSuggestChain`) into a draft. Unknown fields are ignored and
/// nothing is trusted: the result still has to pass
/// [validateCustomChainDraft], which `CustomChainsController.addSuggested`
/// runs before anything is stored.
CustomChainDraft draftFromSuggestedChain(Object? raw) {
  final info = _record(raw);
  final bech32 = _record(info['bech32Config']);
  final bip44 = _record(info['bip44']);
  final currency = _firstRecord(info['currencies']);
  final stake = _record(info['stakeCurrency']);
  final fee = _firstRecord(info['feeCurrencies']);
  final primary = currency.isNotEmpty ? currency : stake;
  final step = _record(fee['gasPriceStep']);
  final features = info['features'];

  return CustomChainDraft(
    chainId: '${info['chainId'] ?? ''}',
    chainName: '${info['chainName'] ?? info['chainId'] ?? ''}',
    rpc: '${info['rpc'] ?? ''}',
    rest: '${info['rest'] ?? ''}',
    bech32Prefix: '${bech32['bech32PrefixAccAddr'] ?? info['bech32Prefix'] ?? ''}',
    // -1 fails validation with "Coin type must be a whole number": a
    // suggestion that leaves it out is refused, never defaulted to 118, since
    // the wrong coin type derives an address the user cannot recover.
    coinType: _intOr(bip44['coinType'] ?? info['coinType'], -1),
    coinDenom: '${primary['coinDenom'] ?? ''}',
    coinMinimalDenom: '${primary['coinMinimalDenom'] ?? ''}',
    coinDecimals: _intOr(primary['coinDecimals'], -1),
    gasPrice: _doubleOr(
      step['average'] ?? step['low'],
      defaultCustomGasPrice,
    ),
    testnet: features is List && features.contains('testnet'),
  );
}
