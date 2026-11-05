/// The network-fee preference every transaction this wallet builds uses: a
/// speed (Low / Mid / High, the catalog's gas price steps) and a gas
/// adjustment between 1.0 and 2.0 (default 1.4) applied to the simulated gas.
///
/// Port of the extension's `feeSpeed` / `gasAdjustment` settings and of
/// `lib/fee-prefs.ts`. Kept in its own store rather than in Preferences,
/// whose screen another workstream owns; the review screens change it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/tx/tx_engine.dart';

const double minGasAdjustment = 1.0;
const double maxGasAdjustment = 2.0;

/// Gas assumed before a transaction has been simulated, for the fee kept back
/// when Max spends the coin that also pays the fee.
const int reserveGasLimit = 300000;

@immutable
class FeePrefs {
  const FeePrefs({this.speed = FeeSpeed.average, this.gasAdjustment = defaultGasAdjustment});

  final FeeSpeed speed;
  final double gasAdjustment;

  FeePrefs copyWith({FeeSpeed? speed, double? gasAdjustment}) => FeePrefs(
        speed: speed ?? this.speed,
        gasAdjustment: gasAdjustment ?? this.gasAdjustment,
      );
}

/// One decimal, inside 1.0–2.0; anything else falls back to the default.
double clampGasAdjustment(double value) {
  if (!value.isFinite || value < minGasAdjustment || value > maxGasAdjustment) {
    return defaultGasAdjustment;
  }
  return (value * 10).round() / 10;
}

const _kSpeed = 'zunia.fees.speed';
const _kAdjustment = 'zunia.fees.gasAdjustment';

class FeePrefsController extends StateNotifier<FeePrefs> {
  FeePrefsController() : super(const FeePrefs()) {
    _restore();
  }

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final speed = FeeSpeed.values.where((s) => s.name == store.getString(_kSpeed)).firstOrNull;
    state = FeePrefs(
      speed: speed ?? FeeSpeed.average,
      gasAdjustment: clampGasAdjustment(store.getDouble(_kAdjustment) ?? defaultGasAdjustment),
    );
  }

  Future<void> set({FeeSpeed? speed, double? gasAdjustment}) async {
    state = state.copyWith(
      speed: speed,
      gasAdjustment: gasAdjustment == null ? null : clampGasAdjustment(gasAdjustment),
    );
    final store = await SharedPreferences.getInstance();
    await store.setString(_kSpeed, state.speed.name);
    await store.setDouble(_kAdjustment, state.gasAdjustment);
  }
}

final feePrefsProvider = StateNotifierProvider<FeePrefsController, FeePrefs>(
  (ref) => FeePrefsController(),
);

/// Base units that must stay in the account when [spendDenom] pays gas: the
/// chain deducts the fee first, so sending the whole balance of the fee coin
/// fails with `insufficient funds` by a few thousand base units.
BigInt reservedFeeUnits(
  ChainEntry chain,
  String spendDenom,
  FeePrefs prefs, {
  int gasLimit = reserveGasLimit,
}) {
  final feeDenom = chain.feeMinimalDenom.isEmpty ? chain.coinMinimalDenom : chain.feeMinimalDenom;
  if (feeDenom != spendDenom) return BigInt.zero;
  final gas = (gasLimit * prefs.gasAdjustment).ceil();
  final fee = TxEngine.feeFor(chain, gas < 1 ? 1 : gas, prefs.speed);
  return fee.amount.isEmpty ? BigInt.zero : BigInt.parse(fee.amount.first.amount);
}

BigInt maxSendable(BigInt available, BigInt reserved) =>
    available <= reserved ? BigInt.zero : available - reserved;
