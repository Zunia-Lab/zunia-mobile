/// The one HTTP transport that talks to NFT metadata hosts.
///
/// `nft.dart` deliberately has no default transport: without one it cannot leak
/// anything, and the caller has to hand a fetcher in. This is that fetcher, and
/// it is the host's job — as the engine's doc comment says — to own the
/// timeout, the redirect policy and the response size limit, because a metadata
/// host is a stranger's server chosen by whoever minted the token and it can
/// serve a gigabyte, a redirect chain, or a slow trickle that never ends.
///
/// It is built only when both `liveReads` and `nftMedia` are on. See
/// `state/nft.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';

/// Whole-request budget. A metadata document is a few kilobytes of JSON; a host
/// that cannot serve that in eight seconds is not one to wait on.
const Duration kNftMetadataTimeout = Duration(seconds: 8);

/// Hard ceiling on a metadata body.
///
/// 512 KiB is far more than any real `token_uri` document and small enough that
/// a hostile host cannot use the wallet's memory as a weapon. The read is
/// aborted the moment the limit is passed, not after the body is buffered.
const int kNftMetadataMaxBytes = 512 * 1024;

/// Redirects followed before giving up. Metadata hosts and IPFS gateways
/// legitimately redirect once or twice; a longer chain is a tarpit.
const int kNftMetadataMaxRedirects = 3;

/// Build a fetcher, or return null when metadata must not be fetched at all.
///
/// Null is not a failure mode to paper over: `fetchNftMetadata` turns a missing
/// fetcher into `readsDisabled`, which the screens render as "artwork is off"
/// with the switch next to it.
NftMetadataFetcher? createNftMetadataFetcher({
  required bool liveReads,
  required bool mediaEnabled,
  Duration timeout = kNftMetadataTimeout,
  int maxBytes = kNftMetadataMaxBytes,
}) {
  if (!liveReads || !mediaEnabled) return null;
  return (url) => _read(url, timeout: timeout, maxBytes: maxBytes);
}

Future<Object?> _read(
  String url, {
  required Duration timeout,
  required int maxBytes,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      'Not a usable metadata URL: $url',
    );
  }
  // https only. `resolveTokenUri` already refuses plain http unless the host
  // opted in, and this build does not, so anything else here is a bug or a
  // hostile redirect target.
  if (uri.scheme != 'https') {
    throw InterchainError(
      InterchainErrorCode.malformedResponse,
      'Refusing a non-https metadata URL: $url',
      endpoint: url,
    );
  }

  final client = HttpClient()
    ..connectionTimeout = timeout
    // Cookies would let a metadata host correlate one wallet's reads across
    // every token it serves.
    ..userAgent = null;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    request.maxRedirects = kNftMetadataMaxRedirects;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw InterchainError(
        InterchainErrorCode.lcdUnreachable,
        'Metadata host answered HTTP ${response.statusCode}',
        endpoint: url,
        httpStatus: response.statusCode,
      );
    }
    // Content-Length is a hint from an untrusted host, so it is used to fail
    // early and never trusted in place of counting the bytes below.
    if (response.contentLength > maxBytes) {
      throw InterchainError(
        InterchainErrorCode.malformedResponse,
        'Metadata document declares ${response.contentLength} bytes, over the '
        '$maxBytes byte limit',
        endpoint: url,
      );
    }

    final buffer = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      buffer.addAll(chunk);
      if (buffer.length > maxBytes) {
        throw InterchainError(
          InterchainErrorCode.malformedResponse,
          'Metadata document is over the $maxBytes byte limit',
          endpoint: url,
        );
      }
    }

    try {
      return jsonDecode(utf8.decode(buffer));
    } on FormatException catch (error) {
      throw InterchainError(
        InterchainErrorCode.malformedResponse,
        'Metadata host did not answer with JSON',
        endpoint: url,
        cause: error,
      );
    }
  } on TimeoutException catch (error) {
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'Metadata host did not answer within ${timeout.inSeconds}s',
      endpoint: url,
      cause: error,
    );
  } on IOException catch (error) {
    throw InterchainError(
      InterchainErrorCode.lcdUnreachable,
      'Could not reach the metadata host',
      endpoint: url,
      cause: error,
    );
  } finally {
    client.close(force: true);
  }
}
