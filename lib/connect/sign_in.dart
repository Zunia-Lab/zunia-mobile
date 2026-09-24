/// Sign in with Zunia: a CAIP-122 message (the Cosmos form of Sign-In with
/// Ethereum) that the wallet signs with ADR-036.
///
///   app.example.com wants you to sign in with your Cosmos account:
///   cosmos1...
///
///   Optional statement.
///
///   URI: https://app.example.com
///   Version: 1
///   Chain ID: cosmoshub-4
///   Nonce: 32891756
///   Issued At: 2026-09-24T10:00:00.000Z
///   Expiration Time: 2026-09-24T10:10:00.000Z
///
/// The parser and the binding rules are the ones `@zunialab/sdk-core` and the
/// extension run. `test/fixtures/sign-in-vectors.json` keeps them identical.
library;

import 'package:zunia_mobile/connect/connect_crypto.dart';

class SignInMessage {
  const SignInMessage({
    required this.domain,
    required this.address,
    required this.uri,
    required this.chainId,
    required this.nonce,
    required this.issuedAt,
    this.statement,
    this.expirationTime,
    this.notBefore,
    this.requestId,
    this.resources,
  });

  final String domain;
  final String address;
  final String? statement;
  final String uri;
  final String chainId;
  final String nonce;
  final String issuedAt;
  final String? expirationTime;
  final String? notBefore;
  final String? requestId;
  final List<String>? resources;

  String get version => '1';

  Map<String, Object?> toJson() => {
        'domain': domain,
        'address': address,
        'statement': ?statement,
        'uri': uri,
        'version': version,
        'chainId': chainId,
        'nonce': nonce,
        'issuedAt': issuedAt,
        'expirationTime': ?expirationTime,
        'notBefore': ?notBefore,
        'requestId': ?requestId,
        'resources': ?resources,
      };
}

const kSignInMaxLength = 4096;
const kSignInMaxStatement = 512;
const kSignInMaxRequestId = 256;
const kSignInMaxResources = 32;

/// How far ahead of the wallet's clock the site's clock may run.
const kSignInClockSkew = Duration(minutes: 5);

const _header = ' wants you to sign in with your Cosmos account:';

final _domain = RegExp(
  r'^(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*)(?::\d{1,5})?$',
);
final _address = RegExp(r'^[a-z][a-z0-9]{0,40}1[02-9ac-hj-np-z]{6,100}$');
final _chainId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _nonce = RegExp(r'^[A-Za-z0-9]{8,128}$');
final _dateTime = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$',
);

/// Control, format (bidi overrides, zero-width) and line separator characters.
final _hidden = RegExp(r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', unicode: true);
final _whitespace = RegExp(r'\s');

/// True for anything that reads like a sign-in request, in any wording or line
/// ending. The wallet never signs such text as a plain message.
bool looksLikeSignIn(String text) =>
    RegExp('wants you to sign in with your', caseSensitive: false).hasMatch(text);

Never _invalid(String message) =>
    throw ConnectException('INVALID_PARAMS', message);

DateTime? _parseDate(String value) {
  final match = _dateTime.firstMatch(value);
  if (match == null) return null;
  int part(int i) => int.parse(match.group(i)!);
  final month = part(2);
  final day = part(3);
  final daysInMonth = DateTime.utc(part(1), month + 1, 0).day;
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > daysInMonth ||
      part(4) > 23 ||
      part(5) > 59 ||
      part(6) > 59) {
    return null;
  }
  if (match.group(7) != null && (part(7) > 23 || part(8) > 59)) return null;
  return DateTime.tryParse(value);
}

String _checkDate(String label, String value) {
  if (_parseDate(value) == null) {
    _invalid('$label must be an RFC 3339 date-time');
  }
  return value;
}

const _hostSchemes = {'http', 'https', 'ws', 'wss', 'ftp'};

String _checkUri(String label, String value) {
  final uri = Uri.tryParse(value);
  if (value.isEmpty ||
      _whitespace.hasMatch(value) ||
      _hidden.hasMatch(value) ||
      uri == null ||
      !uri.hasScheme ||
      (_hostSchemes.contains(uri.scheme) && uri.host.isEmpty)) {
    _invalid('$label is not a valid URI');
  }
  return value;
}

