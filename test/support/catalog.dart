import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';

/// Loads the bundled chain catalog and token table the way the app does at
/// startup, so identity, price and send tests read the same data the phone
/// ships with (and the extension 0.1.5 it was copied from).
Future<void> loadBundledData() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await ChainCatalog.load();
  ChainCatalog.instance.setCustom(const []);
  if (!TokenRegistry.isLoaded) {
    TokenRegistry.loadFromStrings(
      File('assets/data/token-registry.json').readAsStringSync(),
      File('assets/data/ibc-channels.json').readAsStringSync(),
    );
  }
  resetTokenIdentityState();
}

/// A chain the user added, as custom_chains.dart stores it.
ChainEntry customChain({
  String chainId = 'my-osmo-fork-1',
  String chainName = 'My Osmosis Fork',
  String bech32Prefix = 'osmo',
  String network = 'testnet',
  String coinDenom = 'OSMO',
  String coinMinimalDenom = 'uosmo',
}) =>
    ChainEntry(
      chainId: chainId,
      chainName: chainName,
      bech32Prefix: bech32Prefix,
      coinType: 118,
      network: network,
      coinDenom: coinDenom,
      coinMinimalDenom: coinMinimalDenom,
      coinDecimals: 6,
      feeDenom: coinDenom,
      feeMinimalDenom: coinMinimalDenom,
      feeDecimals: 6,
    );
