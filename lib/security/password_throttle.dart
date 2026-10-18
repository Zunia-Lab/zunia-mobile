/// Backoff for wrong passwords, the same schedule as extension 0.1.5
/// (`lib/password-throttle.ts`): three free attempts, then 2 s doubling with
/// every further failure, capped at 5 minutes.
///
/// Argon2id already makes each guess cost a fraction of a second of CPU; this
/// makes someone holding the phone wait on top of that. The state is persisted
/// by the keystore, so killing and relaunching the app does not reset it.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

const int kPasswordFreeAttempts = 3;
const Duration kPasswordBaseDelay = Duration(seconds: 2);
const Duration kPasswordMaxDelay = Duration(minutes: 5);

@immutable
class ThrottleState {
  const ThrottleState({this.failures = 0, this.retryAtMs = 0});

  static const empty = ThrottleState();

  /// Consecutive wrong passwords since the last right one.
  final int failures;

  /// Epoch ms before which another attempt is refused. 0 when not throttled.
  final int retryAtMs;

  /// Time left before the next attempt is allowed, as of [now].
  Duration waitAt(DateTime now) {
    final left = retryAtMs - now.millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  bool isThrottledAt(DateTime now) => waitAt(now) > Duration.zero;

  String encode() => jsonEncode({'failures': failures, 'retryAt': retryAtMs});

  /// The stored state as of [now]. A wait that already ended reads as 0, and
  /// one longer than the maximum (the clock was set back after it was
  /// recorded) is cut to the maximum instead of locking the user out for the
  /// difference.
  static ThrottleState decode(String? raw, DateTime now) {
    if (raw == null || raw.isEmpty) return empty;
    Object? value;
    try {
      value = jsonDecode(raw);
    } catch (_) {
      return empty;
    }
    if (value is! Map) return empty;
    final failures = value['failures'];
    final retryAt = value['retryAt'];
    final nowMs = now.millisecondsSinceEpoch;
    return ThrottleState(
      failures: failures is num && failures > 0 ? failures.floor() : 0,
      retryAtMs: retryAt is num && retryAt > nowMs
          ? math.min(retryAt.toInt(), nowMs + kPasswordMaxDelay.inMilliseconds)
          : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ThrottleState &&
      other.failures == failures &&
      other.retryAtMs == retryAtMs;

  @override
  int get hashCode => Object.hash(failures, retryAtMs);

  @override
  String toString() => 'ThrottleState($failures, retryAt: $retryAtMs)';
}

/// The wait imposed after [failures] consecutive wrong passwords.
Duration throttleDelay(int failures) {
  if (failures < kPasswordFreeAttempts) return Duration.zero;
  final exponent = failures - kPasswordFreeAttempts;
  // 2 s * 2^n overflows nothing before the cap: 2^8 * 2 s is already 8.5 min.
  if (exponent >= 8) return kPasswordMaxDelay;
  final ms = kPasswordBaseDelay.inMilliseconds * (1 << exponent);
  return Duration(milliseconds: math.min(ms, kPasswordMaxDelay.inMilliseconds));
}

ThrottleState recordFailure(ThrottleState state, DateTime now) {
  final failures = state.failures + 1;
  final delay = throttleDelay(failures);
  return ThrottleState(
    failures: failures,
    retryAtMs: delay == Duration.zero
        ? 0
        : now.millisecondsSinceEpoch + delay.inMilliseconds,
  );
}

/// Thrown instead of checking a password while a wait is in force.
class PasswordThrottledException implements Exception {
  const PasswordThrottledException(this.wait);

  final Duration wait;

  int get seconds => math.max(1, (wait.inMilliseconds / 1000).ceil());

  String get message => 'Too many wrong passwords. Try again in $seconds s.';

  @override
  String toString() => message;
}

/// The password did not open the vault. [wait] is the backoff that failure
/// started, zero while free attempts remain.
class WrongPasswordException implements Exception {
  const WrongPasswordException({this.wait = Duration.zero});

  final Duration wait;

  String get message {
    if (wait == Duration.zero) return 'Wrong password';
    final seconds = math.max(1, (wait.inMilliseconds / 1000).ceil());
    return 'Wrong password. Wait $seconds s before trying again.';
  }

  @override
  String toString() => message;
}
