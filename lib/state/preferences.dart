import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-facing app preferences. Nothing here is a secret, so plain
/// SharedPreferences is the right home; the vault keeps its own storage.
@immutable
class AppPreferences {
  const AppPreferences({
    this.themeMode = ThemeMode.dark,
    this.hideAmounts = false,
    this.currency = 'USD',
    this.liveReads = true,
    this.diagnostics = false,
    this.alerts = true,
    this.nftMedia = false,
  });

  final ThemeMode themeMode;
  final bool hideAmounts;
  final String currency;

  /// Read balances and chain state from public endpoints.
  ///
  /// On by default so the portfolio is useful after unlock. Turn off in
  /// Preferences to stay offline for those reads; addresses still derive locally.
  final bool liveReads;
  final bool diagnostics;
  final bool alerts;

  /// Fetch NFT artwork and off-chain metadata from whatever host a token points
  /// at.
  ///
  /// Off by default and separate from [liveReads] on purpose. A live read goes
  /// to a chain endpoint the user chose; this goes to a host the token's minter
  /// chose, and it only happens for tokens this address holds, so turning it on
  /// tells that host both the user's IP address and the shape of their
  /// collection. Both must be on for anything to be fetched.
  final bool nftMedia;

  AppPreferences copyWith({
    ThemeMode? themeMode,
    bool? hideAmounts,
    String? currency,
    bool? liveReads,
    bool? diagnostics,
    bool? alerts,
    bool? nftMedia,
  }) {
    return AppPreferences(
      themeMode: themeMode ?? this.themeMode,
      hideAmounts: hideAmounts ?? this.hideAmounts,
      currency: currency ?? this.currency,
      liveReads: liveReads ?? this.liveReads,
      diagnostics: diagnostics ?? this.diagnostics,
      alerts: alerts ?? this.alerts,
      nftMedia: nftMedia ?? this.nftMedia,
    );
  }

  /// Replaces a rendered amount with dots while privacy mode is on.
  String mask(String value) => hideAmounts ? '••••' : value;
}

const _kTheme = 'zunia.prefs.theme';
const _kHide = 'zunia.prefs.hideAmounts';
const _kCurrency = 'zunia.prefs.currency';
const _kLive = 'zunia.prefs.liveReads';
const _kDiagnostics = 'zunia.prefs.diagnostics';
const _kAlerts = 'zunia.prefs.alerts';
const _kNftMedia = 'zunia.prefs.nftMedia';

ThemeMode _decodeTheme(String? raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'system':
      return ThemeMode.system;
    default:
      return ThemeMode.dark;
  }
}

String _encodeTheme(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.system:
      return 'system';
    case ThemeMode.dark:
      return 'dark';
  }
}

class PreferencesController extends StateNotifier<AppPreferences> {
  PreferencesController() : super(const AppPreferences()) {
    _restore();
  }

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    state = AppPreferences(
      themeMode: _decodeTheme(store.getString(_kTheme)),
      hideAmounts: store.getBool(_kHide) ?? false,
      currency: store.getString(_kCurrency) ?? 'USD',
      liveReads: store.getBool(_kLive) ?? true,
      diagnostics: store.getBool(_kDiagnostics) ?? false,
      alerts: store.getBool(_kAlerts) ?? true,
      nftMedia: store.getBool(_kNftMedia) ?? false,
    );
  }

  Future<void> setTheme(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final store = await SharedPreferences.getInstance();
    await store.setString(_kTheme, _encodeTheme(mode));
  }

  Future<void> toggleHideAmounts() => setHideAmounts(!state.hideAmounts);

  Future<void> setHideAmounts(bool value) async {
    state = state.copyWith(hideAmounts: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kHide, value);
  }

  Future<void> setCurrency(String value) async {
    state = state.copyWith(currency: value);
    final store = await SharedPreferences.getInstance();
    await store.setString(_kCurrency, value);
  }

  Future<void> setLiveReads(bool value) async {
    state = state.copyWith(liveReads: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kLive, value);
  }

  Future<void> setDiagnostics(bool value) async {
    state = state.copyWith(diagnostics: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kDiagnostics, value);
  }

  Future<void> setAlerts(bool value) async {
    state = state.copyWith(alerts: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kAlerts, value);
  }

  /// Turn NFT artwork fetching on or off. See [AppPreferences.nftMedia] for why
  /// this is not folded into [setLiveReads].
  Future<void> setNftMedia(bool value) async {
    state = state.copyWith(nftMedia: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kNftMedia, value);
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesController, AppPreferences>(
  (ref) => PreferencesController(),
);
