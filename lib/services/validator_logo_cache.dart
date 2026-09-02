/// Persists the winning Cosmostation moniker URL until the validator identity
/// changes. Mirrors `@zunialab/ui` `zunia.validator.logo.v1`.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_ui/zunia_ui.dart';

class ValidatorLogoCache {
  ValidatorLogoCache._();

  static Future<String?> read(ValidatorLogoInput input) async {
    if (input.operatorAddress.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(
      validatorLogoCacheKey(input.chainId, input.operatorAddress),
    );
    if (raw == null) return null;
    try {
      final record = ValidatorLogoRecord.tryParse(
        jsonDecode(raw) as Object?,
      );
      if (record == null || record.identity != input.identity) return null;
      return record.url;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(ValidatorLogoInput input, String url) async {
    if (input.operatorAddress.isEmpty || url.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final record = ValidatorLogoRecord(
      identity: input.identity,
      url: url,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(
      validatorLogoCacheKey(input.chainId, input.operatorAddress),
      jsonEncode(record.toJson()),
    );
  }

  static Future<void> clear(String chainId, String operatorAddress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(validatorLogoCacheKey(chainId, operatorAddress));
  }
}
