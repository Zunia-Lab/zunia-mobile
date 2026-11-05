/// The default dApps on the Browser tab, read from `assets/browser/dapps.json`
/// so the list is data, not constants spread over screens.
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
    this.icon,
  });

  /// Unknown or old fields (category, description, chains) are ignored.
  factory CuratedDapp.fromJson(Map<String, dynamic> json) => CuratedDapp(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        icon: json['icon'] as String?,
      );

  final String id;
  final String name;
  final String url;

  /// Bundled asset path of the site's real icon.
  final String? icon;

  String get host => Uri.tryParse(url)?.host ?? url;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) || host.contains(q);
  }
}

@immutable
class CuratedDapps {
  const CuratedDapps({required this.dapps});

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
    return CuratedDapps(dapps: dapps);
  }

  final List<CuratedDapp> dapps;
}

Future<CuratedDapps> loadCuratedDapps({AssetBundle? bundle}) async =>
    CuratedDapps.parse(await (bundle ?? rootBundle).loadString(kCuratedDappsAsset));

final curatedDappsProvider = FutureProvider<CuratedDapps>((ref) => loadCuratedDapps());
