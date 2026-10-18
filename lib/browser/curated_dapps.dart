/// The curated dApps on the Discover tab, read from
/// `assets/browser/dapps.json` so the list is data, not constants spread over
/// screens: the tab, the drawer's count and the tests all read the same file.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

const kCuratedDappsAsset = 'assets/browser/dapps.json';

@immutable
class CuratedDapp {
  const CuratedDapp({
    required this.id,
    required this.name,
    required this.url,
    required this.category,
    required this.description,
    this.chains = const [],
  });

  factory CuratedDapp.fromJson(Map<String, dynamic> json) => CuratedDapp(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        category: json['category'] as String,
        description: json['description'] as String? ?? '',
        chains: [for (final c in (json['chains'] as List? ?? const [])) '$c'],
      );

  final String id;
  final String name;
  final String url;
  final String category;
  final String description;

  /// Chains it mostly works on, for search.
  final List<String> chains;

  String get host => Uri.tryParse(url)?.host ?? url;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        category.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        host.contains(q) ||
        chains.any((c) => c.toLowerCase().contains(q));
  }
}

@immutable
class CuratedDapps {
  const CuratedDapps({required this.dapps, required this.categories, this.featuredId});

  /// Reads the file; a row whose URL is not https is dropped rather than shown.
  factory CuratedDapps.parse(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final dapps = <CuratedDapp>[];
    for (final row in (json['dapps'] as List? ?? const [])) {
      if (row is! Map<String, dynamic>) continue;
      final dapp = CuratedDapp.fromJson(row);
      if (Uri.tryParse(dapp.url)?.scheme != 'https') continue;
      dapps.add(dapp);
    }
    return CuratedDapps(
      dapps: dapps,
      categories: [for (final c in (json['categories'] as List? ?? const [])) '$c'],
      featuredId: json['featured'] as String?,
    );
  }

  final List<CuratedDapp> dapps;
  final List<String> categories;
  final String? featuredId;

  CuratedDapp? get featured {
    for (final d in dapps) {
      if (d.id == featuredId) return d;
    }
    return dapps.isEmpty ? null : dapps.first;
  }

  /// Categories that have at least one dApp, in the file's order.
  List<String> get usedCategories =>
      [for (final c in categories) if (dapps.any((d) => d.category == c)) c];
}

Future<CuratedDapps> loadCuratedDapps({AssetBundle? bundle}) async =>
    CuratedDapps.parse(await (bundle ?? rootBundle).loadString(kCuratedDappsAsset));

final curatedDappsProvider = FutureProvider<CuratedDapps>((ref) => loadCuratedDapps());
