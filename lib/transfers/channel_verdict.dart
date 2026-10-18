/// What a channel check means for the user who typed the channel.
///
/// Port of `zunia-extension/lib/channel-verdict.ts`. The engine's
/// `validateIbcChannel` answers in chain terms (state, counterparty status, a
/// message). Send needs one decision: may this channel carry the transfer,
/// and what must the review say about it. Pure, so every branch is tested
/// without a network.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/services/interchain/channels.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

enum ChannelVerdictKind {
  /// Open on both chains, and the far side points back at it.
  verified,

  /// Open on the source chain, but the far side did not confirm it.
  openUnconfirmed,

  /// The chain could not be asked (endpoint down, reads off). Proves nothing.
  inconclusive,

  /// A definite no: missing, not open, or connected somewhere else.
  rejected,
}

@immutable
class ChannelVerdict {
  const ChannelVerdict({required this.kind, required this.note, this.counterpartyChannelId});

  final ChannelVerdictKind kind;

  /// One sentence for the user, from the chain's own answer where possible.
  final String note;
  final String? counterpartyChannelId;
}

const ChannelMessages _messages = ChannelMessages();

ChannelVerdict classifyChannelCheck(IbcChannelCheck check, String destChainId) {
  final counterparty = (check.counterpartyChannelId ?? '').isEmpty ? null : check.counterpartyChannelId;

  if (!check.ok) {
    // Not open, wrong chain, and a far side that is missing, closed, or points
    // elsewhere all carry the state the source chain reported.
    final definite = check.state != IbcChannelState.unknown ||
        check.message == _messages.notFound ||
        check.message == _messages.emptyInput;
    return definite
        ? ChannelVerdict(kind: ChannelVerdictKind.rejected, note: check.message)
        : ChannelVerdict(
            kind: ChannelVerdictKind.inconclusive,
            note: '${check.message}. Nothing confirmed this channel.',
          );
  }

  // Only the far side itself can say it is open and points back.
  final far = check.counterparty;
  if (far != null &&
      far.status == CounterpartyCheckStatus.ok &&
      (far.chainId ?? destChainId) == destChainId) {
    return ChannelVerdict(
      kind: ChannelVerdictKind.verified,
      note: far.message.isNotEmpty ? far.message : check.message,
      counterpartyChannelId: counterparty,
    );
  }
  return ChannelVerdict(
    kind: ChannelVerdictKind.openUnconfirmed,
    note: check.counterpartyChainId == destChainId
        ? 'Open here and pointing at $destChainId, but $destChainId could not be asked to confirm it.'
        : 'Open on this chain, but nothing confirmed that it leads to $destChainId.',
    counterpartyChannelId: counterparty,
  );
}

/// A definite no is the only verdict that blocks the channel outright.
bool verdictAllowsUse(ChannelVerdict verdict) => verdict.kind != ChannelVerdictKind.rejected;
