/// Ported from `zunia-sdk/packages/interchain/src/tracking.test.ts`.
///
/// The four failure kinds are the point of this module: timeout and ack-error
/// mean the funds came back, stalled means they are safe but stuck, and
/// swap-delivery-failed means they are sitting in a contract until the user
/// claims them. A tracker that collapses any two of those tells the user to do
/// the wrong thing.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

Map<String, Object?> _attr(String key, String value) =>
    {'key': key, 'value': value};

Map<String, Object?> _sendPacketEvent({
  String sequence = '7',
  String srcChannel = 'channel-141',
  String dstChannel = 'channel-0',
  String? data,
}) =>
    {
      'type': 'send_packet',
      'attributes': [
        _attr('packet_sequence', sequence),
        _attr('packet_src_port', 'transfer'),
        _attr('packet_src_channel', srcChannel),
        _attr('packet_dst_port', 'transfer'),
        _attr('packet_dst_channel', dstChannel),
        _attr('packet_timeout_timestamp', '1'),
        if (data != null) _attr('packet_data', data),
      ],
    };

Map<String, Object?> _txResponse({
  required List<Object?> events,
  String txhash = 'AA11',
  String timestamp = '2026-09-06T00:00:00Z',
}) =>
    {
      'tx_response': {
        'txhash': txhash,
        'height': '100',
        'timestamp': timestamp,
        'events': events,
      },
    };

class _FakeLcd implements LcdClient {
  _FakeLcd(this.chainId, this._routes);

  @override
  final String chainId;
  final Map<String, Object? Function(Map<String, Object?>? query)> _routes;

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    for (final entry in _routes.entries) {
      if (path.startsWith(entry.key)) return entry.value(options?.query);
    }
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'no route for $path',
      chainId: chainId,
      httpStatus: 404,
    );
  }
}

RoutePlan _plan({List<RouteHop>? hops}) => RoutePlan(
      sourceChainId: 'cosmoshub-4',
      destChainId: 'osmosis-1',
      inputDenom: 'uatom',
      outputDenom: 'uosmo',
      hops: hops ??
          const [
            RouteHop(
              chainId: 'cosmoshub-4',
              channelId: 'channel-141',
              port: 'transfer',
              counterpartyChainId: 'osmosis-1',
              kind: RouteHopKind.transfer,
            ),
          ],
      memo: '',
      warnings: const [],
      estimatedDurationSeconds: 60,
      requiresPfm: false,
      requiresIbcHooks: false,
    );

