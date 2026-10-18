/// What a Send moves, and what the recipient ends up holding.
///
/// Port of `zunia-extension/lib/send-arrival.ts` (0.1.5). For a transfer to
/// another chain the review says what lands there. That is where wallets
/// mislead: Noble USDC held on Injective and sent straight to Osmosis does not
/// arrive as Osmosis's USDC.n (`ibc/498A…`) but as a voucher of a voucher,
/// which no registry names and few apps accept. [sendArrival] says which case
/// a plan is, works the denom out again from the token's own hash-checked
/// trace, and never states a denom the route plan could not compute.
///
/// Display only. Nothing here builds or changes a signed denom, amount,
/// channel or memo.
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/services/interchain/route.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/tokens/token_amount.dart';
import 'package:zunia_mobile/tokens/token_identity.dart';
import 'package:zunia_mobile/tokens/token_registry.dart';
import 'package:zunia_mobile/transfers/route_plan.dart';

/// A pending transfer's label, as Activity and the arrival notice show it:
/// `10 USDC.n (Osmosis) → Noble`.
String transferLabel(Object units, TokenIdentity sent, String destChainName) {
  final amount = formatTokenAmount(units, AmountScale.of(sent), TokenAmountVariant.history);
  return '$amount ${sent.ticker} (${sent.heldOnChainName}) → $destChainName';
}

/// Pins with the registry's far end added where the registry names the channel
/// and the pin carries none, so the planner can compute what a wrapped token
/// arrives as. Nothing signed changes: the message carries the leaving channel.
List<ManualChannel> withRegistryEnds(List<ManualChannel> pins) => [
      for (final pin in pins)
        if ((pin.counterpartyChannelId ?? '').isNotEmpty ||
            (pin.port != null && pin.port != transferPort))
          pin
        else if (TokenRegistry.instance?.canonicalFarEnd(pin.fromChainId, pin.toChainId, pin.channelId)
            case final far?)
          pin.withCounterparty(far)
        else
          pin,
    ];

/// The engine's note on a channel it was told to use.
const String engineEnteredByHand = 'was entered by hand and has not been checked';

/// A plan's notes as Send shows them: the engine reads every pin as a channel
/// typed by hand that nobody checked, which is wrong for the screen's own pin
/// (the plan has just checked it on both chains). Those notes are dropped;
/// notes for a leg the user entered are kept.
List<String> routeNotes(
  List<String> warnings,
  List<ManualChannel> screenPins,
  List<ManualChannel> userPins,
  String Function(String chainId) chainName,
) {
  String leg(ManualChannel pin) => '${pin.fromChainId}>${pin.toChainId}';
  final typed = {for (final pin in userPins) leg(pin)};
  final own = <String>{};
  for (final pin in screenPins) {
    if (typed.contains(leg(pin))) continue;
    for (final name in {chainName(pin.fromChainId), pin.fromChainId}) {
      own.add('${pin.channelId} on $name $engineEnteredByHand');
    }
  }
  return [for (final note in warnings) if (!own.contains(note)) note];
}

/// The engine's words when it could not compute the denom a transfer arrives as.
const String engineUncomputedOutput = 'The denom the recipient ends up with could not be computed';

/// The engine's words for a plan that sends a voucher onward instead of unwinding it.
const String engineDoubleWrap = 'This sends a wrapped token onward instead of unwinding it';

/// - `native`: the token goes home and arrives as its issuer's own denom.
/// - `named`: it arrives as the voucher the destination knows the asset by.
/// - `rewrapped`: a voucher sent onward instead of home, wrapped twice.
/// - `unnamed`: wrapped once, as a voucher nothing names yet.
/// - `unknown`: the plan could not compute the denom. Nothing is stated.
enum ArrivalKind { native, named, rewrapped, unnamed, unknown }

@immutable
class ArrivalWarning {
  const ArrivalWarning({required this.title, required this.body});
  final String title;
  final String body;
}

@immutable
class SendArrival {
  const SendArrival({
    required this.kind,
    required this.denom,
    required this.identity,
    required this.listedDenom,
    required this.text,
    required this.warning,
  });

