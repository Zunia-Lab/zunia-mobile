import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/memo.dart';

/// Pins the Dart memo output to the bytes the TypeScript engine emits.
///
/// The two implementations are ports of one another, and a memo is the only
/// part of a cross-chain transfer the chain cannot help us get right: a wrong
/// field name or key order is not rejected, it is executed as something else,
/// and the funds are gone. These literals were produced by running
/// `@zunialab/interchain`'s `buildForwardMemo` / `buildXcsSwapMemo` with the
/// same inputs and diffing the output; regenerate them the same way if the
/// TypeScript side deliberately changes.
void main() {
  const tsForward =
      '{"forward":{"receiver":"pfm","port":"transfer","channel":"channel-123",'
      '"timeout":"10m","retries":2,"next":{"forward":{"receiver":"osmo1final",'
      '"port":"transfer","channel":"channel-234","timeout":"10m","retries":2}}}}';

  const tsXcs =
      '{"wasm":{"contract":"osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs",'
      '"msg":{"osmosis_swap":{"output_denom":"uosmo","slippage":{"twap":'
      '{"slippage_percentage":"5","window_seconds":10}},"receiver":"addr_safro1recip",'
      '"on_failed_delivery":{"local_recovery_addr":"osmo1recovery"},"next_memo":null}}}}';

  test('the PFM forward memo matches the TypeScript engine byte for byte', () {
    expect(
      buildForwardMemo(
        const [
          ForwardHop(channelId: 'channel-123'),
          ForwardHop(channelId: 'channel-234'),
        ],
        'osmo1final',
      ),
      tsForward,
    );
  });

  test('the XCS swap memo matches the TypeScript engine byte for byte', () {
    expect(
      buildXcsSwapMemo(
        contract:
            'osmo1uwk8xc6q0s6t5qcpr6rht3sczu6du83xq8pwxjua0hfj5hzcnh3sqxwvxs',
        outputDenom: 'uosmo',
        receiver: 'addr_safro1recip',
        slippage: const XcsTwapSlippage(
          slippagePercentage: '5',
          windowSeconds: 10,
        ),
        onFailedDelivery: const XcsLocalRecovery('osmo1recovery'),
      ),
      tsXcs,
    );
  });
}
