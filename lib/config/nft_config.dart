/// NFT configuration: known collections, ICS721 bridges and channels, and the
/// gateways artwork may be fetched from.
///
/// A sibling of `interchain_config.dart` and it follows the same rule: every
/// value is deployment data, none of it is a protocol constant, and everything
/// ships **unset** so a build either has it or fails closed with a visible
/// reason. Two of these are unrecoverable if wrong — a cw-ics721 bridge address
/// escrows the NFT, and an ICS721 channel decides which chain mints the voucher
/// — so neither has a default, and there is no "probably right" fallback list.
///
/// The parsers are public and pure so they can be tested without a build flag.
library;

/// Split a comma-separated `--dart-define` list, dropping blanks.
List<String> parseCsvConfig(String raw) => [
      for (final part in raw.split(',')) part.trim(),
    ].where((value) => value.isNotEmpty).toList();

/// Parse `chain-a=addr1,addr2;chain-b=addr3` into a per-chain list.
///
/// Later entries for the same chain merge rather than replace, so a build can
/// append without knowing what came before. Malformed segments are skipped
/// rather than throwing: a typo in one chain's entry must not take the whole
/// NFT surface down, and the chains that did parse still work.
Map<String, List<String>> parseChainListConfig(String raw) {
  final out = <String, List<String>>{};
  for (final segment in raw.split(';')) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) continue;
    final split = trimmed.indexOf('=');
    if (split <= 0) continue;
    final chainId = trimmed.substring(0, split).trim();
    if (chainId.isEmpty) continue;
    final values = parseCsvConfig(trimmed.substring(split + 1));
    if (values.isEmpty) continue;
    final bucket = out.putIfAbsent(chainId, () => <String>[]);
    for (final value in values) {
      if (!bucket.contains(value)) bucket.add(value);
    }
  }
  return out;
}

/// Parse `chain-a=value;chain-b=value` into one value per chain.
///
/// The key may itself contain `>` for a directed pair, which is how ICS721
/// channels are keyed: `source>destination=channel-3`.
Map<String, String> parseChainValueConfig(String raw) {
  final out = <String, String>{};
  for (final segment in raw.split(';')) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) continue;
    final split = trimmed.indexOf('=');
    if (split <= 0) continue;
    final key = trimmed.substring(0, split).trim();
    final value = trimmed.substring(split + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    out[key] = value;
  }
  return out;
}

/// Key for a directed ICS721 pair.
String ics721ChannelKey(String sourceChainId, String destChainId) =>
    '$sourceChainId>$destChainId';

const String _knownCollectionsRaw = String.fromEnvironment(
  'NFT_KNOWN_COLLECTIONS',
);

const String _ics721BridgesRaw = String.fromEnvironment('ICS721_BRIDGES');

const String _ics721ChannelsRaw = String.fromEnvironment('ICS721_CHANNELS');

const String _ipfsGatewaysRaw = String.fromEnvironment('NFT_IPFS_GATEWAYS');

const String _arweaveGatewaysRaw =
    String.fromEnvironment('NFT_ARWEAVE_GATEWAYS');

/// CW721 contracts this build ships per chain, e.g.
/// `--dart-define=NFT_KNOWN_COLLECTIONS='safrochain-1=addr_safro1abc,addr_safro1def'`.
///
/// Empty by default. CosmWasm has no chain-wide "tokens by owner" index, so
/// with no list and no indexer the only discovery path left is the address the
/// user types — which is exactly what the collection screen says instead of
/// showing an empty gallery.
final Map<String, List<String>> kNftKnownCollections =
    parseChainListConfig(_knownCollectionsRaw);

/// cw-ics721 bridge contract per chain, e.g.
/// `--dart-define=ICS721_BRIDGES='safrochain-1=addr_safro1bridge'`.
///
/// Empty by default and deliberately so: this contract takes custody of the
/// NFT. A wrong address escrows it somewhere nothing can release it from, and
/// unlike a bad denom there is no second copy.
final Map<String, String> kIcs721Bridges =
    parseChainValueConfig(_ics721BridgesRaw);

/// ICS721 channel per directed chain pair, e.g.
/// `--dart-define=ICS721_CHANNELS='safrochain-1>osmosis-1=channel-3'`.
///
/// Keyed by [ics721ChannelKey]. ICS721 runs on its own port (`wasm.<bridge>`),
/// so an ICS20 transfer channel is not interchangeable with one of these and
/// the wallet never reuses one.
final Map<String, String> kIcs721Channels =
    parseChainValueConfig(_ics721ChannelsRaw);

/// IPFS gateway bases artwork and metadata may be read from, e.g.
/// `--dart-define=NFT_IPFS_GATEWAYS='https://ipfs.io/ipfs/'`.
///
/// Empty by default. A gateway baked into the wallet would route every user's
/// collection through one operator, who then learns which addresses hold which
/// tokens; hosts differ on which one they trust, so this is theirs to choose.
/// With none set, `ipfs://` artwork simply cannot be fetched and the screen
/// says that rather than showing a blank frame.
final List<String> kNftIpfsGateways = parseCsvConfig(_ipfsGatewaysRaw);

/// Arweave gateway bases for `ar://`. Same reasoning, same default.
final List<String> kNftArweaveGateways = parseCsvConfig(_arweaveGatewaysRaw);

/// Per-chain NFT indexers.
///
/// There is no configuration for one because no implementation ships: an
/// indexer is a service-specific client, not a URL, and inventing a protocol
/// nobody serves would put a "complete" badge on a list that was never indexed.
/// `discoverNfts` takes an [NftIndexer] whenever one is written; until then
/// every list this client shows reports itself as partial.
///
/// See `NftDiscoveryResult.complete` and `nftDiscoveryLimitation`.
const bool kNftIndexerAvailable = false;

/// Gas ceiling for a CW721 execute.
///
/// `defaultGasFor` in `wallet_tx_service.dart` already returns 350000 for a
/// `wasm/MsgExecuteContract`, which is the figure the fee shown on the review
/// screen comes from; this constant exists only so the screens can say the same
/// number without importing the tx layer's private reasoning.
const int kNftTransferGasLimit = 350000;
