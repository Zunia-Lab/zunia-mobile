/// What a scanned or pasted code asks the wallet to pay, and how Receive
/// writes one.
///
/// A payment request is a URI:
///
/// ```
/// zunia://pay?chain=<chain id>&to=<bech32 address>&denom=<bank denom>&amount=<base units>&memo=<text>
/// ```
///
/// Only `to` is required. `amount` is in base units of `denom` (an integer
/// string, never a decimal, so no exponent is assumed), `denom` is the exact
/// bank denom on `chain`, and `memo` is at most 256 characters. Every value is
/// percent-encoded. A plain bech32 address, a `cosmos:<address>` URI or a
/// JSON `{"address": …}` reads as a request with only the address.
///
/// Nothing in a request is trusted: Send shows every field for review, checks
/// the address against the chain's prefix and the amount against the balance,
/// and never signs from a scan alone.
library;

import 'dart:convert';

import 'package:bech32/bech32.dart';
import 'package:flutter/foundation.dart';

/// The scheme and host Receive writes.
const String paymentRequestScheme = 'zunia';
const String paymentRequestHost = 'pay';

/// Longest memo a request may carry: the chain's own limit is larger, but a
/// memo is part of what the user reviews, and 256 is what Send allows.
const int maxRequestMemoLength = 256;

/// One request, as read. Fields the code did not carry are null.
@immutable
class PaymentRequest {
  const PaymentRequest({
    required this.address,
    this.chainId,
    this.denom,
    this.amount,
    this.memo,
  });

  /// The recipient: a lowercase bech32 address with a valid checksum.
  final String address;
  final String? chainId;

  /// Exact bank denom on [chainId].
  final String? denom;

  /// Base units of [denom], a positive integer string.
  final String? amount;
  final String? memo;

  /// The bech32 prefix of [address] (`osmo`, `cosmos`).
  String get prefix => bech32Prefix(address) ?? '';

  bool get hasDetails => chainId != null || denom != null || amount != null || memo != null;

  @override
  bool operator ==(Object other) =>
      other is PaymentRequest &&
      other.address == address &&
      other.chainId == chainId &&
      other.denom == denom &&
      other.amount == amount &&
      other.memo == memo;

  @override
  int get hashCode => Object.hash(address, chainId, denom, amount, memo);

  @override
  String toString() => buildPaymentRequestUri(this);
}

/// The URI for a request. A request with only an address is written as the
/// plain address, which every wallet and scanner reads.
String buildPaymentRequestUri(PaymentRequest request) {
  if (!request.hasDetails) return request.address;
  final params = <String, String>{
    if (request.chainId != null) 'chain': request.chainId!,
    'to': request.address,
    if (request.denom != null) 'denom': request.denom!,
    if (request.amount != null) 'amount': request.amount!,
    if (request.memo != null && request.memo!.isNotEmpty) 'memo': request.memo!,
  };
  final query = params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  return '$paymentRequestScheme://$paymentRequestHost?$query';
}

/// Why a code could not be read as a payment request.
class PaymentRequestException implements Exception {
  const PaymentRequestException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _positiveInteger = RegExp(r'^[0-9]*[1-9][0-9]*$');
final RegExp _chainIdShape = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final RegExp _denomShape = RegExp(r'^[A-Za-z][A-Za-z0-9/:._-]{1,127}$');

/// Reads a scanned or pasted code. Null when it holds no address at all;
/// throws [PaymentRequestException] when it is a `zunia://pay` request whose
/// fields are malformed, so the screen can say what is wrong with it instead
/// of quietly dropping a field the sender meant to set.
PaymentRequest? parsePaymentRequest(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && uri.scheme == paymentRequestScheme && uri.host == paymentRequestHost) {
    return _parseZuniaPay(uri);
  }
  final address = addressFromMaybeJson(value);
  return address == null || !isValidBech32(address) ? null : PaymentRequest(address: address);
}

PaymentRequest _parseZuniaPay(Uri uri) {
  final params = uri.queryParameters;
  final to = params['to']?.trim() ?? '';
  if (!isValidBech32(to)) {
    throw const PaymentRequestException('The request has no valid recipient address.');
  }
  final chainId = params['chain']?.trim();
  if (chainId != null && chainId.isNotEmpty && !_chainIdShape.hasMatch(chainId)) {
    throw const PaymentRequestException('The request names a chain id Zunia cannot read.');
  }
  final denom = params['denom']?.trim();
  if (denom != null && denom.isNotEmpty && !_denomShape.hasMatch(denom)) {
    throw const PaymentRequestException('The request names a token Zunia cannot read.');
  }
  final amount = params['amount']?.trim();
  if (amount != null && amount.isNotEmpty) {
    if (!_positiveInteger.hasMatch(amount)) {
      throw const PaymentRequestException(
        'The request amount is not a whole number of base units.',
      );
    }
    if (denom == null || denom.isEmpty) {
      throw const PaymentRequestException('The request has an amount but no token.');
    }
  }
  final memo = params['memo'];
  if (memo != null && memo.length > maxRequestMemoLength) {
    throw const PaymentRequestException('The request memo is longer than 256 characters.');
  }
  return PaymentRequest(
    address: to,
    chainId: chainId == null || chainId.isEmpty ? null : chainId,
    denom: denom == null || denom.isEmpty ? null : denom,
    amount: amount == null || amount.isEmpty ? null : BigInt.parse(amount).toString(),
    memo: memo == null || memo.isEmpty ? null : memo,
  );
}

/// The prefix of a valid bech32 address, or null.
String? bech32Prefix(String address) {
  try {
    return const Bech32Codec().decode(address, address.length < 90 ? 90 : address.length).hrp;
  } on Object {
    return null;
  }
}

/// A lowercase bech32 address with a valid checksum.
bool isValidBech32(String address) {
  final value = address.trim();
  if (value.isEmpty || value != value.toLowerCase()) return false;
  if (!RegExp(r'1[02-9ac-hj-np-z]{20,}$').hasMatch(value)) return false;
  return bech32Prefix(value) != null;
}

/// Pull a bech32 address out of a QR payload (plain or cosmos: URI).
String? extractBech32Address(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (_looksBech32(value)) return value;

  if (value.contains(':')) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.scheme == paymentRequestScheme && uri.host == paymentRequestHost) {
      final to = uri.queryParameters['to']?.trim();
      if (to != null && _looksBech32(to)) return to;
    }
    final after = value.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:'), '');
    final candidate = after.split(RegExp(r'[/?#\s]')).first;
    if (_looksBech32(candidate)) return candidate;
    for (final part in after.split('/')) {
      if (_looksBech32(part)) return part;
    }
  }

  final match = RegExp(r'\b([a-z]{2,16}1[0-9a-z]{20,})\b', caseSensitive: false)
      .firstMatch(value);
  if (match != null && _looksBech32(match.group(1)!)) return match.group(1);
  return null;
}

bool _looksBech32(String value) {
  // Lightweight shape check; full HRP decode happens at the form layer.
  return RegExp(r'^[a-z]{2,16}1[0-9a-z]{20,}$').hasMatch(value.toLowerCase());
}

String? addressFromMaybeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['address'] is String) {
      return extractBech32Address(decoded['address'] as String);
    }
  } catch (_) {}
  return extractBech32Address(raw);
}