  final ArrivalKind kind;

  /// The exact denom the recipient ends up holding; null when not computed.
  final String? denom;
  final TokenIdentity? identity;

  /// The denom the destination knows the sent asset by, when the registry gives one.
  final String? listedDenom;

  /// The "Arrives as" value: `USDC.n · Native on Noble`.
  final String text;
  final ArrivalWarning? warning;
}

typedef _Trace = ({String path, String base});

bool _sameDenom(String a, String b) => denomKey(a) == denomKey(b);

final RegExp _packetPath = RegExp(r'^[^/]+/(?:channel-\d+|\d{2}-[a-z][a-z0-9]*-\d+)/');

List<({String port, String channel})> _splitHops(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  return [
    for (var i = 0; i + 1 < parts.length; i += 2) (port: parts[i], channel: parts[i + 1]),
  ];
}

String _joinHops(List<({String port, String channel})> hops) =>
    hops.map((hop) => '${hop.port}/${hop.channel}').join('/');

_Trace? _traceOf(TokenIdentity identity) {
  final denom = identity.denom;
  if (!isIbcDenom(denom)) return _packetPath.hasMatch(denom) ? null : (path: '', base: denom);
  final candidates = <_Trace>[
    if (identity.path.isNotEmpty && identity.originDenom != null)
      (path: identity.path, base: identity.originDenom!),
    for (final row in tokenTableRows(identity.heldOnChainId))
      if (row.path.isNotEmpty && row.baseDenom.isNotEmpty && _sameDenom(row.denom, denom))
        (path: row.path, base: row.baseDenom),
  ];
  for (final trace in candidates) {
    if (_sameDenom(ibcDenomFor(trace.path, trace.base), denom)) return trace;
  }
  return null;
}

_Trace? _stepTrace(_Trace trace, ChannelLink link) {
  final port = link.port ?? transferPort;
  final hops = _splitHops(trace.path);
  if (hops.isNotEmpty && hops.first.port == port && hops.first.channel == link.channelId) {
    return (path: _joinHops(hops.sublist(1)), base: trace.base);
  }
  final far = link.counterpartyChannelId;
  if (far == null || far.isEmpty) return null;
  return (
    path: _joinHops([(port: link.counterpartyPortId ?? transferPort, channel: far), ...hops]),
    base: trace.base,
  );
}

String _denomOfTrace(_Trace trace) =>
    trace.path.isNotEmpty ? ibcDenomFor(trace.path, trace.base) : trace.base;

String? _listedDenomOn(String destChainId, TokenIdentity sent) {
  final origin = sent.originChainId;
  final originDenom = sent.originDenom;
  if (sent.provenance == TokenProvenance.unknown || !sent.proven || origin == null || originDenom == null) {
    return null;
  }
  if (origin == destChainId) return originDenom;
  if (destChainId == osmosisChainId) return sent.osmosisDenom;
  ({String denom, int hops})? best;
  for (final row in tokenTableRows(destChainId)) {
    if (row.path.isEmpty) continue;
    final listed = identityOf(destChainId, row.denom);
    if (!listed.proven || listed.originChainId != origin || listed.originDenom != originDenom) continue;
    final hops = _splitHops(row.path).length;
    if (best == null || hops < best.hops) best = (denom: row.denom, hops: hops);
  }
  return best?.denom;
}

