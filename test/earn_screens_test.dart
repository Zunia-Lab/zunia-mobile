/// The Earn, Governance, Settings, Preferences, Networks, Notifications and
/// Address book screens, driven through the real widgets with the network
/// faked: what they show, what they refuse, and that they fit a 320dp phone
/// at 1.3× text on both platforms.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/notifications/chain_stream.dart';
import 'package:zunia_mobile/notifications/device_alerts.dart';
import 'package:zunia_mobile/notifications/notice_engine.dart';
import 'package:zunia_mobile/notifications/notifications.dart';
import 'package:zunia_mobile/notifications/notify_prefs.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/address_book_screen.dart';
import 'package:zunia_mobile/screens/governance_screen.dart';
import 'package:zunia_mobile/screens/networks_screen.dart';
import 'package:zunia_mobile/screens/notification_settings_screen.dart';
import 'package:zunia_mobile/screens/notifications_screen.dart';
import 'package:zunia_mobile/screens/preferences_screen.dart';
import 'package:zunia_mobile/screens/rewards_screen.dart';
import 'package:zunia_mobile/screens/settings_screen.dart';
import 'package:zunia_mobile/screens/tabs/earn_tab.dart';
import 'package:zunia_mobile/services/chain_client.dart';
import 'package:zunia_mobile/services/chain_reader.dart';
import 'package:zunia_mobile/services/governance_client.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/staking_client.dart';
import 'package:zunia_mobile/state/address_book.dart';
import 'package:zunia_mobile/state/chain_data.dart';
import 'package:zunia_mobile/state/governance.dart';
import 'package:zunia_mobile/state/preferences.dart';
import 'package:zunia_mobile/state/staking.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_mobile/ui/tx_flow.dart';
import 'package:zunia_ui/zunia_ui.dart';

const me = 'cosmos1qyyq79says4nyw2qga892hrrdfchsluxcqtzp4';

late ChainEntry hub;