void main() {
  group('event decoding', () {
    test('reads plain and base64 attribute spellings', () {
      final encoded = {
        'type': base64Encode(utf8.encode('send_packet')),
        'attributes': [
          {
            'key': base64Encode(utf8.encode('packet_sequence')),
            'value': base64Encode(utf8.encode('7')),
          },
        ],
      };
      final events = decodeTxEvents(_txResponse(events: [encoded]));
      expect(events.single.isType('send_packet'), isTrue);
      expect(events.single.attr('packet_sequence'), '7');
    });

    test('reads the logs[].events shape as well as the flat one', () {
      final body = {
        'tx_response': {
          'txhash': 'AA11',
          'logs': [
            {
              'msg_index': 0,
              'events': [_sendPacketEvent()],
            },
          ],
        },
      };
      expect(decodeTxEvents(body).length, 1);
    });
  });

  group('extractPacketsFromTx', () {
    test('reads a packet and its ICS20 payload', () {
      final packets = extractPacketsFromTx(_txResponse(events: [
        _sendPacketEvent(
          data: jsonEncode({
            'denom': 'uatom',
            'amount': '1000000',
            'sender': 'cosmos1s',
            'receiver': 'osmo1r',
            'memo': '{"wasm":{}}',
          }),
        ),
      ]));
      final packet = packets.single;
      expect(packet.sequence, '7');
      expect(packet.sourceChannelId, 'channel-141');
      expect(packet.destChannelId, 'channel-0');
      expect(packet.data!.amount, '1000000');
      expect(packet.data!.memo, '{"wasm":{}}');
      expect(packet.txHash, 'AA11');
    });

    test('reads the ICS20 v2 tokens array', () {
      final packets = extractPacketsFromTx(_txResponse(events: [
        _sendPacketEvent(
          data: jsonEncode({
            'tokens': [
              {
                'denom': {'base': 'uatom'},
                'amount': '5',
              },
            ],
          }),
        ),
      ]));
      expect(packets.single.data!.denom, 'uatom');
      expect(packets.single.data!.amount, '5');
    });

    test('drops a packet that could never be looked up again', () {
      final packets = extractPacketsFromTx(_txResponse(events: [
        {
          'type': 'send_packet',
          'attributes': [_attr('packet_src_channel', 'channel-1')],
        },
      ]));
      expect(packets, isEmpty);
    });

    test('an unindexed or unexpected body yields nothing, never a throw', () {
      expect(extractPacketsFromTx(null), isEmpty);
      expect(extractPacketsFromTx('nonsense'), isEmpty);
      expect(extractPacketsFromTx(<String, Object?>{}), isEmpty);
    });
  });

  group('acknowledgements', () {
    test('reads both envelopes and refuses to guess at anything else', () {
      expect(parsePacketAcknowledgement('{"result":"AQ=="}')!.ok, isTrue);
      final failure = parsePacketAcknowledgement('{"error":"boom"}')!;
      expect(failure.ok, isFalse);
      expect(failure.error, 'boom');
      expect(parsePacketAcknowledgement('{}'), isNull);
      expect(parsePacketAcknowledgement('  '), isNull);
    });

    test('accepts a base64-wrapped envelope', () {
      final wrapped = base64Encode(utf8.encode('{"error":"boom"}'));
      expect(parsePacketAcknowledgement(wrapped)!.ok, isFalse);
    });
  });

  group('timing', () {
    test('a stall threshold is per hop kind, floored so it never alarms early',
        () {
      expect(estimateHopSeconds(RouteHopKind.transfer), 60);
      expect(estimateHopSeconds(RouteHopKind.swap), 20);
      // 4x the estimate, floored at five minutes.
      expect(hopStallThresholdSeconds(RouteHopKind.transfer), 300);
      expect(
        hopStallThresholdSeconds(
          RouteHopKind.transfer,
          const HopTimingProfile(transferSeconds: 600),
        ),
        2400,
      );
    });

    test('only an in-flight hop can stall', () {
      bool stalled(PacketStatus status) => isHopStalled(
            status: status,
            kind: RouteHopKind.transfer,
            elapsedSeconds: 10000,
          );
      expect(stalled(PacketStatus.pending), isTrue);
      expect(stalled(PacketStatus.relayed), isTrue);
      expect(stalled(PacketStatus.unknown), isTrue);
      // The funds have landed; a late ack is not something to chase.
      expect(stalled(PacketStatus.received), isFalse);
      expect(stalled(PacketStatus.acknowledged), isFalse);
      expect(stalled(PacketStatus.timeout), isFalse);
    });

    test('an unknown start time never reads as stalled', () {
      expect(
        isHopStalled(
          status: PacketStatus.pending,
          kind: RouteHopKind.transfer,
          elapsedSeconds: null,
        ),
        isFalse,
      );
    });
  });

  group('getPacketStatus', () {
    final packet = const ExtractedPacket(
      sequence: '7',
      sourcePort: 'transfer',
      sourceChannelId: 'channel-141',
      destPort: 'transfer',
      destChannelId: 'channel-0',
      timeoutTimestamp: '1',
    );

    test('a node with no tx index reports unknown, not pending', () async {
      final report = await getPacketStatus(
        packet,
        _FakeLcd('cosmoshub-4', const {}),
      );
      expect(report.status, PacketStatus.unknown);
      expect(report.failure, isNull);
    });

    test('an acknowledgement on the source chain is terminal success',
        () async {
      final source = _FakeLcd('cosmoshub-4', {
        '/cosmos/tx/v1beta1/txs': (query) {
          final q = query!['query']! as String;
          if (!q.contains('acknowledge_packet')) return {'tx_responses': []};
          return {
            'tx_responses': [
              {
                'txhash': 'ACK1',
                'timestamp': '2026-09-06T00:01:00Z',
                'events': [
                  {
                    'type': 'acknowledge_packet',
                    'attributes': [
                      _attr('packet_sequence', '7'),
                      _attr('packet_src_channel', 'channel-141'),
                      _attr('packet_dst_channel', 'channel-0'),
                    ],
                  },
                ],
              },
            ],
          };
        },
      });
      final report = await getPacketStatus(packet, source);
      expect(report.status, PacketStatus.acknowledged);
      expect(report.ackTxHash, 'ACK1');
      expect(report.fundsRefunded, isFalse);
    });

    test('a timeout is reported with the funds already refunded', () async {
      final source = _FakeLcd('cosmoshub-4', {
        '/cosmos/tx/v1beta1/txs': (query) {
          final q = query!['query']! as String;
          if (!q.contains('timeout_packet')) return {'tx_responses': []};
          return {
            'tx_responses': [
              {
                'txhash': 'TO1',
                'timestamp': '2026-09-06T00:11:00Z',
                'events': [
                  {
                    'type': 'timeout_packet',
                    'attributes': [
                      _attr('packet_sequence', '7'),
                      _attr('packet_src_channel', 'channel-141'),
                      _attr('packet_dst_channel', 'channel-0'),
                    ],
                  },
                ],
              },
            ],
          };
        },
      });
      final report = await getPacketStatus(packet, source);
      expect(report.status, PacketStatus.timeout);
      expect(report.failure, PacketFailureKind.timeout);
      expect(report.fundsRefunded, isTrue);
    });

    test('an error acknowledgement on the destination is a failure now',
        () async {
      final dest = _FakeLcd('osmosis-1', {
        '/cosmos/tx/v1beta1/txs': (query) {
          final q = query!['query']! as String;
          if (!q.contains('write_acknowledgement')) {
            return {'tx_responses': []};
          }
          return {
            'tx_responses': [
              {
                'txhash': 'RCV1',
                'timestamp': '2026-09-06T00:00:30Z',
                'events': [
                  {
                    'type': 'write_acknowledgement',
                    'attributes': [
                      _attr('packet_sequence', '7'),
                      _attr('packet_src_channel', 'channel-141'),
                      _attr('packet_dst_channel', 'channel-0'),
                      _attr('packet_ack', '{"error":"hook failed"}'),
                    ],
                  },
                ],
              },
            ],
          };
        },
      });
      final report = await getPacketStatus(
        packet,
        _FakeLcd('cosmoshub-4', const {}),
        destination: dest,
      );
      expect(report.status, PacketStatus.failed);
      expect(report.failure, PacketFailureKind.ackError);
      // The refund only lands once the relayer brings the ack home.
      expect(report.fundsRefunded, isFalse);
      expect(report.error, 'hook failed');
    });

    test('a quote inside a channel id is refused rather than escaped', () {
      expect(
        () => getPacketStatus(
          const ExtractedPacket(
            sequence: "7'",
            sourcePort: 'transfer',
            sourceChannelId: 'channel-1',
            destPort: 'transfer',
            destChannelId: '',
          ),
          _FakeLcd('cosmoshub-4', const {}),
        ),
        throwsA(isA<InterchainError>()),
      );
    });
  });

  group('trackRoute', () {
    test('an unindexed source transaction is a note, not a failure', () async {
      final trace = await trackRoute(
        _plan(),
        'AA11',
        (chainId) => _FakeLcd(chainId, const {}),
      );
      expect(trace.status, PacketStatus.pending);
      expect(trace.failure, isNull);
      expect(trace.notes.any((n) => n.contains('not indexed yet')), isTrue);
    });

    test('a plan with no hops cannot be tracked', () async {
      expect(
        () => trackRoute(
          _plan(hops: const []),
          'AA11',
          (chainId) => _FakeLcd(chainId, const {}),
        ),
        throwsA(isA<InterchainError>()
            .having((e) => e.code, 'code', InterchainErrorCode.noRoute)),
      );
    });

    test('a source chain with no endpoint fails closed with the reason',
        () async {
      expect(
        () => trackRoute(_plan(), 'AA11', (chainId) => null),
        throwsA(isA<InterchainError>().having(
            (e) => e.code, 'code', InterchainErrorCode.unsupportedChain)),
      );
    });

    test('a failure after the swap hop is recoverable, and says how', () async {
      final plan = _plan(hops: const [
        RouteHop(
          chainId: 'cosmoshub-4',
          channelId: 'channel-141',
          port: 'transfer',
          counterpartyChainId: 'osmosis-1',
          kind: RouteHopKind.transfer,
        ),
        RouteHop(
          chainId: 'osmosis-1',
          channelId: '',
          port: '',
          counterpartyChainId: 'osmosis-1',
          kind: RouteHopKind.swap,
        ),
        RouteHop(
          chainId: 'osmosis-1',
          channelId: 'channel-42',
          port: 'transfer',
          counterpartyChainId: 'juno-1',
          kind: RouteHopKind.forward,
        ),
      ]);

      LcdClient? resolve(String chainId) {
        if (chainId == 'cosmoshub-4') {
          return _FakeLcd('cosmoshub-4', {
            '/cosmos/tx/v1beta1/txs/AA11': (_) => _txResponse(events: [
                  _sendPacketEvent(
                    data: jsonEncode({'denom': 'uatom', 'amount': '1000000'}),
                  ),
                ]),
            '/cosmos/tx/v1beta1/txs': (query) {
              final q = query!['query']! as String;
              if (!q.contains('acknowledge_packet')) {
                return {'tx_responses': []};
              }
              return {
                'tx_responses': [
                  {
                    'txhash': 'ACK1',
                    'timestamp': '2026-09-06T00:01:00Z',
                    'events': [
                      {
                        'type': 'acknowledge_packet',
                        'attributes': [
                          _attr('packet_sequence', '7'),
                          _attr('packet_src_channel', 'channel-141'),
                          _attr('packet_dst_channel', 'channel-0'),
                        ],
                      },
                    ],
                  },
                ],
              };
            },
          });
        }
        return _FakeLcd(chainId, {
          '/cosmos/tx/v1beta1/txs': (query) {
            final q = query!['query']! as String;
            if (q.contains('recv_packet') && q.contains('channel-141')) {
              return {
                'tx_responses': [
                  {
                    'txhash': 'RCV1',
                    'timestamp': '2026-09-06T00:00:30Z',
                    'events': [
                      {
                        'type': 'recv_packet',
                        'attributes': [
                          _attr('packet_sequence', '7'),
                          _attr('packet_src_channel', 'channel-141'),
                          _attr('packet_dst_channel', 'channel-0'),
                        ],
                      },
                      // The contract's outbound transfer, sent from inside the
                      // same delivery.
                      _sendPacketEvent(
                        sequence: '9',
                        srcChannel: 'channel-42',
                        dstChannel: 'channel-0',
                      ),
                    ],
                  },
                ],
              };
            }
            if (q.contains('timeout_packet') && q.contains('channel-42')) {
              return {
                'tx_responses': [
                  {
                    'txhash': 'TO2',
                    'timestamp': '2026-09-06T00:20:00Z',
                    'events': [
                      {
                        'type': 'timeout_packet',
                        'attributes': [
                          _attr('packet_sequence', '9'),
                          _attr('packet_src_channel', 'channel-42'),
                          _attr('packet_dst_channel', 'channel-0'),
                        ],
                      },
                    ],
                  },
                ],
              };
            }
            return {'tx_responses': []};
          },
        });
      }

      final trace = await trackRoute(
        plan,
        'AA11',
        resolve,
        swapContract: 'osmo1xcs',
        recoveryAddress: 'osmo1recovery',
      );
      expect(trace.failure, PacketFailureKind.swapDeliveryFailed);
      expect(trace.recovery, isNotNull);
      expect(trace.recovery!.chainId, 'osmosis-1');
      expect(trace.recovery!.ready, isTrue);
      expect(trace.recovery!.executeMsg, {'recover': <String, Object?>{}});
    });

    test('recovery without a configured contract is reported as not ready',
        () {
      const recovery = XcsRecovery(
        chainId: 'osmosis-1',
        contractAddress: null,
        recoveryAddress: 'osmo1recovery',
      );
      // Fail closed: the UI must say the address is unset rather than offer a
      // button that cannot build a message.
      expect(recovery.ready, isFalse);
    });
  });
}