/// What a transfer of [sent] delivers on [destChainId], from its route plan.
SendArrival sendArrival({
  required String sourceChainId,
  required String inputDenom,
  required String destChainId,
  required String outputDenom,
  required String destChainName,
  List<String> warnings = const [],
  List<ChannelLink> links = const [],
  TokenIdentity? sent,
}) {
  final token = sent != null && sent.heldOnChainId == sourceChainId && _sameDenom(sent.denom, inputDenom)
      ? sent
      : identityOf(sourceChainId, inputDenom);
  final listedDenom = _listedDenomOn(destChainId, token);

  final engineGaveUp = warnings.any((warning) => warning.startsWith(engineUncomputedOutput));
  String? denom;
  String? path;
  var disagrees = false;
  var trace = links.isNotEmpty ? _traceOf(token) : null;
  for (final link in links) {
    if (trace == null) break;
    trace = _stepTrace(trace, link);
  }
  if (trace != null) {
    final ours = _denomOfTrace(trace);
    if (!engineGaveUp && !_sameDenom(ours, outputDenom)) {
      disagrees = true;
    } else {
      denom = ours;
      path = trace.path;
    }
  } else if (!engineGaveUp) {
    denom = outputDenom;
  }

  if (denom == null) {
    return SendArrival(
      kind: ArrivalKind.unknown,
      denom: null,
      identity: null,
      listedDenom: listedDenom,
      text: 'Could not be computed',
      warning: ArrivalWarning(
        title: 'Arrival not known',
        body: disagrees
            ? "The route plan and Zunia's own check disagree on the denom this becomes on "
                '$destChainName, so neither is shown. It may arrive as a token no registry names.'
            : 'Zunia could not work out the denom this becomes on $destChainName. It may arrive '
                'as a token no registry names.',
      ),
    );
  }

  final identity = identityOf(destChainId, denom);
  String namedText(TokenIdentity id) => '${id.ticker} · ${tokenText(id, TokenTextVariant.row)}';

  if (!isIbcDenom(denom)) {
    return SendArrival(
      kind: ArrivalKind.native,
      denom: denom,
      identity: identity,
      listedDenom: listedDenom,
      text: namedText(identity),
      warning: null,
    );
  }

  final named = token.provenance != TokenProvenance.unknown;
  final asset = named ? token.ticker : 'voucher';
  final listedIsDelivered = listedDenom != null && _sameDenom(listedDenom, denom);
  final registryNames = identity.proven &&
      (identity.provenance == TokenProvenance.table || identity.provenance == TokenProvenance.catalog);
  if (listedIsDelivered || registryNames) {
    return SendArrival(
      kind: ArrivalKind.named,
      denom: denom,
      identity: identity,
      listedDenom: listedDenom,
      text: namedText(identity),
      warning: null,
    );
  }

  final hops = path == null ? null : _splitHops(path).length;
  final doubled = hops != null ? hops >= 2 : warnings.any((w) => w.startsWith(engineDoubleWrap));
  final known = listedDenom != null && named
      ? '$destChainName lists ${token.ticker} as ${shortDenom(listedDenom)}. '
      : '';
  final origin = token.originChainId;
  final home = named && origin != null && origin != sourceChainId
      ? origin == destChainId
          ? ''
          : ' To receive ${token.ticker} on $destChainName, send it to '
              '${token.originChainName ?? origin} first.'
      : '';

  if (doubled) {
    return SendArrival(
      kind: ArrivalKind.rewrapped,
      denom: denom,
      identity: identity,
      listedDenom: listedDenom,
      text: 'Re-wrapped $asset · on $destChainName',
      warning: ArrivalWarning(
        title: 'Arrives as a different token',
        body: '${known}Sent this way it arrives as ${shortDenom(denom)}, a re-wrapped voucher that '
            'no registry names, so wallets and apps may not accept it.$home',
      ),
    );
  }

  if (listedDenom == null && identity.proven) {
    return SendArrival(
      kind: ArrivalKind.named,
      denom: denom,
      identity: identity,
      listedDenom: listedDenom,
      text: namedText(identity),
      warning: null,
    );
  }
  return SendArrival(
    kind: ArrivalKind.unnamed,
    denom: denom,
    identity: identity,
    listedDenom: listedDenom,
    text: named ? '${token.ticker} voucher · on $destChainName' : 'Unnamed voucher · on $destChainName',
    warning: listedDenom != null && named
        ? ArrivalWarning(
            title: 'Arrives as a different token',
            body: '${known}This route delivers ${shortDenom(denom)} instead, a voucher that no '
                'registry names, so wallets and apps may not accept it.',
          )
        : null,
  );
}
