import 'package:flutter/material.dart';
import 'package:zunia_tokens/zunia_tokens.dart';

export 'package:zunia_tokens/zunia_tokens.dart'
    show ZuniaColors, ZuniaSpace, ZuniaRadii, ZuniaThemeTokens;

/// Locally bundled fonts — never fetch at runtime (privacy + offline).
const String kZuniaSans = 'SpaceGrotesk';
const String kZuniaMono = 'JetBrainsMono';

TextStyle zuniaSans({
  double? fontSize,
  FontWeight? fontWeight,
  double? letterSpacing,
  double? height,
  Color? color,
}) {
  return TextStyle(
    fontFamily: kZuniaSans,
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    height: height,
    color: color,
  );
}

TextStyle zuniaMono({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
}) {
  return TextStyle(
    fontFamily: kZuniaMono,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
  );
}

abstract final class ZuniaTheme {
  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: kZuniaSans,
      scaffoldBackgroundColor: ZuniaColors.ink,
      colorScheme: const ColorScheme.dark(
        primary: ZuniaColors.cobalt,
        onPrimary: Colors.white,
        secondary: ZuniaColors.cobaltSoft,
        surface: ZuniaThemeTokens.darkElevated,
        onSurface: ZuniaColors.paper,
        outline: Color(0x1FF4F5F7),
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: kZuniaSans,
        bodyColor: ZuniaColors.paper,
        displayColor: ZuniaColors.paper,
      ),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: kZuniaSans),
      appBarTheme: AppBarTheme(
        backgroundColor: ZuniaColors.ink,
        foregroundColor: ZuniaColors.paper,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: zuniaSans(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.6,
          color: ZuniaColors.paper,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ZuniaColors.cobalt,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: const StadiumBorder(),
          textStyle: zuniaSans(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            letterSpacing: -0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ZuniaColors.paper,
          side: const BorderSide(color: Color(0x33F4F5F7)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: const StadiumBorder(),
        ),
      ),
      cardTheme: CardThemeData(
        color: ZuniaThemeTokens.darkElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZuniaRadii.lg),
          side: const BorderSide(color: Color(0x1FF4F5F7)),
        ),
      ),
    );
  }

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: kZuniaSans,
      scaffoldBackgroundColor: ZuniaColors.paper,
      colorScheme: const ColorScheme.light(
        primary: ZuniaColors.cobalt,
        onPrimary: Colors.white,
        secondary: ZuniaColors.cobalt,
        surface: Colors.white,
        onSurface: ZuniaColors.black,
        outline: ZuniaColors.hairline,
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: kZuniaSans,
        bodyColor: ZuniaColors.black,
        displayColor: ZuniaColors.ink,
      ),
    );
  }
}
