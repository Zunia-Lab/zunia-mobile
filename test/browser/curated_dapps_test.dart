/// The Discover list is data: it parses, every row is https and unique, and
/// the count the drawer shows is its length.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/browser/curated_dapps.dart';

void main() {
  final data = CuratedDapps.parse(File(kCuratedDappsAsset).readAsStringSync());

  test('rows are https, unique and in a listed category', () {
    expect(data.dapps, isNotEmpty);
    final ids = <String>{};
    for (final dapp in data.dapps) {
      expect(Uri.parse(dapp.url).scheme, 'https', reason: dapp.id);
      expect(ids.add(dapp.id), isTrue, reason: 'duplicate ${dapp.id}');
      expect(data.categories, contains(dapp.category), reason: dapp.id);
      expect(dapp.description, isNotEmpty, reason: dapp.id);
    }
    expect(data.featured?.id, 'osmosis');
    expect(data.usedCategories, isNotEmpty);
  });

  test('a row that is not https is dropped, never shown', () {
    final parsed = CuratedDapps.parse(
      '{"dapps":[{"id":"a","name":"A","url":"http://a.example","category":"Tools"},'
      '{"id":"b","name":"B","url":"https://b.example","category":"Tools"}],"categories":["Tools"]}',
    );
    expect(parsed.dapps.map((d) => d.id), ['b']);
    expect(parsed.featured!.id, 'b');
  });

  test('search reads name, category, description, host and chains', () {
    final osmosis = data.dapps.firstWhere((d) => d.id == 'osmosis');
    expect(osmosis.matches('osmo'), isTrue);
    expect(osmosis.matches('osmosis-1'), isTrue);
    expect(osmosis.matches('defi'), isTrue);
    expect(osmosis.matches('nothing like it'), isFalse);
  });
}
