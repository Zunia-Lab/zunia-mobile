/// Shared recovery-phrase safety copy for Zunia clients.
/// Keep aligned with `@zunialab/ui` `SEED_SAFETY` (React).
class SeedSafetyCopy {
  static const title = 'Protect your phrase';

  static const summary =
      'Anyone with these words controls the wallet. Zunia cannot reset a lost phrase.';

  static const bullets = <String>[
    'Never share it. Support will never ask for it.',
    'Store it offline. Screenshots and cloud notes are unsafe.',
  ];

  static const ackUnderstand =
      'I will never share my recovery phrase with anyone.';

  static const ackBackup =
      'I accept that Zunia cannot recover a lost phrase, and I will keep an offline backup.';

  static const deviceNote =
      'Keys stay on this device. Session clears when you lock.';

  static const wordLengthHint =
      '12 words is standard. 24 words adds entropy.';
}
