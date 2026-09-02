import 'dart:convert';

/// Pull a bech32 address out of a QR payload (plain or cosmos: URI).
String? extractBech32Address(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (_looksBech32(value)) return value;

  if (value.contains(':')) {
    final after = value.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:'), '');
    final candidate = after.split(RegExp(r'[/?#\s]')).first;
    if (_looksBech32(candidate)) return candidate;
    for (final part in after.split('/')) {
      if (_looksBech32(part)) return part;
    }
  }

  final match = RegExp(r'\b([a-z]{2,16}1[0-9a-z]{20,})\b', caseSensitive: false)
      .firstMatch(value);
  if (match != null && _looksBech32(match.group(1)!)) return match.group(1);
  return null;
}

bool _looksBech32(String value) {
  // Lightweight shape check; full HRP decode happens at the form layer.
  return RegExp(r'^[a-z]{2,16}1[0-9a-z]{20,}$').hasMatch(value.toLowerCase());
}

String? addressFromMaybeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['address'] is String) {
      return extractBech32Address(decoded['address'] as String);
    }
  } catch (_) {}
  return extractBech32Address(raw);
}
