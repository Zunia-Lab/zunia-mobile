/// Cross-chain swap and IBC routing configuration.
///
/// Swap reads its deployment data (contract candidates, router hosts,
/// slippage, quote lifetime) from `assets/data/interchain.json`, the file the
/// extension release ships (`lib/swap/swap_config.dart`). What is left here
/// are build-time overrides and the values older IBC screens still read.
library;

/// Chain the crosschain-swaps contract runs on.
const String kSwapVenueChainId = String.fromEnvironment(
  'OSMOSIS_CHAIN_ID',
  defaultValue: 'osmosis-1',
);

/// An extra Osmosis crosschain-swaps candidate for this build, checked first.
///
/// The release's candidates live in `assets/data/interchain.json`
/// (`xcsContractCandidates`, copied from the extension) and every one, this
/// included, is confirmed on chain before the contract path is enabled: a
/// wrong address in a memo sends funds to a contract that will not send them
/// back. Empty by default; set it only to try another deployment:
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
