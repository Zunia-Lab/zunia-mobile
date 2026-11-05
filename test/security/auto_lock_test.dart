import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/security/auto_lock.dart';
import 'package:zunia_mobile/state/security_settings.dart';

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this.callback);

  final DateTime at;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void main() {
  group('policy', () {
    final t0 = DateTime.utc(2026, 10, 18, 12);

    test('locks once the delay has passed since the last touch', () {
      bool lockAt(Duration later, {bool background = false}) =>
          AutoLockPolicy.shouldLock(
            now: t0.add(later),
            lastInteraction: t0,
            delay: AutoLockDelay.tenMinutes,
            inBackground: background,
          );
      expect(lockAt(const Duration(minutes: 9, seconds: 59)), isFalse);
      expect(lockAt(const Duration(minutes: 10)), isTrue);
      // Background time counts: nothing touches the app there.
      expect(lockAt(const Duration(minutes: 11), background: true), isTrue);
    });

    test('immediately means on leaving the screen', () {
      expect(
        AutoLockPolicy.shouldLock(
          now: t0.add(const Duration(hours: 1)),
          lastInteraction: t0,
          delay: AutoLockDelay.immediately,
          inBackground: false,
        ),
        isFalse,
      );
      expect(
        AutoLockPolicy.shouldLock(
          now: t0,
          lastInteraction: t0,
          delay: AutoLockDelay.immediately,
          inBackground: true,
        ),
        isTrue,
      );
    });

    test('a clock moved back locks rather than extending the session', () {
      expect(
        AutoLockPolicy.shouldLock(
          now: t0.subtract(const Duration(minutes: 1)),
          lastInteraction: t0,
          delay: AutoLockDelay.thirtyMinutes,
          inBackground: false,
        ),
        isTrue,
      );
    });

    test('defaults to 10 minutes, like the extension', () {
      expect(AutoLockDelay.fallback.duration, const Duration(minutes: 10));
      expect(AutoLockDelay.fromMs(null), AutoLockDelay.tenMinutes);
      expect(AutoLockDelay.fromMs(300000), AutoLockDelay.fiveMinutes);
      expect(AutoLockDelay.fromMs(0), AutoLockDelay.immediately);
      expect(AutoLockDelay.fromMs(12345), AutoLockDelay.tenMinutes);
    });
  });

  group('controller', () {
    late DateTime now;
    late List<_FakeTimer> timers;
    late int locks;
    late AutoLockDelay delay;
    late AutoLockController controller;

    void advance(Duration d) {
      now = now.add(d);
      for (final t in List.of(timers)) {
        if (!t.cancelled && !t.at.isAfter(now)) {
          t.cancelled = true;
          t.callback();
        }
      }
    }

    setUp(() {
      now = DateTime.utc(2026, 10, 18, 12);
      timers = [];
      locks = 0;
      delay = AutoLockDelay.fiveMinutes;
      controller = AutoLockController(
        delay: () => delay,
        onLock: () => locks++,
        clock: () => now,
        timerFactory: (d, cb) {
          final timer = _FakeTimer(now.add(d), cb);
          timers.add(timer);
          return timer;
        },
      );
      controller.start();
    });

    test('locks after the delay without a touch', () {
      advance(const Duration(minutes: 4, seconds: 59));
      expect(locks, 0);
      advance(const Duration(seconds: 2));
      expect(locks, 1);
      expect(controller.running, isFalse);
    });

    test('every touch restarts the delay', () {
      advance(const Duration(minutes: 4));
      controller.touch();
      advance(const Duration(minutes: 4));
      expect(locks, 0);
      advance(const Duration(minutes: 1, seconds: 1));
      expect(locks, 1);
    });

    test('time in the background counts, checked on return', () {
      advance(const Duration(minutes: 1));
      controller.backgrounded();
      // Timers do not run while iOS suspends the app.
      now = now.add(const Duration(minutes: 6));
      expect(locks, 0);
      controller.foregrounded();
      expect(locks, 1);
    });

    test('a short trip to the background does not lock', () {
      controller.backgrounded();
      now = now.add(const Duration(minutes: 2));
      controller.foregrounded();
      expect(locks, 0);
      expect(controller.running, isTrue);
    });

    test('immediately locks on leaving the app', () {
      delay = AutoLockDelay.immediately;
      controller.reschedule();
      advance(const Duration(hours: 2));
      expect(locks, 0);
      controller.backgrounded();
      expect(locks, 1);
    });

    test('a shorter delay applies at once', () {
      advance(const Duration(minutes: 2));
      delay = AutoLockDelay.oneMinute;
      controller.reschedule();
      expect(locks, 1);
    });

    test('stopped (locked by hand) means no second lock', () {
      controller.stop();
      advance(const Duration(hours: 1));
      controller.foregrounded();
      expect(locks, 0);
    });
  });
}
