import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand tokens aligned with zunia-brand / @zunialab/tokens.
abstract final class ZuniaColors {
  static const ink = Color(0xFF10214F);
  static const paper = Color(0xFFF4F5F7);
  static const cobalt = Color(0xFF2050C4);
  static const cobaltBright = Color(0xFF3B6BFF);
  static const cobaltSoft = Color(0xFF6FA8FF);
  static const black = Color(0xFF101012);
  static const slate = Color(0xFF4A5468);
  static const grey = Color(0xFF6E7280);
  static const muted = Color(0xFFA8BADE);
  static const hairline = Color(0xFFC7D2EA);
  static const wash = Color(0xFFE4E9F4);
  static const elevatedDark = Color(0xFF15275C);
}

abstract final class ZuniaTheme {
  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ZuniaColors.ink,
      colorScheme: const ColorScheme.dark(
        primary: ZuniaColors.cobalt,
        onPrimary: Colors.white,
        secondary: ZuniaColors.cobaltSoft,
        surface: ZuniaColors.elevatedDark,
        onSurface: ZuniaColors.paper,
        outline: Color(0x1FF4F5F7),
      ),
    );

    return base.copyWith(
      textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme).apply(
        bodyColor: ZuniaColors.paper,
        displayColor: ZuniaColors.paper,
      ),
      primaryTextTheme: GoogleFonts.spaceGroteskTextTheme(base.primaryTextTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: ZuniaColors.ink,
        foregroundColor: ZuniaColors.paper,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
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
          textStyle: GoogleFonts.spaceGrotesk(
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
        color: ZuniaColors.elevatedDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0x1FF4F5F7)),
        ),
      ),
    );
  }

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
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
      textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme).apply(
        bodyColor: ZuniaColors.black,
        displayColor: ZuniaColors.ink,
      ),
    );
  }
}
