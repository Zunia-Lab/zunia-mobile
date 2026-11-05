import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fiat currencies the app can show values in, in the order Preferences lists
/// them. The same five as extension 0.1.5 (`CURRENCIES` in lib/settings.ts).
///
/// The portfolio reads [AppPreferences.currency] and can rely on it being one
/// of these: a value stored by an older build that offered others (NGN, KES,
/// ZAR, with no price feed behind them) reads back as USD.
const supportedCurrencies = <String>['USD', 'EUR', 'GBP', 'JPY', 'CHF'];

/// User-facing app preferences. Nothing here is a secret, so plain
/// SharedPreferences is the right home; the vault keeps its own storage.
///
/// Notification choices (which kinds show, reward reminders) live in
/// `lib/notifications/notify_prefs.dart`, next to the engine that reads them.
@immutable
class AppPreferences {
  const AppPreferences({
    this.themeMode = ThemeMode.system,
    this.hideAmounts = false,
    this.currency = 'USD',
    this.liveReads = true,
    this.diagnostics = false,
    this.alerts = true,
    this.nftMedia = false,
    this.loaded = true,
  });

  /// What the app holds before the stored values have been read.
  ///
  /// Every switch that lets the wallet talk to a third party starts off here,
  /// not at its default. The defaults are on for live reads, and a provider
  /// built in the first frame would otherwise read balances for a user who
  /// turned reads off, before their choice had been loaded. `main` preloads the
  /// stored values so the app itself never sees this state; tests and any
  /// other ProviderScope do, for the few milliseconds the read takes.
  static const unloaded = AppPreferences(
    liveReads: false,
    nftMedia: false,
    alerts: false,
    loaded: false,
  );

  final ThemeMode themeMode;
  final bool hideAmounts;

  /// One of [supportedCurrencies].
  final String currency;

  /// Read balances and chain state from public endpoints.
  ///
  /// On by default so the portfolio is useful after unlock, as in the
  /// extension (`liveBalances`). Turn off in Preferences to stay offline for
  /// those reads; addresses still derive locally.
  final bool liveReads;

  /// Stored, but nothing reads it: the app collects no diagnostics.
  ///
  /// Kept so a value set by an older build survives, and so the Security
  /// screen, which still renders a switch for it, compiles. Preferences no
  /// longer shows it: a switch that does nothing tells the user something
  /// false. This mirrors the extension's `INERT_SETTINGS.diagnostics`.
  final bool diagnostics;

  /// Raise device notifications (banners, lock screen) for new notices.
  ///
  /// The in-app feed and its unread count work without this; it only decides
  /// whether the system is asked to show them too, and the system still needs
  /// the user's permission. The extension's equivalent is `browserAlerts`.
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

  /// False only for [unloaded].
  final bool loaded;

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
    case 'dark':
      return ThemeMode.dark;
    default:
      // Unset follows the phone, as the launch screen does.
      return ThemeMode.system;
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

/// A stored currency, or USD for anything this build does not offer.
String normalizeCurrency(String? raw) =>
    raw != null && supportedCurrencies.contains(raw) ? raw : 'USD';

/// The stored preferences, field by field; anything missing keeps its default.
Future<AppPreferences> readStoredPreferences() async {
  final store = await SharedPreferences.getInstance();
  return AppPreferences(
    themeMode: _decodeTheme(store.getString(_kTheme)),
    hideAmounts: store.getBool(_kHide) ?? false,
    currency: normalizeCurrency(store.getString(_kCurrency)),
    liveReads: store.getBool(_kLive) ?? true,
    diagnostics: store.getBool(_kDiagnostics) ?? false,
    alerts: store.getBool(_kAlerts) ?? true,
    nftMedia: store.getBool(_kNftMedia) ?? false,
  );
}

class PreferencesController extends StateNotifier<AppPreferences> {
  PreferencesController({AppPreferences? initial})
      : super(initial ?? _takePreloaded() ?? AppPreferences.unloaded) {
    _ready = state.loaded ? Future<void>.value() : _restore();
  }

  static AppPreferences? _preloaded;

  /// Read the stored values before the first frame, so nothing ever renders,
  /// or reads a chain, with [AppPreferences.unloaded]. Called once by `main`.
  static Future<void> preload() async {
    _preloaded = await readStoredPreferences();
  }

  /// Used once: a second controller (a test's fresh ProviderScope) must read
  /// the store, not a snapshot an earlier one was built from.
  static AppPreferences? _takePreloaded() {
    final value = _preloaded;
    _preloaded = null;
    return value;
  }

  late final Future<void> _ready;

  /// Completes once the stored values are in [state].
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    final stored = await readStoredPreferences();
    if (mounted) state = stored;
  }

  /// Applies [next] once the restore is done, so a change made in the first
  /// milliseconds is not overwritten by the values it replaced.
  Future<SharedPreferences> _apply(AppPreferences Function(AppPreferences) next) async {
    await _ready;
    state = next(state);
    return SharedPreferences.getInstance();
  }

  Future<void> setTheme(ThemeMode mode) async {
    final store = await _apply((p) => p.copyWith(themeMode: mode));
    await store.setString(_kTheme, _encodeTheme(mode));
  }

  Future<void> toggleHideAmounts() async {
    await _ready;
    await setHideAmounts(!state.hideAmounts);
  }

  Future<void> setHideAmounts(bool value) async {
    final store = await _apply((p) => p.copyWith(hideAmounts: value));
    await store.setBool(_kHide, value);
  }

  /// [value] must be one of [supportedCurrencies]; anything else is stored as
  /// USD rather than as a currency no screen can price.
  Future<void> setCurrency(String value) async {
    final code = normalizeCurrency(value);
    final store = await _apply((p) => p.copyWith(currency: code));
    await store.setString(_kCurrency, code);
  }

  Future<void> setLiveReads(bool value) async {
    final store = await _apply((p) => p.copyWith(liveReads: value));
    await store.setBool(_kLive, value);
  }

  /// Inert: see [AppPreferences.diagnostics].
  Future<void> setDiagnostics(bool value) async {
    final store = await _apply((p) => p.copyWith(diagnostics: value));
    await store.setBool(_kDiagnostics, value);
  }

  Future<void> setAlerts(bool value) async {
    final store = await _apply((p) => p.copyWith(alerts: value));
    await store.setBool(_kAlerts, value);
  }

  /// Turn NFT artwork fetching on or off. See [AppPreferences.nftMedia] for why
  /// this is not folded into [setLiveReads].
  Future<void> setNftMedia(bool value) async {
    final store = await _apply((p) => p.copyWith(nftMedia: value));
    await store.setBool(_kNftMedia, value);
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesController, AppPreferences>(
  (ref) => PreferencesController(),
);
