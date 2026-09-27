import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Keybase avatar lookup, matching TheHub's `validatorAvatarCache.ts`.
class ValidatorAvatarResolver {
  ValidatorAvatarResolver._();

  static const _cachePrefix = 'validator_avatar_';
  static const _hitTtl = Duration(days: 7);
  static const _missTtl = Duration(hours: 1);
  static const _lookup =
      'https://keybase.io/_/api/1.0/user/lookup.json';

  static final _memory = <String, _Entry>{};

  static bool isValidKeySuffix(String identity) {
    final s = identity.trim();
    if (s.length < 8 || s.length > 64) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
  }

  static Future<String?> resolveOne(String identity) async {
    final trimmed = identity.trim();
    if (!isValidKeySuffix(trimmed)) return null;

    final cached = await _peek(trimmed);
    if (cached != null) return cached.$1;

    final fetched = await _fetch(trimmed);
    await _store(trimmed, fetched);
    return fetched;
  }

  static Future<(String?,)?> _peek(String identity) async {
    final mem = _memory[identity];
    if (mem != null) {
      final age = DateTime.now().difference(mem.at);
      if (mem.url != null && age < _hitTtl) return (mem.url,);
      if (mem.url == null && age < _missTtl) return (null,);
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_cachePrefix$identity');
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final url = data['url'] as String?;
      final ts = data['timestamp'] as int? ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (url != null && url.isNotEmpty && age < _hitTtl.inMilliseconds) {
        _memory[identity] = _Entry(url, DateTime.fromMillisecondsSinceEpoch(ts));
        return (url,);
      }
      if ((url == null || url.isEmpty) && age < _missTtl.inMilliseconds) {
        _memory[identity] = _Entry(null, DateTime.fromMillisecondsSinceEpoch(ts));
        return (null,);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _store(String identity, String? url) async {
    _memory[identity] = _Entry(url, DateTime.now());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_cachePrefix$identity',
      jsonEncode({
        'url': url,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  static Future<String?> _fetch(String identity) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        '$_lookup?key_suffix=${Uri.encodeQueryComponent(identity)}&fields=pictures',
      );
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      if (body is! Map) return null;
      final them = body['them'];
      if (them is! List || them.isEmpty || them.first is! Map) return null;
      final pictures = (them.first as Map)['pictures'];
      if (pictures is! Map) return null;
      final primary = pictures['primary'];
      if (primary is! Map) return null;
      final url = primary['url'];
      return url is String && url.isNotEmpty ? url : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

class _Entry {
  const _Entry(this.url, this.at);
  final String? url;
  final DateTime at;
}
