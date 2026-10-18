/// How dApp signing behaves: the two switches extension 0.1.5 keeps under
/// Settings > Security, with the same defaults.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class SigningSettings {
  const SigningSettings({
    this.blindSigning = false,
    this.exposeKeplrAlias = false,
    this.loaded = false,
  });

  /// Approve messages Zunia cannot decode. Off: such a request is refused
  /// before any prompt opens ("Blind signing disabled for unknown messages").
  final bool blindSigning;

  /// Also expose the provider as `window.keplr` in the in-app browser, for
  /// dApps that only look for Keplr. Off: `window.zunia` only.
  final bool exposeKeplrAlias;

  final bool loaded;

  SigningSettings copyWith({bool? blindSigning, bool? exposeKeplrAlias, bool? loaded}) =>
      SigningSettings(
        blindSigning: blindSigning ?? this.blindSigning,
        exposeKeplrAlias: exposeKeplrAlias ?? this.exposeKeplrAlias,
        loaded: loaded ?? this.loaded,
      );
}

const _kBlindSigning = 'zunia.signing.blindSigning';
const _kKeplrAlias = 'zunia.signing.exposeKeplrAlias';

class SigningSettingsController extends StateNotifier<SigningSettings> {
  SigningSettingsController() : super(const SigningSettings()) {
    _ready = _restore();
  }

  late final Future<void> _ready;

  /// Completes once the stored values are in [state].
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = state.copyWith(
      blindSigning: store.getBool(_kBlindSigning) ?? false,
      exposeKeplrAlias: store.getBool(_kKeplrAlias) ?? false,
      loaded: true,
    );
  }

  Future<void> setBlindSigning(bool value) async {
    await _ready;
    state = state.copyWith(blindSigning: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kBlindSigning, value);
  }

  Future<void> setExposeKeplrAlias(bool value) async {
    await _ready;
    state = state.copyWith(exposeKeplrAlias: value);
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kKeplrAlias, value);
  }
}

final signingSettingsProvider =
    StateNotifierProvider<SigningSettingsController, SigningSettings>(
  (ref) => SigningSettingsController(),
);