StakingPosition position(String op, String moniker, String amount, String rewards) =>
    StakingPosition(
      chainId: 'cosmoshub-4',
      validatorAddress: op,
      moniker: moniker,
      identity: '',
      amount: BigInt.parse(amount),
      rewards: BigInt.parse(rewards),
      jailed: false,
      status: 'BOND_STATUS_BONDED',
    );

Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  List<Override> overrides = const [],
  Map<String, Object> prefs = const {},
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(320, 640),
  double textScale = 1.0,
}) async {
  SharedPreferences.setMockInitialValues({
    'zunia.prefs.liveReads': true,
    'zunia.wallet.enabledChains': ['cosmoshub-4'],
    ...prefs,
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chainAccountsProvider.overrideWithValue([ChainAccount(chain: hub, address: me)]),
        deviceAlertsProvider.overrideWithValue(RecordingDeviceAlerts(granted: false)),
        nativeConnectProvider.overrideWithValue(NativeConnectService()),
        pendingApprovalsProvider.overrideWith((ref) => Stream.value(const [])),
        ...overrides,
      ],
      child: MaterialApp(
        theme: ZuniaTheme.dark().copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Text in any case: Material segmented controls upper-case their labels.
Finder label(String text) => find.byWidgetPredicate(
      (w) => w is Text && w.data?.toLowerCase() == text.toLowerCase(),
    );

/// Overflow and other layout errors surface as exceptions in tests.
void expectNoLayoutErrors(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

Future<LcdResponse> govFetch(Uri uri, Duration _) async {
  if (uri.path.endsWith('/votes/$me')) {
    return LcdResponse(
      200,
      jsonEncode({
        'vote': {
          'options': [
            {'option': 'VOTE_OPTION_YES', 'weight': '1.0'},
          ],
        },
      }),
    );
  }
  if (uri.path.endsWith('/tally')) {
    return LcdResponse(200, jsonEncode({'tally': {'yes_count': '60', 'no_count': '40'}}));
  }
  if (uri.path == '/cosmos/gov/v1/proposals') {
    return LcdResponse(
      200,
      jsonEncode({
        'proposals': [
          for (var i = 30; i > 0; i--)
            {
              'id': '$i',
              'title': i == 30 ? 'Raise the gas floor' : 'Proposal number $i',
              'summary': '## Why\nBecause **gas**. See https://forum.cosmos.network/t/1',
              'status': i == 30
                  ? 'PROPOSAL_STATUS_VOTING_PERIOD'
                  : i.isEven
                      ? 'PROPOSAL_STATUS_PASSED'
                      : 'PROPOSAL_STATUS_REJECTED',
              'voting_end_time': DateTime.now()
                  .add(Duration(days: i == 30 ? 3 : -i))
                  .toUtc()
                  .toIso8601String(),
              'final_tally_result': {'yes_count': '7', 'no_count': '3'},
            },
        ],
        'pagination': {'next_key': null},
      }),
    );
  }
  return const LcdResponse(404, '{}');
}

/// The app's own fonts, so overflow checks measure real glyphs rather than
/// the test font, whose every glyph is a full em wide.
Future<void> loadAppFonts() async {
  const families = {
    'SpaceGrotesk': [
      'SpaceGrotesk-Light.ttf',
      'SpaceGrotesk-Regular.ttf',
      'SpaceGrotesk-Medium.ttf',
      'SpaceGrotesk-Bold.ttf',
    ],
    'JetBrainsMono': ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Medium.ttf'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      loader.addFont(rootBundle.load('assets/fonts/$file'));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
    await ChainCatalog.load();
    hub = ChainCatalog.instance.find('cosmoshub-4')!;
  });

  group('Earn', () {
    final positions = [
      position('cosmosvaloper1a', 'Alpha Validator With A Long Name', '12500000', '345678'),
      position('cosmosvaloper1b', 'Beta', '1000000', '0'),
    ];

    List<Override> earnOverrides({AprEstimate? apr}) => [
          stakingPositionsProvider.overrideWith((ref, id) async => positions),
          stakingUnbondingProvider.overrideWith((ref, id) async => const []),
          stakingValidatorsProvider.overrideWith((ref, id) async => const []),
          stakingParamsProvider.overrideWith(
            (ref, id) async => const StakingParams(
              unbondingTime: Duration(days: 21),
              bondDenom: 'uatom',
              maxValidators: 180,
            ),
          ),
          stakingAprProvider.overrideWith((ref, id) async => apr),
          balancesProvider.overrideWith((ref) async => const {}),
        ];

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('shows stake, rewards and positions (${platform.name})', (tester) async {
        await pumpScreen(
          tester,
          const EarnTab(),
          overrides: earnOverrides(),
          platform: platform,
          textScale: 1.3,
        );
        expectNoLayoutErrors(tester);
        expect(find.text('Earn'), findsOneWidget);
        expect(find.textContaining('13.5'), findsOneWidget);
        expect(find.text('Alpha Validator With A Long Name'), findsOneWidget);
        // Truncated, never rounded up: 345678 base units is 0.3456 at 4 places.
        expect(find.textContaining('+0.3456 ATOM rewards'), findsOneWidget);
        // No APR the chain parameters cannot back.
        expect(find.textContaining('APR'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('Network: Cosmos Hub')), findsOneWidget);
      });
    }

    testWidgets('a position opens with its terms; Unstake states the period', (tester) async {
      final validator = StakingValidator(
        chainId: 'cosmoshub-4',
        operatorAddress: 'cosmosvaloper1a',
        moniker: 'Alpha Validator With A Long Name',
        identity: '',
        commission: 0.05,
        maxCommission: 0.2,
        votingPower: 0.0123,
        tokens: BigInt.parse('9000000000000'),
        minSelfDelegation: BigInt.parse('1000000'),
        website: 'alpha.example',
        details: 'Runs nodes.',
        jailed: false,
        status: 'BOND_STATUS_BONDED',
      );
      await pumpScreen(
        tester,
        const EarnTab(),
        overrides: [
          ...earnOverrides(),
          stakingValidatorsProvider.overrideWith((ref, id) async => [validator]),
        ],
        textScale: 1.3,
      );
      await tester.tap(find.text('Alpha Validator With A Long Name'));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester);
      expect(find.text('Max commission'), findsOneWidget);
      expect(find.text('alpha.example'), findsOneWidget);
      await tester.tap(find.text('Unstake'));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester);
      expect(find.text('21 days'), findsOneWidget);
      // MAX fills the whole position for an unstake: there is no fee reserve
      // to keep out of staked tokens.
      await tester.tap(find.bySemanticsLabel('Maximum'));
      await tester.pumpAndSettle();
      expect(find.text('12.5'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
    });

    testWidgets('an honest APR shows with its working one tap away', (tester) async {
      await pumpScreen(
        tester,
        const EarnTab(),
        overrides: earnOverrides(
          apr: const AprEstimate(apr: 0.18, inflation: 0.1, communityTax: 0.1, bondedRatio: 0.5),
        ),
      );
      expect(find.text('≈ 18.0%'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(RegExp('Estimated APR')));
      await tester.pumpAndSettle();
      expect(find.textContaining('inflation × (1 − community tax)'), findsOneWidget);
    });

    testWidgets('live reads off reads nothing and says how to change it', (tester) async {
      await pumpScreen(
        tester,
        const EarnTab(),
        prefs: const {'zunia.prefs.liveReads': false},
        overrides: [
          stakingPositionsProvider.overrideWith(
            (ref, id) async => throw StateError('must not read'),
          ),
        ],
      );
      expectNoLayoutErrors(tester);
      expect(find.text('Live reads are off'), findsOneWidget);
      expect(find.text('Open Preferences'), findsOneWidget);
    });
  });

  group('Governance', () {
    List<Override> gov() => [
          governanceClientProvider.overrideWithValue(
            GovernanceClient(ChainReader(readsAllowed: () => true, fetch: govFetch)),
          ),
        ];

    testWidgets('lists open votes first, filters, and pages as it scrolls', (tester) async {
      await pumpScreen(tester, const GovernanceScreen(), overrides: gov(), textScale: 1.3);
      expectNoLayoutErrors(tester);
      expect(find.text('Raise the gas floor'), findsOneWidget);
      expect(find.text('VOTED YES'), findsOneWidget);
      expect(find.text('1 open'), findsOneWidget);
      // Ten rows at first; scrolling to the end shows more.
      expect(find.text('Proposal number 20'), findsNothing);
      await tester.dragUntilVisible(
        find.text('Proposal number 20'),
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      expect(find.text('Proposal number 20'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Rejected'),
        find.byType(CustomScrollView),
        const Offset(0, 300),
      );
      await tester.tap(find.text('Rejected'));
      await tester.pumpAndSettle();
      expect(find.text('Raise the gas floor'), findsNothing);
      expect(find.text('Proposal number 29'), findsOneWidget);
    });

    testWidgets('a proposal opens with its text rendered as text and your vote', (tester) async {
      await pumpScreen(tester, const GovernanceScreen(), overrides: gov());
      await tester.tap(find.text('Raise the gas floor'));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester);
      expect(find.text('Proposal #30'), findsOneWidget);
      expect(find.text('You voted Yes'), findsOneWidget);
      expect(find.text('Yes leading'), findsOneWidget);
      // Markdown heading rendered without the hashes.
      expect(find.text('Why'), findsOneWidget);
      // Change the vote: the ballot appears.
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(RegExp('^No\\. Reject')));
      await tester.pumpAndSettle();
      expect(find.text('Review vote · No'), findsOneWidget);
    });
  });

  group('Settings', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('groups every area and states the build (${platform.name})', (tester) async {
        await pumpScreen(tester, const SettingsScreen(), platform: platform, textScale: 1.3);
        expectNoLayoutErrors(tester);
        for (final row in ['Accounts', 'Networks', 'Address book', 'Connected apps', 'Preferences', 'Notifications']) {
          await tester.dragUntilVisible(
            find.text(row),
            find.byType(CustomScrollView),
            const Offset(0, -120),
          );
          expect(find.text(row), findsOneWidget, reason: row);
        }
        await tester.dragUntilVisible(
          find.text('Open-source licenses'),
          find.byType(CustomScrollView),
          const Offset(0, -300),
        );
        expect(find.text('Version'), findsOneWidget);
        expect(find.text('0.1.0'), findsOneWidget);
        expect(find.textContaining('Matches Zunia extension 0.1.5'), findsOneWidget);
      });
    }
  });

  group('Preferences', () {
    testWidgets('offers the five currencies, no diagnostics, and gates artwork', (tester) async {
      await pumpScreen(tester, const PreferencesScreen(), textScale: 1.3);
      expectNoLayoutErrors(tester);
      expect(find.textContaining('iagnostic'), findsNothing);
      expect(label('Auto'), findsOneWidget);
      await tester.tap(find.text('Currency'));
      await tester.pumpAndSettle();
      for (final code in supportedCurrencies) {
        expect(find.textContaining('$code ·'), findsOneWidget);
      }
      expect(find.textContaining('NGN'), findsNothing);
      await tester.tap(find.textContaining('CHF ·'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(PreferencesScreen)));
      expect(container.read(preferencesProvider).currency, 'CHF');

      await tester.tap(find.text('Live reads'));
      await tester.pumpAndSettle();
      expect(container.read(preferencesProvider).liveReads, isFalse);
      expect(find.text('Turn on live reads first'), findsOneWidget);
    });

    test('an old currency the app no longer offers reads back as USD', () async {
      SharedPreferences.setMockInitialValues({'zunia.prefs.currency': 'NGN'});
      expect((await readStoredPreferences()).currency, 'USD');
    });

    test('nothing reads before the stored choice is known', () async {
      SharedPreferences.setMockInitialValues({'zunia.prefs.liveReads': false});
      final controller = PreferencesController();
      expect(controller.state.liveReads, isFalse);
      expect(controller.state.loaded, isFalse);
      await controller.ready;
      expect(controller.state.liveReads, isFalse);
      expect(controller.state.loaded, isTrue);
    });
  });

  group('Notifications', () {
    testWidgets('quiet defaults, and choices persist', (tester) async {
      await pumpScreen(tester, const NotificationSettingsScreen(), textScale: 1.3);
      expectNoLayoutErrors(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotificationSettingsScreen)),
      );
      expect(container.read(notifyPrefsProvider), NotifyPrefs.defaults);
      expect(find.text('Approvals always show: a site is waiting on each one.'), findsOneWidget);
      await tester.ensureVisible(label('Weekly'));
      await tester.pumpAndSettle();
      await tester.tap(label('Weekly'));
      await tester.pumpAndSettle();
      expect(container.read(notifyPrefsProvider).rewards, RewardReminder.weekly);
      final stored = (await SharedPreferences.getInstance()).getString('zunia.notify.prefs')!;
      expect(jsonDecode(stored)['rewards'], 'weekly');
    });
  });

  group('Networks', () {
    testWidgets('pinned chains first, testnets apart, one network always kept', (tester) async {
      await pumpScreen(tester, const NetworksScreen(), textScale: 1.3);
      expectNoLayoutErrors(tester);
      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      final pinned = ['Safrochain', 'Cosmos Hub', 'Osmosis']
          .map((n) => names.indexWhere((x) => x == n))
          .toList();
      expect(pinned.every((i) => i >= 0), isTrue, reason: '$pinned');
      expect(pinned, [...pinned]..sort());
      expect(find.textContaining('Mainnets'), findsOneWidget);

      // Turning off the only enabled network is refused with a reason.
      await tester.tap(find.text('Cosmos Hub'));
      await tester.pumpAndSettle();
      expect(find.text('Keep one network'), findsOneWidget);
    });
  });

  group('Notifications feed', () {
    testWidgets('shows notices, filters by kind and marks read', (tester) async {
      Future<LcdResponse> fetch(Uri uri, Duration _) async {
        if (uri.path.endsWith('/rewards')) {
          return LcdResponse(200, jsonEncode({'total': [{'denom': 'uatom', 'amount': '5000000'}]}));
        }
        if (uri.path.endsWith('/unbonding_delegations')) {
          return LcdResponse(200, jsonEncode({'unbonding_responses': []}));
        }
        return govFetch(uri, const Duration(seconds: 1));
      }

      // Built by the provider, in the widget test's zone, so its storage
      // read completes while the test pumps.
      late NoticeEngine engine;
      NoticeEngine build() => engine = NoticeEngine(
        alerts: RecordingDeviceAlerts(granted: false),
        reader: ChainReader(readsAllowed: () => true, fetch: fetch),
        openStream: ({
          required chainId,
          required rpc,
          required subscriptions,
          required onTx,
          required onState,
        }) =>
            ChainStream(
              chainId: chainId,
              rpc: rpc,
              subscriptions: subscriptions,
              onTx: onTx,
              connect: (_) => Completer<WebSocket>().future,
            ),
        observeLifecycle: false,
      );
      await pumpScreen(
        tester,
        const NotificationsScreen(),
        textScale: 1.3,
        prefs: {
          'zunia.notify.prefs': jsonEncode({'governance': true}),
        },
        overrides: [
          noticeEngineProvider.overrideWith((ref) => build()),
          allActivityProvider.overrideWith((ref) async => const []),
        ],
      );
      await tester.runAsync(() => engine.update(
            NoticeEngineInputs(
              accounts: [WatchedChain(hub, me)],
              accountIndex: 0,
              liveReads: true,
              prefs: NotifyPrefs.defaults.copyWith(governance: true),
            ),
          ));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester);
      expect(find.text('Staking rewards ready to claim'), findsOneWidget);
      expect(find.text('Proposal 30 ends in 3d'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Governance'),
        find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
        ),
        const Offset(-120, 0),
      );
      await tester.tap(find.text('Governance'));
      await tester.pumpAndSettle();
      expect(find.text('Staking rewards ready to claim'), findsNothing);
      expect(engine.state.unread, 2);
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(engine.state.unread, 0);
      expect(find.text('Mark all read'), findsNothing);
    });
  });

  group('Review', () {
    testWidgets('a transaction that cannot be prepared says why and cannot be signed', (tester) async {
      await pumpScreen(
        tester,
        TxReviewScreen(
          intent: TxIntent(
            title: 'Review stake',
            action: 'Sign stake',
            chain: hub,
            signer: me,
            msgs: stakeMsgs(
              delegator: me,
              validator: 'cosmosvaloper1a',
              denom: 'uatom',
              amount: BigInt.from(1500000),
            ),
            headlineLabel: 'You stake',
            headline: '1.5 ATOM',
            headlineLine: 'With Alpha · Cosmos Hub',
            facts: const [(label: 'Unbonding period', value: '21 days')],
            notice: 'Locked for 21 days after unstaking.',
            result: const TxResultCopy(
              sending: 'Staking',
              done: 'Staked',
              failed: 'Stake failed',
              doneMessage: 'Done.',
            ),
          ),
        ),
        textScale: 1.3,
      );
      expectNoLayoutErrors(tester);
      expect(find.text('1.5 ATOM'), findsOneWidget);
      // Locked: no phrase, so nothing is quoted or signed.
      expect(find.text('This transaction cannot be prepared'), findsOneWidget);
      expect(find.textContaining('Unlock the wallet'), findsOneWidget);
      expect(find.text('Cannot sign yet'), findsOneWidget);
    });
  });

  group('Rewards', () {
    testWidgets('lists each network with something to claim', (tester) async {
      await pumpScreen(
        tester,
        const RewardsScreen(),
        textScale: 1.3,
        overrides: [
          stakingPositionsProvider.overrideWith(
            (ref, id) async => [position('cosmosvaloper1a', 'Alpha', '1', '2500000')],
          ),
        ],
      );
      expectNoLayoutErrors(tester);
      expect(find.text('Cosmos Hub'), findsOneWidget);
      expect(find.textContaining('2.5 ATOM'), findsOneWidget);
      expect(find.text('Claim'), findsOneWidget);
    });
  });

  group('Address book', () {
    testWidgets('validates as you type and saves a contact', (tester) async {
      await pumpScreen(tester, const AddressBookScreen(), textScale: 1.3);
      expectNoLayoutErrors(tester);
      expect(find.text('No saved addresses'), findsOneWidget);
      await tester.tap(find.text('Add contact'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Treasury');
      await tester.enterText(find.byType(TextField).at(1), '${me.substring(0, me.length - 1)}5');
      await tester.pump();
      expect(find.textContaining('typo'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), me);
      await tester.pump();
      expect(find.textContaining('Valid address'), findsOneWidget);
      await tester.tap(find.text('Save contact'));
      await tester.pumpAndSettle();
      expect(find.text('Treasury'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(AddressBookScreen)));
      expect(container.read(addressBookProvider).single.address, me);
    });

    testWidgets('pick mode offers only contacts usable on the target', (tester) async {
      await pumpScreen(
        tester,
        const AddressBookScreen(pickMode: true, prefixFilter: 'osmo'),
        prefs: {
          'zunia.addressBook': jsonEncode([
            {'id': '1', 'label': 'Hub friend', 'address': me},
            {'id': '2', 'label': 'Osmo desk', 'address': 'osmo1qyyq79says4nyw2qga892hrrdfchsluxsmcjh8'},
          ]),
        },
      );
      expect(find.text('Osmo desk'), findsOneWidget);
      expect(find.text('Hub friend'), findsNothing);
    });
  });

  test('a chain read error says what happened, not that the account is empty', () {
    const e = ChainReadError(ChainReadErrorKind.unreachable, 'x');
    expect(e.userMessage, contains('did not answer'));
    expect(e.userMessage, isNot(contains('no ')));
    // Balance failures from the portfolio's client keep their own wording.
    expect(const ChainReadFailure(ChainReadFailureKind.timedOut).message, isNotEmpty);
  });
}
