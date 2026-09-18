/// The gallery's honesty behaviours, driven through the real screen.
///
/// The defect these pin is the one the audit found: a mobile NFT tab that said
/// "you own no NFTs" when nothing had been queried. CosmWasm has no chain-wide
/// index of NFTs by owner, so "nothing was asked" and "nothing was found" are
/// different facts and this screen must never merge them.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/screens/nft_collection_screen.dart';
import 'package:zunia_mobile/services/interchain/lcd.dart';
import 'package:zunia_mobile/services/interchain/nft.dart';
import 'package:zunia_mobile/services/interchain/types.dart';
import 'package:zunia_mobile/state/interchain.dart';
import 'package:zunia_mobile/state/nft.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

const _chainId = 'safrochain-1';
const _owner = 'addr_safro1owner00000000000000000000000000000';
const _collection = 'addr_safro1collection00000000000000000000000';

const _chainInfo = ChainInfo(
  chainId: _chainId,
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinMinimalDenom: 'usafro',
  features: ['cosmwasm'],
  rest: 'https://lcd.safro.example',
);

final _entry = ChainEntry(
  chainId: _chainId,
  chainName: 'Safrochain',
  bech32Prefix: 'addr_safro',
  coinType: 118,
  network: 'testnet',
  coinDenom: 'SAFRO',
  coinMinimalDenom: 'usafro',
  coinDecimals: 6,
  feeDenom: 'SAFRO',
  feeMinimalDenom: 'usafro',
  feeDecimals: 6,
  // Unroutable on purpose: a widget test must never open a socket.
  rest: 'http://127.0.0.1:1',
);

class _FakeRegistry implements ChainRegistry {
  const _FakeRegistry();

  @override
  ChainInfo? get(String chainId) => chainId == _chainId ? _chainInfo : null;

  @override
  List<ChainInfo> list() => const [_chainInfo];
}

final RegExp _smartPath =
    RegExp(r'^/cosmwasm/wasm/v1/contract/([^/]+)/smart/(.+)$');

/// Answers CW721 smart queries from a handler, so the screen runs the real
/// discovery code without a socket.
class _StubLcd implements LcdClient {
  _StubLcd(this._handler);

  final Object? Function(String contract, String action) _handler;

  @override
  final String chainId = _chainId;

  final List<String> actions = [];

