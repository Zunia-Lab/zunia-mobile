/// Mirrors [config/mnemonic_security.yaml] as typed Dart constants for UI enforcement.
library;

class MnemonicSecurityConfig {
  const MnemonicSecurityConfig._();

  static const int schemaVersion = 1;

  // screenshots
  static const bool androidFlagSecure = true;
  static const bool iosDetectScreenCapture = true;
  static const bool iosBlurOnScreenshotNotification = true;

  // display
  static const bool blurByDefault = true;
  static const bool tapToReveal = true;
  static const bool autoReblurOnBackground = true;
  static const int autoHideAfterSeconds = 60;
  static const bool hideInAppSwitcher = true;

  // clipboard
  static const bool allowMnemonicCopyDefault = true;
  static const int clipboardAutoClearSeconds = 45;
  static const bool warnBeforeCopy = false;

  // input
  static const bool autocorrect = false;
  static const bool spellcheck = false;
  static const bool androidImeNoPersonalizedLearning = true;

  // backup_verification
  static const bool requiredBeforeFund = true;
  static const int randomWordPositions12 = 4;
  static const int randomWordPositions24 = 6;
  static const bool typedEntry = false;
  static const bool skipAllowedWithScaryConfirm = false;
  static const bool persistentUnverifiedBanner = true;

  /// Words the user must confirm for a phrase of [wordCount] words.
  static int verifyWordCount(int wordCount) =>
      wordCount >= 24 ? randomWordPositions24 : randomWordPositions12;

  // entropy
  static const bool offer24Word = true;
  static const int minBits = 128;
}
