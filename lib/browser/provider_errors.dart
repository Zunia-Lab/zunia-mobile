/// Codes a page can branch on, the same eight the extension's provider uses
/// (zunia-extension/lib/provider-errors.ts). The message keeps Keplr's wording
/// where Keplr has one ("Request rejected", "Not authorized") so dApps that
/// match on text keep working in the in-app browser too.
library;

import 'package:zunia_mobile/connect/connect_crypto.dart';

abstract final class ProviderErrorCode {
  /// The user said no, closed the prompt, or let it expire.
  static const userRejected = 'USER_REJECTED';

  /// The site has no live grant for that chain.
  static const notConnected = 'NOT_CONNECTED';

  /// The wallet is locked and was not unlocked in time.
  static const locked = 'LOCKED';

  /// The chain is not in the wallet.
  static const unknownChain = 'UNKNOWN_CHAIN';

  /// The request does not come from the site it names.
  static const originMismatch = 'ORIGIN_MISMATCH';

  /// The method exists but Zunia will not do it.
  static const unsupported = 'UNSUPPORTED';

  /// Missing or malformed arguments, or a signer that is not the active account.
  static const invalidParams = 'INVALID_PARAMS';

  /// Anything else.
  static const internal = 'INTERNAL';

  static const all = <String>{
    userRejected,
    notConnected,
    locked,
    unknownChain,
    originMismatch,
    unsupported,
    invalidParams,
    internal,
  };
}

class ProviderError implements Exception {
  const ProviderError(this.code, this.message);

  const ProviderError.rejected([this.message = 'Request rejected'])
      : code = ProviderErrorCode.userRejected;

  const ProviderError.invalid(this.message)
      : code = ProviderErrorCode.invalidParams;

  final String code;
  final String message;

  /// What crosses into the page: the page rebuilds a `ZuniaProviderError`.
  Map<String, Object?> toWire() => {'error': message, 'code': code};

  @override
  String toString() => message;
}

/// Any failure as a [ProviderError]. A [ConnectException] (the sign-in and
/// sign-doc checks shared with Zunia Connect) keeps its code; anything else is
/// INTERNAL with its message, never a stack trace.
ProviderError asProviderError(Object error) {
  if (error is ProviderError) return error;
  if (error is ConnectException) {
    final code = ProviderErrorCode.all.contains(error.code)
        ? error.code
        : ProviderErrorCode.internal;
    return ProviderError(code, error.message);
  }
  final text = error.toString().replaceFirst(RegExp(r'^(Exception|Bad state|StateError): '), '');
  return ProviderError(ProviderErrorCode.internal, text.isEmpty ? 'Something went wrong' : text);
}