/// Reads a sign-in text, or throws `INVALID_PARAMS` naming the first problem.
SignInMessage parseSignInMessage(String text) {
  if (text.length > kSignInMaxLength) {
    _invalid('The sign-in message is too long');
  }
  final lines = text.split('\n');
  var at = 0;
  String? line(int index) => index < lines.length ? lines[index] : null;

  final header = line(at++) ?? '';
  if (!header.endsWith(_header)) {
    _invalid('Zunia signs in with Cosmos accounts only, in the CAIP-122 format');
  }
  final domain = header.substring(0, header.length - _header.length);
  if (!_domain.hasMatch(domain)) {
    _invalid('The sign-in message names an invalid domain');
  }

  final address = line(at++) ?? '';
  if (!_address.hasMatch(address)) {
    _invalid('The sign-in message names an invalid address');
  }
  if (line(at++) != '') _invalid('A blank line must follow the address');

  String? statement;
  final next = line(at);
  if (next != null && !next.startsWith('URI: ')) {
    statement = next;
    at += 1;
    if (statement.trim().isEmpty || _hidden.hasMatch(statement)) {
      _invalid('The sign-in statement must be one line of visible text');
    }
    if (statement.length > kSignInMaxStatement) {
      _invalid('The sign-in statement is too long');
    }
    if (line(at++) != '') _invalid('A blank line must follow the statement');
  }

  String field(String name) {
    final value = line(at);
    final prefix = '$name: ';
    if (value == null || !value.startsWith(prefix)) {
      _invalid('Expected "$name:" on line ${at + 1}');
    }
    at += 1;
    return value.substring(prefix.length);
  }

  String? optional(String name) =>
      (line(at)?.startsWith('$name: ') ?? false) ? field(name) : null;

  final uri = _checkUri('URI', field('URI'));
  if (field('Version') != '1') {
    _invalid('Only version 1 sign-in messages are supported');
  }
  final chainId = field('Chain ID');
  if (!_chainId.hasMatch(chainId)) {
    _invalid('The sign-in message names an invalid chain ID');
  }
  final nonce = field('Nonce');
  if (!_nonce.hasMatch(nonce)) {
    _invalid('The nonce must be 8 to 128 letters or digits');
  }
  final issuedAt = _checkDate('Issued At', field('Issued At'));

  final expirationTime = optional('Expiration Time');
  if (expirationTime != null) _checkDate('Expiration Time', expirationTime);
  final notBefore = optional('Not Before');
  if (notBefore != null) _checkDate('Not Before', notBefore);
  final requestId = optional('Request ID');
  if (requestId != null &&
      (requestId.isEmpty ||
          _hidden.hasMatch(requestId) ||
          requestId.length > kSignInMaxRequestId)) {
    _invalid('The request ID must be one line of visible text');
  }

  List<String>? resources;
  if (line(at) == 'Resources:') {
    at += 1;
    resources = [];
    while (line(at)?.startsWith('- ') ?? false) {
      resources.add(_checkUri('Resource', lines[at].substring(2)));
      at += 1;
    }
    if (resources.isEmpty) _invalid('Resources: must list at least one URI');
    if (resources.length > kSignInMaxResources) {
      _invalid('The sign-in message lists too many resources');
    }
  }

  if (at != lines.length) _invalid('Unexpected content on line ${at + 1}');

  return SignInMessage(
    domain: domain,
    address: address,
    statement: statement,
    uri: uri,
    chainId: chainId,
    nonce: nonce,
    issuedAt: issuedAt,
    expirationTime: expirationTime,
    notBefore: notBefore,
    requestId: requestId,
    resources: resources,
  );
}

String _hostOf(Uri uri) {
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host.toLowerCase();
  return uri.hasPort ? '$host:${uri.port}' : host;
}

/// `scheme://host[:port]` for http and https URLs, as a browser computes it,
/// and null for anything else.
String? webOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return '${uri.scheme}://${_hostOf(uri)}';
}

/// The host a browser shows for [origin], with the port when it is not the
/// default one, or null when [origin] is not an http or https URL.
String? webHost(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return _hostOf(uri);
}

/// The wallet-side check: refuses a sign-in that is not for the site asking,
/// the chain it asked on, or the account it asked to sign with, or whose dates
/// are out of bounds. Throws `ORIGIN_MISMATCH` or `INVALID_PARAMS`.
void checkSignInBinding(
  SignInMessage message, {
  required String origin,
  required String chainId,
  required String signer,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final host = webHost(origin);
  if (host == null) {
    throw const ConnectException(
      'ORIGIN_MISMATCH',
      'The requesting site has no usable origin',
    );
  }
  if (message.domain.toLowerCase() != host) {
    throw ConnectException(
      'ORIGIN_MISMATCH',
      'This sign-in request is for ${message.domain}, but $host sent it',
    );
  }
  if (webOrigin(message.uri) != origin) {
    throw ConnectException(
      'ORIGIN_MISMATCH',
      'The sign-in URI ${message.uri} is not on $origin',
    );
  }
  if (message.chainId != chainId) {
    _invalid(
      'The sign-in message names ${message.chainId}, but the signature was '
      'requested on $chainId',
    );
  }
  if (message.address != signer) {
    _invalid('The sign-in message names another address than the signer');
  }
  final latest = clock.add(kSignInClockSkew);
  final issuedAt = _parseDate(message.issuedAt)!;
  if (issuedAt.isAfter(latest)) {
    _invalid('The sign-in message is dated in the future');
  }
  final expirationTime = message.expirationTime;
  if (expirationTime != null) {
    final expires = _parseDate(expirationTime)!;
    if (!expires.isAfter(issuedAt)) {
      _invalid('The sign-in message expires before it was issued');
    }
    if (!expires.isAfter(clock)) _invalid('The sign-in message has expired');
  }
  final notBefore = message.notBefore;
  if (notBefore != null && _parseDate(notBefore)!.isAfter(latest)) {
    _invalid('The sign-in message is not valid yet');
  }
}
