/// When an unlocked session locks by itself.
///
/// The extension counts time without input (`activity_report_ms`) and locks on
/// device lock. A phone has no device-lock event an app can see, so here the
/// clock runs from the last touch and keeps running while the app is in the
/// background: coming back after the delay finds the wallet locked, whether
/// the time passed on screen or in the app switcher. "Immediately" locks as
/// soon as the app leaves the screen.
library;

import 'dart:async';

import 'package:zunia_mobile/state/security_settings.dart';

/// Pure decision, separate from timers so it can be tested exactly.
abstract final class AutoLockPolicy {
  /// A clock set back by more than this since the last touch locks too, so
  /// the delay cannot be dodged by moving the clock.
  static const clockSkewTolerance = Duration(seconds: 5);

  static bool shouldLock({
    required DateTime now,
    required DateTime lastInteraction,
    required AutoLockDelay delay,
    required bool inBackground,
  }) {
    if (delay == AutoLockDelay.immediately) return inBackground;
    final elapsed = now.difference(lastInteraction);
    if (elapsed < -clockSkewTolerance) return true;
    return elapsed >= delay.duration;
  }

  /// Time until [shouldLock] turns true while the user does nothing.
  static Duration remaining({
    required DateTime now,
    required DateTime lastInteraction,
    required AutoLockDelay delay,
  }) {
    if (delay == AutoLockDelay.immediately) return Duration.zero;
    final left = delay.duration - now.difference(lastInteraction);
    return left.isNegative ? Duration.zero : left;
  }
}

typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Runs [AutoLockPolicy] for one unlocked session: reschedules on touch,
/// checks on return from the background, and calls [onLock] once.
class AutoLockController {
  AutoLockController({
    required this.delay,
    required this.onLock,
    DateTime Function()? clock,
    TimerFactory? timerFactory,
  })  : _now = clock ?? DateTime.now,
        _timerFactory = timerFactory ?? Timer.new;

  /// Read on every decision, so a change in Settings applies at once.
  AutoLockDelay Function() delay;
  final void Function() onLock;
  final DateTime Function() _now;
  final TimerFactory _timerFactory;

  Timer? _timer;
  DateTime? _lastInteraction;
  DateTime? _lastScheduled;
  bool _running = false;
  bool _inBackground = false;

  bool get running => _running;
  DateTime? get lastInteraction => _lastInteraction;

  /// The session was unlocked.
  void start() {
    _running = true;
    _inBackground = false;
    _lastInteraction = _now();
    _schedule();
  }

  /// The session locked (by this controller or by the user).
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// A touch, a key, a scroll. Cheap: the timer is only rebuilt once a
  /// second at most, however fast the events come.
  void touch() {
    if (!_running || _inBackground) return;
    final now = _now();
    _lastInteraction = now;
    final last = _lastScheduled;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _schedule();
  }

  /// The app left the screen (paused / hidden).
  void backgrounded() {
    if (!_running) return;
    _inBackground = true;
    _check();
  }

  /// The app is back on screen. Locks before the first frame shows anything
  /// if the delay ran out meanwhile.
  void foregrounded() {
    if (!_running) return;
    _inBackground = false;
    if (_check()) return;
    _schedule();
  }

  /// Settings changed: apply the new delay from the last touch.
  void reschedule() {
    if (!_running) return;
    if (_check()) return;
    _schedule();
  }

  bool _check() {
    final last = _lastInteraction;
    if (!_running || last == null) return false;
    final lock = AutoLockPolicy.shouldLock(
      now: _now(),
      lastInteraction: last,
      delay: delay(),
      inBackground: _inBackground,
    );
    if (lock) {
      stop();
      onLock();
    }
    return lock;
  }

  void _schedule() {
    _timer?.cancel();
    final last = _lastInteraction;
    if (!_running || last == null) return;
    final now = _now();
    _lastScheduled = now;
    final current = delay();
    if (current == AutoLockDelay.immediately) {
      _timer = null;
      return;
    }
    final left = AutoLockPolicy.remaining(
      now: now,
      lastInteraction: last,
      delay: current,
    );
    // A little late on purpose: the check compares wall clocks, and firing
    // a hair early would only reschedule.
    _timer = _timerFactory(left + const Duration(milliseconds: 250), () {
      if (!_check()) _schedule();
    });
  }
}
