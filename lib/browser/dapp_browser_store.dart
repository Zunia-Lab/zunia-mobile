/// Origin-scoped dApp browser permissions and recent / favorite URLs.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class BrowserBookmark {
  const BrowserBookmark({
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  factory BrowserBookmark.fromJson(Map<String, dynamic> json) =>
      BrowserBookmark(
        url: json['url'] as String,
        title: json['title'] as String? ?? json['url'] as String,
        visitedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['visitedAt'] as num?)?.toInt() ?? 0,
        ),
      );

  final String url;
  final String title;
  final DateTime visitedAt;

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'visitedAt': visitedAt.millisecondsSinceEpoch,
      };
}

class DappBrowserStore {
  DappBrowserStore._();
  static final instance = DappBrowserStore._();

  static const _kPerms = 'zunia.browser.permissions';
  static const _kRecents = 'zunia.browser.recents';
  static const _kFavorites = 'zunia.browser.favorites';

  /// origin → enabled chain ids
  Future<Map<String, List<String>>> permissions() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kPerms);
    if (raw == null || raw.isEmpty) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map(
      (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()),
    );
  }

  Future<bool> isEnabled(String origin, String chainId) async {
    final perms = await permissions();
    final chains = perms[origin];
    return chains != null && chains.contains(chainId);
  }

  Future<void> grant(String origin, List<String> chainIds) async {
    final store = await SharedPreferences.getInstance();
    final perms = await permissions();
    final existing = {...(perms[origin] ?? const <String>[])};
    existing.addAll(chainIds);
    perms[origin] = existing.toList();
    await store.setString(_kPerms, jsonEncode(perms));
  }

  Future<void> revoke(String origin) async {
    final store = await SharedPreferences.getInstance();
    final perms = await permissions();
    perms.remove(origin);
    await store.setString(_kPerms, jsonEncode(perms));
  }

  Future<List<BrowserBookmark>> recents() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kRecents);
    if (raw == null || raw.isEmpty) return <BrowserBookmark>[];
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => BrowserBookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> touchRecent({required String url, required String title}) async {
    final store = await SharedPreferences.getInstance();
    final list = await recents();
    list.removeWhere((b) => b.url == url);
    list.insert(
      0,
      BrowserBookmark(url: url, title: title, visitedAt: DateTime.now()),
    );
    final trimmed = list.take(24).toList();
    await store.setString(
      _kRecents,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<BrowserBookmark>> favorites() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kFavorites);
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => BrowserBookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> isFavorite(String url) async {
    final list = await favorites();
    return list.any((b) => b.url == url);
  }

  Future<void> toggleFavorite({
    required String url,
    required String title,
  }) async {
    final store = await SharedPreferences.getInstance();
    final list = await favorites();
    final idx = list.indexWhere((b) => b.url == url);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(
        0,
        BrowserBookmark(url: url, title: title, visitedAt: DateTime.now()),
      );
    }
    await store.setString(
      _kFavorites,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }
}

String browserOriginOf(Uri uri) {
  if (uri.hasScheme && uri.host.isNotEmpty) {
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
  return uri.toString();
}
