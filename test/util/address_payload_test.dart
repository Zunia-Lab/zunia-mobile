import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/util/address_payload.dart';

/// The payment request Receive writes and Send reads:
/// `zunia://pay?chain=…&to=…&denom=…&amount=…&memo=…`.
const osmo = 'osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw';
const cosmos = 'cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu';
const usdcN = 'ibc/498A0751C798A0D9A389AA3691123DADA57DAA4FE165D5C75894505B876BA6E4';

void main() {
  group('payment requests', () {
    test('round-trip every field, percent-encoded', () {
      const request = PaymentRequest(
        address: osmo,
        chainId: 'osmosis-1',
        denom: usdcN,
        amount: '12340000',
        memo: 'Invoice #42 & co — café',
      );
      final uri = buildPaymentRequestUri(request);
      expect(uri, startsWith('zunia://pay?chain=osmosis-1&to=$osmo&denom=ibc%2F498A'));
      expect(uri, contains('memo=Invoice%20%2342%20%26%20co'));
      expect(parsePaymentRequest(uri), request);
    });

    test('write a request with only an address as the plain address', () {
      const request = PaymentRequest(address: osmo);
      expect(buildPaymentRequestUri(request), osmo);
      expect(parsePaymentRequest(osmo), request);
    });

    test('read a plain address, a cosmos: URI and an address in JSON', () {
      expect(parsePaymentRequest('  $osmo  ')?.address, osmo);
      expect(parsePaymentRequest('cosmos:$cosmos')?.address, cosmos);
      expect(parsePaymentRequest('{"address":"$cosmos"}')?.address, cosmos);
      expect(parsePaymentRequest('hello'), isNull);
      // A typo in one character fails the checksum: no address at all.
      expect(parsePaymentRequest(osmo.replaceRange(osmo.length - 1, null, 'x')), isNull);
    });

    test('name the prefix of the recipient', () {
      expect(parsePaymentRequest('zunia://pay?to=$osmo')!.prefix, 'osmo');
    });

    test('refuse malformed fields rather than dropping them', () {
      expect(() => parsePaymentRequest('zunia://pay?chain=osmosis-1'), throwsA(isA<PaymentRequestException>()));
      expect(() => parsePaymentRequest('zunia://pay?to=$osmo&denom=uosmo&amount=1.5'),
          throwsA(isA<PaymentRequestException>()));
      expect(() => parsePaymentRequest('zunia://pay?to=$osmo&amount=10'), throwsA(isA<PaymentRequestException>()));
      expect(() => parsePaymentRequest('zunia://pay?to=$osmo&denom=uosmo&amount=-3'),
          throwsA(isA<PaymentRequestException>()));
      expect(() => parsePaymentRequest('zunia://pay?to=$osmo&memo=${'x' * 257}'),
          throwsA(isA<PaymentRequestException>()));
      expect(() => parsePaymentRequest('zunia://pay?to=${osmo.toUpperCase()}'), throwsA(isA<PaymentRequestException>()));
    });

    test('drop leading zeros from an amount but never read it as a decimal', () {
      expect(parsePaymentRequest('zunia://pay?to=$osmo&denom=uosmo&amount=0012')!.amount, '12');
      expect(() => parsePaymentRequest('zunia://pay?to=$osmo&denom=uosmo&amount=0'),
          throwsA(isA<PaymentRequestException>()));
    });

    test('still give other scanners the address inside a request', () {
      expect(extractBech32Address('zunia://pay?chain=osmosis-1&to=$osmo&denom=uosmo&amount=5'), osmo);
    });
  });

  group('bech32', () {
    test('accepts a checksummed lowercase address only', () {
      expect(isValidBech32(osmo), isTrue);
      expect(isValidBech32(osmo.toUpperCase()), isFalse);
      expect(isValidBech32('osmo1abc'), isFalse);
      expect(bech32Prefix(cosmos), 'cosmos');
    });
  });
}
