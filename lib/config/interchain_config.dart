/// Cross-chain swap and IBC routing configuration.
///
/// Values mirror [config/interchain.yaml] and are supplied at build time with
/// `--dart-define`. The one that matters is [kOsmosisXcsContract]: the Osmosis
/// crosschain-swaps address is deployment data, not a protocol constant, and a
/// wrong address in a memo sends funds to a contract that will not send them
/// back. It therefore ships **unset**, the swap flow fails closed with a
/// visible reason until it is configured, and the address is additionally
/// checked on chain before any memo is built.
library;

/// Chain the crosschain-swaps contract runs on.
const String kSwapVenueChainId = String.fromEnvironment(
  'OSMOSIS_CHAIN_ID',
  defaultValue: 'osmosis-1',
);

/// The Osmosis crosschain-swaps contract.
///
/// Empty by default and deliberately so. INTERCHAIN-SPEC.md lists two candidate
/// addresses seen in governance and docs, both unverified; hardcoding either
/// would make this wallet route funds through whatever that address later
/// becomes. Set it with:
///
/// ```
/// flutter run --dart-define=OSMOSIS_XCS_CONTRACT=osmo1…
/// ```
const String kOsmosisXcsContract = String.fromEnvironment(
  'OSMOSIS_XCS_CONTRACT',
);

/// The Osmosis sidecar query server, which prices swaps.
///
/// Without it the wallet can only price a pool the caller already names, so the
/// quote panel says so rather than showing a blank rate.
const String kOsmosisRouterBaseUrl = String.fromEnvironment(
  'OSMOSIS_SQS_URL',
  defaultValue: 'https://sqs.osmosis.zone',
);

/// Default slippage tolerance, as a 0-100 percentage.
///
/// One percent: enough for a normal pool to fill, tight enough that a thin pool
/// fails the swap rather than filling it at a price the user would not have
/// accepted. The swaprouter divides this by 100 itself.
const double kSwapDefaultSlippagePercent = 1;

/// Tolerances the picker offers.
const List<double> kSlippagePresets = [0.5, 1, 3];

// There is deliberately no "warn above" constant here: `zuniaCheckSlippage` in
// zunia_ui owns that threshold, and a second copy would drift from the one the
// quote panel actually renders.

/// Per-hop packet timeout, in minutes. Becomes the PFM `timeout` string.
const int kPacketTimeoutMinutes = 10;

/// Whether a TWAP window is sent at all.
///
/// Null omits `window_seconds`, so the contract's own `unwrap_or(3600)` applies.
/// Guessing a shorter window narrows the average and reads a noisier price on a
/// thin pool, which is a worse default than the contract's.
const int? kTwapWindowSeconds = null;
