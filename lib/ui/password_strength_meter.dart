import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

enum PasswordStrength { empty, weak, fair, strong }

/// Same scoring as `@zunialab/ui` `scorePassword`, so the extension and the
/// app call the same password the same thing.
({PasswordStrength score, double fraction, List<String> hints}) scorePassword(
  String password,
) {
  if (password.isEmpty) {
    return (
      score: PasswordStrength.empty,
      fraction: 0,
      hints: const ['Enter a password'],
    );
  }
  final hints = <String>[];
  var points = 0;
  if (password.length >= 8) {
    points += 1;
  } else {
    hints.add('Use at least 8 characters');
  }
  if (password.length >= 12) points += 1;
  if (RegExp('[a-z]').hasMatch(password) && RegExp('[A-Z]').hasMatch(password)) {
    points += 1;
  } else {
    hints.add('Mix upper and lower case');
  }
  if (RegExp(r'\d').hasMatch(password)) {
    points += 1;
  } else {
    hints.add('Add a number');
  }
  if (RegExp('[^A-Za-z0-9]').hasMatch(password)) {
    points += 1;
  } else {
    hints.add('Add a symbol');
  }
  if (points <= 1) {
    return (score: PasswordStrength.weak, fraction: 0.25, hints: hints);
  }
  if (points <= 3) {
    return (score: PasswordStrength.fair, fraction: 0.55, hints: hints);
  }
  return (
    score: PasswordStrength.strong,
    fraction: 1,
    hints: hints.isEmpty ? const ['Looks good'] : hints,
  );
}

class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final result = scorePassword(password);
    final (label, color) = switch (result.score) {
      PasswordStrength.empty => ('Strength', s.fgMuted),
      PasswordStrength.weak => ('Weak', s.danger),
      PasswordStrength.fair => ('Fair', s.warning),
      PasswordStrength.strong => ('Strong', s.success),
    };
    return Semantics(
      label: 'Password strength: $label',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'PASSWORD STRENGTH',
                  style: zuniaMono(fontSize: 9.5, letterSpacing: 1.2, color: s.fgDim),
                ),
              ),
              Text(
                label.toUpperCase(),
                style: zuniaMono(fontSize: 10, letterSpacing: 1, color: color),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: result.fraction),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 4,
                color: color,
                backgroundColor: s.glass2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final hint in result.hints.take(2))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(hint, style: zuniaMono(fontSize: 10, color: s.fgDim)),
            ),
        ],
      ),
    );
  }
}
