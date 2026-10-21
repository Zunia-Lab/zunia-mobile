/// Bookmarks and recently visited pages of the in-app browser. Local to the
/// device, never synced. Which sites may see which chains lives in
/// `site_grants.dart`.
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

  String get host => Uri.tryParse(url)?.host ?? url;

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'visitedAt': visitedAt.millisecondsSinceEpoch,
      };
}

class DappBrowserStore {
  DappBrowserStore._();
  static final instance = DappBrowserStore._();

  static const _kRecents = 'zunia.browser.recents';

  /// The key predates the word "bookmarks" in the UI; kept so nothing saved is lost.
  static const _kBookmarks = 'zunia.browser.favorites';

  static const _maxRecents = 24;

  Future<List<BrowserBookmark>> _read(String key) async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(key);
    if (raw == null || raw.isEmpty) return <BrowserBookmark>[];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(BrowserBookmark.fromJson)
          .toList();
    } on FormatException {
      return <BrowserBookmark>[];
    }
  }

  Future<void> _write(String key, List<BrowserBookmark> rows) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(key, jsonEncode(rows.map((e) => e.toJson()).toList()));
  }

  Future<List<BrowserBookmark>> recents() => _read(_kRecents);

  /// Only https pages are remembered: an http or data: page is never a place
  /// to come back to with a wallet.
  Future<void> touchRecent({required String url, required String title}) async {
    if (Uri.tryParse(url)?.scheme != 'https') return;
    final list = await recents();
    list.removeWhere((b) => b.url == url);
    list.insert(0, BrowserBookmark(url: url, title: title, visitedAt: DateTime.now()));
    await _write(_kRecents, list.take(_maxRecents).toList());
  }

  Future<void> removeRecent(String url) async {
    final list = await recents();
    list.removeWhere((b) => b.url == url);
    await _write(_kRecents, list);
  }

  Future<void> clearRecents() => _write(_kRecents, const []);

  Future<List<BrowserBookmark>> bookmarks() => _read(_kBookmarks);

  Future<bool> isBookmarked(String url) async =>
      (await bookmarks()).any((b) => b.url == url);

  /// Adds the page, or removes it when it is already saved. Returns whether it
  /// is saved now.
  Future<bool> toggleBookmark({required String url, required String title}) async {
    final list = await bookmarks();
    final index = list.indexWhere((b) => b.url == url);
    if (index >= 0) {
      list.removeAt(index);
    } else {
      list.insert(0, BrowserBookmark(url: url, title: title, visitedAt: DateTime.now()));
    }
    await _write(_kBookmarks, list);
    return index < 0;
  }

  Future<void> removeBookmark(String url) async {
    final list = await bookmarks();
    list.removeWhere((b) => b.url == url);
    await _write(_kBookmarks, list);
  }
}

/// `scheme://host[:port]` as a browser computes an origin, or the input when
/// it has none.
String browserOriginOf(Uri uri) {
  if (uri.hasScheme && uri.host.isNotEmpty) {
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://$host$port';
  }
  return uri.toString();
}
