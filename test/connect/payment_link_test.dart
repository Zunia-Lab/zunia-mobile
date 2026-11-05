import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/connect/connect_links.dart';
import 'package:zunia_mobile/util/address_payload.dart';

void main() {
  const to = 'osmo1gv86dp8wmnmmatdckgr5xkevnpmy4662stl5rm';

  test('a zunia://pay link is a payment request, from the camera or another app', () {
    final link = buildPaymentRequestUri(
      const PaymentRequest(address: to, chainId: 'osmosis-1', denom: 'uosmo', amount: '1500000'),
    );
    for (final scanned in [true, false]) {
      final classified = classifyLink(link, scanned: scanned);
      expect(classified, isA<PaymentLink>(), reason: 'scanned: $scanned');
      final request = (classified! as PaymentLink).request;
      expect(request.address, to);
      expect(request.chainId, 'osmosis-1');
      expect(request.amount, '1500000');
    }
  });

  test('a damaged payment request says why instead of being ignored', () {
    final classified = classifyLink('zunia://pay?to=notanaddress');
    expect(classified, isA<UnsupportedLink>());
  });
}
