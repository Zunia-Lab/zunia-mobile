/// Which notifications appear: in the feed, on the unread count and as device
/// notifications. Mirrors `NotifyPrefs` in zunia-extension/lib/settings.ts.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often the "staking rewards ready to claim" reminder comes back while
/// the rewards wait: once until they are claimed, every day, every week, or
/// never.
enum RewardReminder { once, daily, weekly, off }

extension RewardReminderCopy on RewardReminder {
  String get label => switch (this) {
        RewardReminder.once => 'Once',
        RewardReminder.daily => 'Daily',
        RewardReminder.weekly => 'Weekly',
        RewardReminder.off => 'Off',
      };

  /// What the choice does, in the extension's words.
  String get hint => switch (this) {
        RewardReminder.once =>
          'One notification when rewards can be claimed. After you claim, the '
              'next one waits until a whole token is ready.',
        RewardReminder.daily =>
          'Reminds you once a day while rewards are waiting to be claimed.',
        RewardReminder.weekly =>
          'Reminds you once a week while rewards are waiting to be claimed.',
        RewardReminder.off =>
          'No notifications for staking rewards. Earn still shows what you can '
              'claim.',
      };
}

/// Approvals are not a choice: a site is waiting on each one.
@immutable
class NotifyPrefs {
  const NotifyPrefs({
    this.transfers = true,
    this.unbonding = false,
    this.governance = false,
    this.rewards = RewardReminder.once,
  });

  /// Quiet by default: tokens arriving and one staking-rewards notice per
  /// cycle. Governance lists every open proposal on every enabled network and
  /// unbonding repeats what the user just did, so both stay off until asked
  /// for. The same defaults as the extension's `DEFAULT_NOTIFY_PREFS`.
  static const defaults = NotifyPrefs();

  final bool transfers;
  final bool unbonding;
  final bool governance;
  final RewardReminder rewards;

  NotifyPrefs copyWith({
    bool? transfers,
    bool? unbonding,
    bool? governance,
    RewardReminder? rewards,
  }) =>
      NotifyPrefs(
        transfers: transfers ?? this.transfers,
        unbonding: unbonding ?? this.unbonding,
        governance: governance ?? this.governance,
        rewards: rewards ?? this.rewards,
      );

  Map<String, Object> toJson() => {
        'transfers': transfers,
        'unbonding': unbonding,
        'governance': governance,
        'rewards': rewards.name,
      };

  @override
  bool operator ==(Object other) =>
      other is NotifyPrefs &&
      other.transfers == transfers &&
      other.unbonding == unbonding &&
      other.governance == governance &&
      other.rewards == rewards;

  @override
  int get hashCode => Object.hash(transfers, unbonding, governance, rewards);
}

/// A stored value, field by field; anything unreadable keeps its default.
NotifyPrefs parseNotifyPrefs(Object? value) {
  final row = value is Map ? value : const <String, Object?>{};
  bool flag(String key, bool fallback) =>
      row[key] is bool ? row[key] as bool : fallback;
  const d = NotifyPrefs.defaults;
  final raw = row['rewards'];
  return NotifyPrefs(
    transfers: flag('transfers', d.transfers),
    unbonding: flag('unbonding', d.unbonding),
    governance: flag('governance', d.governance),
    rewards: RewardReminder.values
            .where((r) => r.name == raw)
            .firstOrNull ??
        d.rewards,
  );
}

const _kNotifyPrefs = 'zunia.notify.prefs';

class NotifyPrefsController extends StateNotifier<NotifyPrefs> {
  NotifyPrefsController() : super(NotifyPrefs.defaults) {
    _ready = _restore();
  }

  late final Future<void> _ready;
  Future<void> get ready => _ready;

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kNotifyPrefs);
    if (raw == null) return;
    try {
      final parsed = parseNotifyPrefs(jsonDecode(raw));
      if (mounted) state = parsed;
    } on FormatException {
      // Defaults stand.
    }
  }

  Future<void> update(NotifyPrefs Function(NotifyPrefs) change) async {
    await _ready;
    state = change(state);
    final store = await SharedPreferences.getInstance();
    await store.setString(_kNotifyPrefs, jsonEncode(state.toJson()));
  }
}

final notifyPrefsProvider =
    StateNotifierProvider<NotifyPrefsController, NotifyPrefs>(
  (ref) => NotifyPrefsController(),
);
