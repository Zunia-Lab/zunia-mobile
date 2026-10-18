/// Where the packets of a past transaction went, read without a route plan:
/// for a transfer opened from the history.
///
/// Port of `walkSentPackets` in `zunia-extension/lib/packet-tracking.ts`.
/// Each packet's first hop is always read; a packet whose memo asks
/// packet-forward middleware to send it on is followed across each forward,
/// matched on the memo's channel and then the amount. A contract call such as
/// a swap is not followed: what it sends next is not in the packet.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/tracking.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

@immutable
class WalkedHop {
  const WalkedHop({
    required this.chainId,
    required this.counterpartyChainId,
    required this.channelId,
    required this.port,
    required this.status,
    this.sequence,
    this.sendTxHash,
    this.receiveTxHash,
    this.error,
  });

  final String chainId;
  final String? counterpartyChainId;
  final String channelId;
  final String port;
  final PacketStatus status;
  final String? sequence;
  final String? sendTxHash;
  final String? receiveTxHash;
  final String? error;
}

@immutable
class PacketWalk {
  const PacketWalk({required this.hops, required this.failure, required this.settled});

  final List<WalkedHop> hops;
  final PacketFailureKind? failure;

  /// No hop can change any more.
  final bool settled;
}

const int _maxWalkPackets = 3;
const int _maxWalkForwards = 3;

/// The channel a packet-forward memo sends the packet on next, or null.
String? forwardChannelOf(String? memo) {
  if (memo == null || memo.isEmpty) return null;
  try {
    final parsed = jsonDecode(memo);
    final forward = parsed is Map ? parsed['forward'] : null;
    final channel = forward is Map ? forward['channel'] : null;
    return channel is String && channel.isNotEmpty ? channel : null;
  } on FormatException {
    return null;
  }
}

/// Follow the packets [txHash] sent on [chainId].
Future<PacketWalk> walkSentPackets({
  required String chainId,
  required String txHash,
  required List<ExtractedPacket> packets,
  required IbcChannelService channels,
  required LcdResolver resolve,
}) async {
  final hops = <WalkedHop>[];
  PacketFailureKind? failure;
  var open = false;

  for (final root in packets.take(_maxWalkPackets)) {
    var hopChain = chainId;
    var channelId = root.sourceChannelId;
    var port = root.sourcePort;
    ExtractedPacket? packet = root;
    String? sendTxHash = txHash;

    for (var depth = 0; depth <= _maxWalkForwards; depth++) {
      final check = await channels.validateIbcChannel(hopChain, channelId, portId: port);
      final counterparty = check.counterpartyChainId;
      final source = resolve(hopChain);
      if (packet == null || source == null) {
        hops.add(WalkedHop(
          chainId: hopChain,
          counterpartyChainId: counterparty,
          channelId: channelId,
          port: port,
          status: packet == null ? PacketStatus.pending : PacketStatus.unknown,
          sendTxHash: sendTxHash,
        ));
        open = true;
        break;
      }
      final report = await getPacketStatus(
        packet,
        source,
        destination: counterparty == null ? null : resolve(counterparty),
      );
      hops.add(WalkedHop(
        chainId: hopChain,
        counterpartyChainId: counterparty,
        channelId: channelId,
        port: port,
        status: report.status,
        sequence: packet.sequence,
        sendTxHash: sendTxHash,
        receiveTxHash: report.receiveTxHash,
        error: report.error,
      ));
      if (report.failure != null) {
        failure ??= report.failure;
        break;
      }
      if (!isTerminalPacketStatus(report.status)) open = true;

      final nextChannel = forwardChannelOf(packet.data?.memo);
      if (nextChannel == null || counterparty == null || resolve(counterparty) == null) break;
      final amount = packet.data?.amount;
      final onward = [
        for (final candidate in report.onwardPackets)
          if (candidate.sourceChannelId == nextChannel) candidate,
      ];
      final next = onward.length == 1
          ? onward.first
          : onward.where((candidate) => candidate.data?.amount == amount).firstOrNull;
      hopChain = counterparty;
      channelId = nextChannel;
      port = next?.sourcePort ?? transferPort;
      sendTxHash = report.receiveTxHash;
      packet = next;
    }
  }
  return PacketWalk(hops: hops, failure: failure, settled: failure != null || !open);
}
