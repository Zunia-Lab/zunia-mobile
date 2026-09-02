import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zunia_mobile/security/mnemonic_security_config.dart';

/// Text field configured to suppress autofill / autocorrect for seed entry.
class SeedTextField extends StatelessWidget {
  const SeedTextField({
    super.key,
    required this.controller,
    this.onChanged,
    this.label = 'Recovery phrase',
    this.maxLines = 3,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final String label;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      maxLines: maxLines,
      autocorrect: MnemonicSecurityConfig.autocorrect,
      enableSuggestions: false,
      enableIMEPersonalizedLearning:
          !MnemonicSecurityConfig.androidImeNoPersonalizedLearning,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      spellCheckConfiguration: MnemonicSecurityConfig.spellcheck
          ? null
          : const SpellCheckConfiguration.disabled(),
      keyboardType: TextInputType.visiblePassword,
      autofillHints: const [],
      inputFormatters: [
        // Discourage password-manager autofill association.
        FilteringTextInputFormatter.deny(RegExp(r'[\u0000]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
