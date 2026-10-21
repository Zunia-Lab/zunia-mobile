import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/password_throttle.dart';

import '../support/kernel.dart';

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon about';

/// Same schedule as extension 0.1.5: three free attempts, then 2 s doubling
/// to 5 minutes, persisted.
void main() {
  group('schedule', () {
    test('three free attempts, then 2 s doubling, capped at 5 min', () {
      expect(
        [for (var f = 1; f <= 12; f++) throttleDelay(f).inSeconds],
        [0, 0, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300],
      );
      expect(throttleDelay(1000), kPasswordMaxDelay);
    });

    test('recordFailure counts and sets the retry time', () {
      final t0 = DateTime.utc(2026, 10, 18, 12);
      var state = ThrottleState.empty;
      state = recordFailure(state, t0);
      state = recordFailure(state, t0);
      expect(state.isThrottledAt(t0), isFalse);
      state = recordFailure(state, t0);
      expect(state.failures, 3);
      expect(state.waitAt(t0), const Duration(seconds: 2));
      expect(state.isThrottledAt(t0.add(const Duration(seconds: 2))), isFalse);
    });

    test('a wait that ended reads as none; a clock set back is capped', () {
      final now = DateTime.utc(2026, 10, 18, 12);
      final ms = now.millisecondsSinceEpoch;
      expect(
        ThrottleState.decode('{"failures":4,"retryAt":${ms - 1}}', now),
        const ThrottleState(failures: 4),
      );
      final far = ThrottleState.decode(
        '{"failures":9,"retryAt":${ms + 3600 * 1000}}',
        now,
      );
      expect(far.waitAt(now), kPasswordMaxDelay);
      expect(ThrottleState.decode('garbage', now), ThrottleState.empty);
      expect(ThrottleState.decode(null, now), ThrottleState.empty);
    });
  });

  group('keystore', () {
    late MemorySecretStore store;
    late DateTime now;

    Keystore keystore() =>
        Keystore(secrets: store, runner: runInline, clock: () => now);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = MemorySecretStore();
      now = DateTime.utc(2026, 10, 18, 12);
      await keystore().createVault(phrase: _phrase, password: 'right password');
    });

    test('backs off after the third wrong password, across restarts', () async {
      for (var i = 0; i < 2; i++) {
        await expectLater(
          keystore().unlock('wrong'),
          throwsA(isA<WrongPasswordException>()
              .having((e) => e.wait, 'wait', Duration.zero)),
        );
      }
      await expectLater(
        keystore().unlock('wrong'),
        throwsA(isA<WrongPasswordException>()
            .having((e) => e.wait, 'wait', const Duration(seconds: 2))),
      );
      // Even the right password waits; a new Keystore (an app restart)
      // reads the same persisted state.
      await expectLater(
        keystore().unlock('right password'),
        throwsA(isA<PasswordThrottledException>()
            .having((e) => e.seconds, 'seconds', 2)),
      );
      now = now.add(const Duration(seconds: 2));
      await expectLater(
        keystore().unlock('wrong'),
        throwsA(isA<WrongPasswordException>()
            .having((e) => e.wait, 'wait', const Duration(seconds: 4))),
      );
      now = now.add(const Duration(seconds: 4));
      await keystore().unlock('right password');
      expect(await keystore().throttle(), ThrottleState.empty);
    }, skip: kernelSkip);

    test('every password check shares the throttle', () async {
      for (var i = 0; i < 3; i++) {
        await expectLater(
          keystore().verifyPassword('wrong'),
          throwsA(isA<WrongPasswordException>()),
        );
      }
      final ids = await keystore().phraseIds();
      await expectLater(
        keystore().revealPhrase(phraseId: ids.single, password: 'right password'),
        throwsA(isA<PasswordThrottledException>()),
      );
    }, skip: kernelSkip);

    test('parallel guesses are checked one at a time', () async {
      final ks = keystore();
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          ks.unlock('wrong $i').then<Object>((_) => 'ok', onError: (Object e) => e),
      ]);
      // Three counted as wrong, then the backoff refused the rest.
      expect(results.whereType<WrongPasswordException>(), hasLength(3));
      expect(results.whereType<PasswordThrottledException>(), hasLength(2));
    }, skip: kernelSkip);
  });
}