  @override
  Future<Object?> getJson(String path, [LcdRequestOptions? options]) async {
    final match = _smartPath.firstMatch(path)!;
    final contract = Uri.decodeComponent(match.group(1)!);
    final encoded = match.group(2)!;
    final padding = (4 - encoded.length % 4) % 4;
    final query = jsonDecode(
      utf8.decode(base64Url.decode(encoded + ('=' * padding))),
    ) as Map<String, Object?>;
    final action = query.keys.first;
    actions.add('$contract/$action');
    return <String, Object?>{'data': _handler(contract, action)};
  }
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    NftChainSupport? support,
    LcdClient? lcd,
    Map<String, Object> prefs = const {},
    Map<String, List<String>> userCollections = const {},
    Size size = const Size(320, 640),
  }) async {
    SharedPreferences.setMockInitialValues({
      ...prefs,
      if (userCollections.isNotEmpty)
        'zunia.nft.collections': jsonEncode(userCollections),
    });

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interchainRegistryProvider.overrideWithValue(const _FakeRegistry()),
          chainAccountsProvider.overrideWithValue(
            [ChainAccount(chain: _entry, address: _owner)],
          ),
          nftChainSupportProvider.overrideWith(
            (ref, chainId) async =>
                support ??
                const NftChainSupport(
                  chainId: _chainId,
                  state: NftChainSupportState.supported,
                  reason: null,
                  evidence: 'test',
                ),
          ),
          nftContextProvider.overrideWith(
            (ref, chainId) async => lcd == null
                ? null
                : NftChainContext(
                    chain: _chainInfo,
                    lcd: lcd,
                    allowUnknownFeatures: true,
                  ),
          ),
        ],
        child: MaterialApp(
          theme: ZuniaTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(12),
              child: NftGalleryView(chainId: _chainId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing to query it says nothing was queried, not that the '
      'account is empty', (tester) async {
    final lcd = _StubLcd((_, _) => const {'tokens': <String>[]});
    await pump(
      tester,
      lcd: lcd,
      prefs: const {'zunia.prefs.liveReads': true},
    );

    expect(find.text('Nothing was checked'), findsOneWidget);
    expect(
      find.textContaining('no chain-wide index of NFTs by owner'),
      findsWidgets,
    );
    // The load-bearing assertion: not one wasm query was made, so no sentence
    // on screen may be a claim about the account.
    expect(lcd.actions, isEmpty);
    expect(find.textContaining('you own no'), findsNothing);
    expect(find.textContaining('No NFTs'), findsNothing);
  });

  testWidgets('an empty answer says how many collections were read',
      (tester) async {
    final lcd = _StubLcd((_, _) => const {'tokens': <String>[]});
    await pump(
      tester,
      lcd: lcd,
      prefs: const {'zunia.prefs.liveReads': true},
      userCollections: const {
        _chainId: [_collection],
      },
    );

    expect(lcd.actions, contains('$_collection/tokens'));
    expect(find.text('Nothing in the collections checked'), findsOneWidget);
    expect(find.textContaining('queried 1 collection'), findsOneWidget);
  });

  testWidgets('a chain without CosmWasm explains itself instead of showing an '
      'empty gallery', (tester) async {
    await pump(
      tester,
      support: const NftChainSupport(
        chainId: _chainId,
        state: NftChainSupportState.unsupported,
        reason: 'Testchain does not run CosmWasm, so no CW721 contract can '
            'exist on it.',
        evidence: 'registry features',
      ),
      prefs: const {'zunia.prefs.liveReads': true},
    );

    expect(find.text('NFTs are not available on this chain'), findsOneWidget);
    expect(find.textContaining('does not run CosmWasm'), findsOneWidget);
  });

  testWidgets('unknown CosmWasm support is neither a yes nor a no',
      (tester) async {
    await pump(
      tester,
      support: const NftChainSupport(
        chainId: _chainId,
        state: NftChainSupportState.unknown,
        reason: 'The bundled chain catalog drops the registry feature list.',
        evidence: 'no features',
      ),
      prefs: const {'zunia.prefs.liveReads': true},
    );

    expect(find.text('Zunia cannot tell yet'), findsOneWidget);
    // Never the unsupported wording, which would be a claim about the chain.
    expect(find.text('NFTs are not available on this chain'), findsNothing);
  });

  testWidgets('live reads off means nothing was read, and says so',
      (tester) async {
    final lcd = _StubLcd((_, _) => const {'tokens': <String>[]});
    await pump(tester, lcd: lcd);

    expect(find.text('Nothing was read'), findsOneWidget);
    expect(lcd.actions, isEmpty);
  });

  testWidgets('artwork is off by default and the switch says what it costs',
      (tester) async {
    final lcd = _StubLcd((contract, action) => switch (action) {
          'tokens' => const {'tokens': ['1']},
          'all_nft_info' => const {
              'access': {'owner': _owner, 'approvals': <Object?>[]},
              'info': {
                'token_uri': null,
                'extension': {'name': 'Zebra', 'image': 'https://img.test/1'},
              },
            },
          _ => const {'name': 'Zebras', 'symbol': 'ZEB'},
        });
    await pump(
      tester,
      lcd: lcd,
      prefs: const {'zunia.prefs.liveReads': true},
      userCollections: const {
        _chainId: [_collection],
      },
    );

    expect(find.text('Show artwork'), findsOneWidget);
    expect(find.text(kZuniaNftMediaPrivacyNote), findsOneWidget);
    // The switch is real: with media off there is no Image widget at all, so
    // nothing is requested from the image host.
    expect(find.byType(Image), findsNothing);
    // The token is still listed. Artwork being off is not the same as the
    // token being absent.
    expect(find.text('Zebra'), findsOneWidget);
  });

  testWidgets('a collection that will not answer is reported, not swallowed',
      (tester) async {
    final lcd = _StubLcd((contract, action) {
      if (action == 'tokens') {
        throw InterchainError(
          InterchainErrorCode.contractError,
          'not a cw721',
        );
      }
      return const <String, Object?>{};
    });
    await pump(
      tester,
      lcd: lcd,
      prefs: const {'zunia.prefs.liveReads': true},
      userCollections: const {
        _chainId: [_collection],
      },
    );

    expect(find.text('A collection could not be read'), findsOneWidget);
    expect(find.textContaining('not a cw721'), findsOneWidget);
  });

  testWidgets('an address for another chain is refused before it is stored',
      (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});

    await tester.enterText(find.byType(TextField).first, 'osmo1abcdefghij');
    await tester.ensureVisible(find.text('Check this collection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check this collection'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('does not start with "addr_safro1"'),
      findsOneWidget,
    );
    expect(find.text('ADDED BY YOU'), findsNothing);
  });

  testWidgets('renders at 320dp and in landscape without overflowing',
      (tester) async {
    final lcd = _StubLcd((contract, action) => switch (action) {
          'tokens' => const {'tokens': ['1', '2', '3']},
          'all_nft_info' => const {
              'access': {'owner': _owner, 'approvals': <Object?>[]},
              'info': {'token_uri': null, 'extension': {'name': 'Zebra'}},
            },
          _ => const {'name': 'Zebras', 'symbol': 'ZEB'},
        });
    await pump(
      tester,
      lcd: lcd,
      prefs: const {'zunia.prefs.liveReads': true},
      userCollections: const {
        _chainId: [_collection],
      },
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('every control the user can reach carries a label',
      (tester) async {
    await pump(tester, prefs: const {'zunia.prefs.liveReads': true});
    final handle = tester.ensureSemantics();

    for (final node in _semanticNodes(tester)) {
      // A node merged into its parent is not exposed to the platform on its
      // own; the parent carries the name. Checking it separately would fail on
      // the bare Checkbox inside a labelled ZuniaCheckbox.
      if (node.isMergedIntoParent) continue;
      final data = node.getSemanticsData();
      if (!data.hasAction(SemanticsAction.tap)) continue;
      expect(
        data.label.trim().isNotEmpty || data.tooltip.trim().isNotEmpty,
        isTrue,
        reason: 'a tappable node with no accessible name: $data',
      );
    }
    handle.dispose();
  });
}

/// The semantics root.
///
/// Found by walking the pipeline-owner tree rather than through
/// `binding.pipelineOwner`, which is deprecated: the owner that actually holds
/// the semantics tree is a child of the root owner, and the root's own
/// `semanticsOwner` is null.
SemanticsNode? _rootSemantics(WidgetTester tester) {
  SemanticsNode? found;
  void visit(PipelineOwner owner) {
    found ??= owner.semanticsOwner?.rootSemanticsNode;
    owner.visitChildren(visit);
  }

  visit(tester.binding.rootPipelineOwner);
  return found;
}

List<SemanticsNode> _semanticNodes(WidgetTester tester) {
  final out = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    out.add(node);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(_rootSemantics(tester)!);
  return out;
}
