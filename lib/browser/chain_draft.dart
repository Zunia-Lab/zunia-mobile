/// Checks for a chain a dApp proposes through `experimentalSuggestChain`
/// before anything is saved (zunia-extension/lib/chain-draft.ts): it ends up
/// deriving addresses and receiving balance queries, so a bad endpoint or a
/// hidden character in a name is refused here, naming the first bad field.
library;

import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';

final _chainId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _prefix = RegExp(r'^[a-z][a-z0-9]{1,19}$');

/// The Cosmos SDK base-denom rule, which also admits IBC and factory paths.
final _denom = RegExp(r'^[a-zA-Z][a-zA-Z0-9/:._-]{1,127}$');
final _control = RegExp('[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]');
const _maxCoinType = 0x7fffffff;
const _defaultGasPrice = 0.025;

Never _bad(String message) => throw ProviderError.invalid(message);

String _label(Object? value, String field, int max) {
  if (value is! String) _bad('$field is required');
  final trimmed = value.trim();
  if (trimmed.isEmpty) _bad('$field is required');
  if (trimmed.length > max) _bad('$field must be $max characters or fewer');
  if (_control.hasMatch(trimmed)) _bad('$field contains hidden or control characters');
  return trimmed;
}

/// An endpoint the wallet will send the user's addresses to: HTTPS only, no
/// credentials in it.
String cleanEndpoint(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) _bad('$field is required');
  final raw = value.trim();
  if (raw.length > 2048) _bad('$field is too long');
  final url = Uri.tryParse(raw);
  if (url == null || !url.hasScheme || url.host.isEmpty) _bad('$field is not a valid URL');
  if (url.scheme != 'https') _bad('$field must be an https:// URL');
  if (url.userInfo.isNotEmpty) _bad('$field must not contain a username or password');
  return raw.replaceFirst(RegExp(r'/+$'), '');
}

int _whole(Object? value, String field, int min, int max) {
  final n = value is String && value.trim().isNotEmpty ? num.tryParse(value.trim()) : value;
  if (n is! num || n != n.truncate() || n < min || n > max) {
    _bad('$field must be a whole number from $min to $max');
  }
  return n.toInt();
}

Map<String, dynamic> _record(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

Map<String, dynamic> _first(Object? value) =>
    value is List && value.isNotEmpty ? _record(value.first) : const {};

/// A Keplr-style `ChainInfo` read into a catalog row and validated. Unknown
/// fields are ignored, and so are `features`: like the extension, a suggested
/// chain derives Cosmos-style addresses (an Ethermint flag from a site is not
/// trusted to change which key signs). [isRegistryChain] refuses an id the
/// bundled registry already has.
ChainEntry draftFromSuggestedChain(
  Object? raw, {
  required bool Function(String chainId) isRegistryChain,
}) {
  final info = _record(raw);
  final bech32 = _record(info['bech32Config']);
  final bip44 = _record(info['bip44']);
  final currency = _first(info['currencies']);
  final stake = _record(info['stakeCurrency']);
  final fee = _first(info['feeCurrencies']);
  final primary = currency.isNotEmpty ? currency : stake;
  final step = _record(fee['gasPriceStep']);

  final chainId = '${info['chainId'] ?? ''}'.trim();
  if (chainId.isEmpty) _bad('Chain ID is required');
  if (!_chainId.hasMatch(chainId)) {
    _bad('Chain ID may use letters, digits, dot, dash and underscore (64 characters max)');
  }
  if (isRegistryChain(chainId)) _bad('That chain ID is already in the registry');

  final prefix = '${bech32['bech32PrefixAccAddr'] ?? info['bech32Prefix'] ?? ''}'.trim();
  if (!_prefix.hasMatch(prefix)) {
    _bad('Prefix must be lowercase letters, optionally followed by digits');
  }
  final minimal = '${primary['coinMinimalDenom'] ?? ''}'.trim();
  if (!_denom.hasMatch(minimal)) _bad('Base denom is not a valid Cosmos denom');

  final priceRaw = step['average'] ?? step['low'];
  final gasPrice = priceRaw == null ? _defaultGasPrice : (priceRaw is num ? priceRaw.toDouble() : double.tryParse('$priceRaw'));
  if (gasPrice == null || !gasPrice.isFinite || gasPrice < 0 || gasPrice > 1000000) {
    _bad('Gas price must be a positive number');
  }

  final name = _label(info['chainName'] ?? info['chainId'], 'Name', 48);
  final rpc = cleanEndpoint(info['rpc'], 'RPC');
  final rest = cleanEndpoint(info['rest'], 'REST');
  final coinType = _whole(bip44['coinType'] ?? info['coinType'], 'Coin type', 0, _maxCoinType);
  final symbol = _label(primary['coinDenom'], 'Symbol', 16);
  final decimals = _whole(primary['coinDecimals'], 'Decimals', 0, 18);

  return ChainEntry(
    chainId: chainId,
    chainName: name,
    bech32Prefix: prefix,
    coinType: coinType,
    // What the extension files a suggested chain under: it came from a site,
    // not the registry.
    network: 'testnet',
    coinDenom: symbol,
    coinMinimalDenom: minimal,
    coinDecimals: decimals,
    feeDenom: symbol,
    feeMinimalDenom: minimal,
    feeDecimals: decimals,
    gasPriceStep: {
      'low': gasPrice,
      'average': gasPrice,
      'high': gasPrice * 2,
    },
    rpc: rpc,
    rest: rest,
  );
}
