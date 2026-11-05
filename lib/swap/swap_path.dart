/// Which way Swap reaches Osmosis for one pair.
///
/// Port of zunia-extension 0.1.5 `lib/swap-path.ts`. Three venues execute a
/// swap on Osmosis:
/// - Skip Go's entry point (`one_signature.dart`): one transfer from the chain
///   holding the funds, whose memo swaps them in Osmosis's pools and delivers
///   the output, for any pair the router prices. Nothing to sign on Osmosis
///   and no OSMO needed.
/// - The crosschain-swaps contract: the same shape, but only for the pairs in
///   its route table (`xcs_routes.dart`).
/// - Osmosis's own pools (`pool_swap.dart`): any pair they connect, but only
///   for funds already on Osmosis, paid to the signer there.
library;

/// What the contract's route table says about a pair.
///
/// `yes`: the router has the pair. `no`: it has not. `unknown`: no table to
/// ask, or a side it cannot name. `unknown` never disables anything.
enum Executable { yes, no, unknown }

/// - [contract]: the crosschain-swaps contract: an IBC transfer whose memo
///   calls it, or a call on Osmosis. It delivers the whole output wherever the
///   To is.
/// - [pool]: the funds and the To are both on Osmosis. One poolmanager swap.
/// - [poolDeliver]: the funds are on Osmosis and the To is on another chain
///   the contract cannot reach for this pair. One transaction: the swap, then
///   a transfer of its guaranteed minimum to that chain.
/// - [moveFirst]: the funds are on another chain and the contract cannot swap
///   the pair. They move to Osmosis first; the swap there is then [pool] or
///   [poolDeliver].
/// - [oneSignature]: the funds are on another chain that reaches Osmosis in
///   one canonical hop, and the output is wanted on Osmosis or one direct hop
///   from it. One transfer whose memo calls Skip Go's entry point: it swaps in
///   Osmosis's pools and delivers, with no step on Osmosis.
enum SwapPath { contract, pool, poolDeliver, moveFirst, oneSignature }

/// The path for selling on [fromChainId] and buying on [toChainId], given the
/// route table's [answer] for the pair. Funds on Osmosis swap in its pools,
/// unless the contract can deliver the whole output to another chain. Funds
/// elsewhere take one signature through the entry point when [oneSignature]
/// (`oneSignatureReaches`) says the pair allows it, whatever the route table
/// holds; otherwise the contract unless its table says it cannot swap the pair
/// (an unreadable table leaves that to the live route check), and otherwise
/// they move to Osmosis first.
SwapPath swapPathFor(
  String fromChainId,
  String toChainId,
  Executable answer, {
  required String venueChainId,
  bool oneSignature = false,
}) {
  if (fromChainId == venueChainId) {
    if (toChainId == venueChainId) return SwapPath.pool;
    return answer == Executable.yes ? SwapPath.contract : SwapPath.poolDeliver;
  }
  if (oneSignature) return SwapPath.oneSignature;
  return answer == Executable.no ? SwapPath.moveFirst : SwapPath.contract;
}

/// Whether the path signs a poolmanager swap now.
bool isPoolPath(SwapPath? path) =>
    path == SwapPath.pool || path == SwapPath.poolDeliver;

/// Whether the path is priced by the router for Osmosis's pools (and so keeps
/// a pool plan): every path but the crosschain-swaps contract.
bool pricesInPools(SwapPath? path) =>
    path != null && path != SwapPath.contract;
