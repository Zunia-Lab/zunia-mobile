/// The default dApp list is data: exactly four https rows with bundled icons.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/curated_dapps.dart';

void main() {
  final data = CuratedDapps.parse(File(kCuratedDappsAsset).readAsStringSync());

  test('exactly the four defaults, https, with existing icon assets', () {
    expect(data.dapps.map((d) => d.url), [
      'https://hub.safrochain.com',
      'https://app.osmosis.zone',
      'https://www.mintscan.io',
      'https://ibcmap.zunialab.com',
    ]);
    expect(data.dapps.map((d) => d.name), ['Safrochain Hub', 'Osmosis', 'Mintscan', 'Zunia IBC Map']);
    final ids = <String>{};
    for (final dapp in data.dapps) {
      expect(ids.add(dapp.id), isTrue, reason: 'duplicate ${dapp.id}');
      expect(dapp.icon, isNotNull, reason: dapp.id);
      expect(File(dapp.icon!).existsSync(), isTrue, reason: dapp.icon);
    }
  });

  test('a row that is not https is dropped; old fields are tolerated', () {
    final parsed = CuratedDapps.parse(
      '{"featured":"b","categories":["Tools"],"dapps":[{"id":"a","name":"A","url":"http://a.example","category":"Tools"},'
      '{"id":"b","name":"B","url":"https://b.example","category":"Tools","description":"x"}]}',
    );
    expect(parsed.dapps.map((d) => d.id), ['b']);
  });

  test('search reads name and host', () {
    final osmosis = data.dapps.firstWhere((d) => d.id == 'osmosis');
    expect(osmosis.matches('osmo'), isTrue);
    expect(osmosis.matches('zone'), isTrue);
    expect(osmosis.matches('nothing like it'), isFalse);
  });
}
