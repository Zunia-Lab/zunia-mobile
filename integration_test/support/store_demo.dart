// A believable wallet for App Store and Google Play screenshots.
//
// The app reads the network with dart:io HttpClient. These overrides answer
// only the requests about the demo account (balances, staking, rewards,
// history) with fixed numbers; everything else (prices, validators,
// proposals, swap quotes, logos) goes to the real network, so the screens show
// live public data around a demo portfolio. Nothing here can sign or
// broadcast: the demo phrase is the public test phrase, and the numbers exist
// only inside this process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The account every demo request is about, as the 32 data characters its
/// bech32 addresses share on coin-type-118 chains.
class StoreDemo {
  StoreDemo(this.cosmosAddress)
    : data = cosmosAddress.substring('cosmos1'.length, 'cosmos1'.length + 32);

  final String cosmosAddress;
  final String data;

  final _validators = <String, Future<List<String>>>{};
  final Map<String, Map<String, Object?>> _txByHash = {};

  void install() => HttpOverrides.global = _DemoOverrides(this);

  static const _hours = Duration(hours: 1);

  /// Spendable balances, base units, by bech32 prefix.
  static const Map<String, Map<String, String>> _bank = {
    'cosmos': {'uatom': '248520000'},
    'osmo': {
      'uosmo': '3420750000',
      // ATOM moved to Osmosis over IBC.
      'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2':
          '12500000',
    },
    'celestia': {'utia': '520400000'},
    'addr_safro': {'usaf': '25000000000'},
  };

  /// Staked amounts (two validators each) and claimable rewards.
  static const Map<
    String,
    ({String denom, List<String> staked, String rewards})
  >
  _stake = {
    'cosmos': (
      denom: 'uatom',
      staked: ['800000000', '400000000'],
      rewards: '3842117.551',
    ),
    'celestia': (denom: 'utia', staked: ['300000000'], rewards: '1204410.2'),
    'osmo': (denom: 'uosmo', staked: ['1500000000'], rewards: '9310044.0'),
  };

  static const _prefixRest = {
    'cosmos': 'https://lcd-cosmoshub.keplr.app',
    'osmo': 'https://lcd-osmosis.keplr.app',
    'celestia': 'https://lcd-celestia.keplr.app',
    'addr_safro': 'https://api.safrochain.network',
  };

  /// Brands kept out of the pictures: exchanges and wallets that closed.
  static final _avoid = RegExp(
    r'binance|coinbase|kraken|okx|kucoin|huobi|htx|bitfinex|bybit|gate|upbit|bithumb|'
    r'cosmostation|leap|crypto\.com|mexc|robinhood',
    caseSensitive: false,
  );

  /// Answers a request about the demo account, or null to let it through.
  Future<({int status, Object? body})?> answer(Uri uri, HttpClient real) async {
    final url = uri.toString();
    final path = uri.path;

    final hashMatch = RegExp(
      r'/cosmos/tx/v1beta1/txs/([0-9A-F]{64})$',
    ).firstMatch(path);
    if (hashMatch != null) {
      final tx = _txByHash[hashMatch.group(1)];
      return tx == null ? null : (status: 200, body: tx);
    }

    if (!url.contains(data)) return null;
    final match = RegExp(
      '(?<![a-z0-9_])([a-z][a-z0-9_]*)1$data[02-9ac-hj-np-z]{6}',
    ).firstMatch(Uri.decodeFull(url));
    if (match == null) return null;
    final prefix = match.group(1)!;
    final me = match.group(0)!;

    if (path.contains('/cosmos/bank/v1beta1/balances/') ||
        path.contains('/cosmos/bank/v1beta1/spendable_balances/')) {
      final coins = _bank[prefix] ?? const <String, String>{};
      return (
        status: 200,
        body: {
          'balances': [
            for (final e in coins.entries) {'denom': e.key, 'amount': e.value},
          ],
          'pagination': {'next_key': null, 'total': '${coins.length}'},
        },
      );
    }

    final stake = _stake[prefix];
    if (path.contains('/cosmos/staking/v1beta1/delegations/')) {
      if (stake == null) {
        return (
          status: 200,
          body: {
            'delegation_responses': [],
            'pagination': {'next_key': null, 'total': '0'},
          },
        );
      }
      final validators = await _validatorsFor(prefix, real);
      return (
        status: 200,
        body: {
          'delegation_responses': [
            for (
              var i = 0;
              i < stake.staked.length && i < validators.length;
              i++
            )
              {
                'delegation': {
                  'delegator_address': me,
                  'validator_address': validators[i],
                  'shares': '${stake.staked[i]}.000000000000000000',
                },
                'balance': {'denom': stake.denom, 'amount': stake.staked[i]},
              },
          ],
          'pagination': {'next_key': null, 'total': '${stake.staked.length}'},
        },
      );
    }

    if (path.contains('/cosmos/distribution/v1beta1/delegators/') &&
        path.endsWith('/rewards')) {
      if (stake == null) {
        return (status: 200, body: {'rewards': [], 'total': []});
      }
      final validators = await _validatorsFor(prefix, real);
      final total = double.parse(stake.rewards);
      final count = stake.staked.length.clamp(1, validators.length);
      return (
        status: 200,
        body: {
          'rewards': [
            for (var i = 0; i < count; i++)
              {
                'validator_address': validators[i],
                'reward': [
                  {
                    'denom': stake.denom,
                    'amount': (total / count).toStringAsFixed(18),
                  },
                ],
              },
          ],
          'total': [
            {'denom': stake.denom, 'amount': total.toStringAsFixed(18)},
          ],
        },
      );
    }

    if (path.contains('/unbonding_delegations')) {
      return (
        status: 200,
        body: {
          'unbonding_responses': [],
          'pagination': {'next_key': null, 'total': '0'},
        },
      );
    }

    if (path.endsWith('/cosmos/tx/v1beta1/txs')) {
      final txs = await _history(prefix, me, real);
      return (
        status: 200,
        body: {
          'txs': [],
          'tx_responses': txs,
          'pagination': null,
          'total': '${txs.length}',
        },
      );
    }

    if (path.contains('/votes/')) {
      return (status: 404, body: {'code': 5, 'message': 'not found'});
    }

    // Anything else about the account (NFTs, authz, feegrants): empty.
    return null;
  }

  Future<List<String>> _validatorsFor(String prefix, HttpClient real) {
    return _validators.putIfAbsent(prefix, () async {
      final rest = _prefixRest[prefix];
      if (rest == null) return const [];
      try {
        final request = await real.getUrl(
          Uri.parse(
            '$rest/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED&pagination.limit=200',
          ),
        );
        final response = await request.close();
        final json =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;
        final rows = (json['validators'] as List).cast<Map<String, Object?>>()
          ..sort(
            (a, b) => BigInt.parse(
              '${b['tokens']}',
            ).compareTo(BigInt.parse('${a['tokens']}')),
          );
        final picked = <String>[];
        for (final row in rows.skip(2)) {
          final moniker = '${(row['description'] as Map?)?['moniker'] ?? ''}';
          if (moniker.isEmpty ||
              _avoid.hasMatch(moniker) ||
              row['jailed'] == true)
            continue;
          final rate =
              double.tryParse(
                '${(row['commission'] as Map?)?['commission_rates']?['rate'] ?? '1'}',
              ) ??
              1;
          if (rate > 0.1) continue;
          picked.add('${row['operator_address']}');
          if (picked.length == 3) break;
        }
        return picked;
      } catch (_) {
        return const [];
      }
    });
  }

  Map<String, Object?> _tx({
    required String hash,
    required DateTime at,
    required List<Map<String, Object?>> messages,
    required String feeDenom,
    String fee = '4200',
    String memo = '',
  }) {
    final response = {
      'height': '${24800000 + at.millisecondsSinceEpoch % 100000}',
      'txhash': hash,
      'codespace': '',
      'code': 0,
      'data': '',
      'raw_log': '',
      'logs': [],
      'info': '',
      'gas_wanted': '220000',
      'gas_used': '168214',
      'tx': {
        '@type': '/cosmos.tx.v1beta1.Tx',
        'body': {'messages': messages, 'memo': memo, 'timeout_height': '0'},
        'auth_info': {
          'signer_infos': [],
          'fee': {
            'amount': [
              {'denom': feeDenom, 'amount': fee},
            ],
            'gas_limit': '220000',
            'payer': '',
            'granter': '',
          },
        },
        'signatures': [],
      },
      'timestamp': at.toUtc().toIso8601String().replaceFirst(
        RegExp(r'\.\d+Z$'),
        'Z',
      ),
      'events': [],
    };
    _txByHash[hash] = {'tx': response['tx'], 'tx_response': response};
    return response;
  }

  static String _hash(String seed) {
    // Stable fake hashes: 64 hex characters from the seed.
    var h = 0xcbf29ce484222325;
    final out = StringBuffer();
    for (var round = 0; out.length < 64; round++) {
      for (final unit in '$seed#$round'.codeUnits) {
        h = ((h ^ unit) * 0x100000001b3) & 0xFFFFFFFFFFFFFFF;
      }
      out.write(h.toRadixString(16).toUpperCase().padLeft(15, '0'));
    }
    return out.toString().substring(0, 64);
  }

  Future<List<Map<String, Object?>>> _history(
    String prefix,
    String me,
    HttpClient real,
  ) async {
    final now = DateTime.now().toUtc();
    DateTime ago(int hours) => now.subtract(_hours * hours);
    final validators = await _validatorsFor(prefix, real);
    switch (prefix) {
      case 'cosmos':
        // Gaia v28.2.0, a plain upgrade proposal that passed.
        const proposal = 1055;
        return [
          _tx(
            hash: _hash('hub-claim'),
            at: ago(5),
            feeDenom: 'uatom',
            messages: [
              for (final v in validators.take(2))
                {
                  '@type':
                      '/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward',
                  'delegator_address': me,
                  'validator_address': v,
                },
            ],
          ),
          _tx(
            hash: _hash('hub-vote'),
            at: ago(19),
            feeDenom: 'uatom',
            messages: [
              {
                '@type': '/cosmos.gov.v1.MsgVote',
                'proposal_id': '$proposal',
                'voter': me,
                'option': 'VOTE_OPTION_YES',
                'metadata': '',
              },
            ],
          ),
          _tx(
            hash: _hash('hub-receive'),
            at: ago(31),
            feeDenom: 'uatom',
            messages: [
              {
                '@type': '/cosmos.bank.v1beta1.MsgSend',
                'from_address': 'cosmos1zg69v7ys40x77y352eufp27daufrg4ncnjqz7q',
                'to_address': me,
                'amount': [
                  {'denom': 'uatom', 'amount': '150000000'},
                ],
              },
            ],
          ),
          if (validators.length > 1)
            _tx(
              hash: _hash('hub-delegate'),
              at: ago(52),
              feeDenom: 'uatom',
              messages: [
                {
                  '@type': '/cosmos.staking.v1beta1.MsgDelegate',
                  'delegator_address': me,
                  'validator_address': validators[1],
                  'amount': {'denom': 'uatom', 'amount': '400000000'},
                },
              ],
            ),
          _tx(
            hash: _hash('hub-ibc'),
            at: ago(76),
            feeDenom: 'uatom',
            messages: [
              {
                '@type': '/ibc.applications.transfer.v1.MsgTransfer',
                'source_port': 'transfer',
                'source_channel': 'channel-141',
                'token': {'denom': 'uatom', 'amount': '12500000'},
                'sender': me,
                'receiver':
                    'osmo1${me.substring('cosmos1'.length, 'cosmos1'.length + 32)}',
                'timeout_height': {
                  'revision_number': '0',
                  'revision_height': '0',
                },
                'timeout_timestamp': '0',
                'memo': '',
              },
            ],
          ),
        ];
      case 'osmo':
        return [
          _tx(
            hash: _hash('osmo-swap'),
            at: ago(9),
            feeDenom: 'uosmo',
            fee: '8750',
            messages: [
              {
                '@type': '/osmosis.poolmanager.v1beta1.MsgSwapExactAmountIn',
                'sender': me,
                'routes': [
                  {
                    'pool_id': '1',
                    'token_out_denom':
                        'ibc/27394FB092D2ECCD56123C74F36E4C1F926001CEADA9CA97EA622B25F41E5EB2',
                  },
                ],
                'token_in': {'denom': 'uosmo', 'amount': '248750000'},
                'token_out_min_amount': '1',
              },
              {
                '@type': '/cosmos.bank.v1beta1.MsgSend',
                'from_address': me,
                'to_address': 'osmo1gv86dp8wmnmmatdckgr5xkevnpmy4662stl5rm',
                'amount': [
                  {'denom': 'uosmo', 'amount': '1250000'},
                ],
              },
            ],
          ),
          _tx(
            hash: _hash('osmo-receive'),
            at: ago(64),
            feeDenom: 'uosmo',
            messages: [
              {
                '@type': '/cosmos.bank.v1beta1.MsgSend',
                'from_address': 'osmo1zg69v7ys40x77y352eufp27daufrg4ncdqy5nd',
                'to_address': me,
                'amount': [
                  {'denom': 'uosmo', 'amount': '1200000000'},
                ],
              },
            ],
          ),
        ];
      case 'celestia':
        return [
          if (validators.isNotEmpty)
            _tx(
              hash: _hash('tia-delegate'),
              at: ago(40),
              feeDenom: 'utia',
              messages: [
                {
                  '@type': '/cosmos.staking.v1beta1.MsgDelegate',
                  'delegator_address': me,
                  'validator_address': validators.first,
                  'amount': {'denom': 'utia', 'amount': '300000000'},
                },
              ],
            ),
        ];
      case 'addr_safro':
        return [
          _tx(
            hash: _hash('saf-receive'),
            at: ago(27),
            feeDenom: 'usaf',
            fee: '2500',
            messages: [
              {
                '@type': '/cosmos.bank.v1beta1.MsgSend',
                'from_address':
                    'addr_safro1zg69v7ys40x77y352eufp27daufrg4nc8k5x0m',
                'to_address': me,
                'amount': [
                  {'denom': 'usaf', 'amount': '25000000000'},
                ],
              },
            ],
          ),
        ];
    }
    return const [];
  }
}

class _DemoOverrides extends HttpOverrides {
  _DemoOverrides(this.demo);
  final StoreDemo demo;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final real = super.createHttpClient(context);
    // A second real client for the demo's own live reads (validators,
    // proposals), so they never loop back through the overrides.
    return _DemoClient(real, demo, super.createHttpClient(context));
  }
}

class _DemoClient implements HttpClient {
  _DemoClient(this._real, this._demo, this._side);
  final HttpClient _real;
  final HttpClient _side;
  final StoreDemo _demo;

  Future<HttpClientRequest> _open(
    String method,
    Uri url,
    Future<HttpClientRequest> Function() pass,
  ) async {
    if (method == 'GET') {
      final answer = await _demo.answer(url, _side);
      if (answer != null)
        return _FakeRequest(method, url, answer.status, answer.body);
    }
    return pass();
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _open('GET', url, () => _real.getUrl(url));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _open(method.toUpperCase(), url, () => _real.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _real.postUrl(url);

  @override
  void close({bool force = false}) {
    _real.close(force: force);
    _side.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Settings (timeouts, user agent, proxies...) go to the real client.
    final name = invocation.memberName;
    if (invocation.isSetter) {
      final field = MirrorlessSetter.of(name);
      field?.call(_real, invocation.positionalArguments.first);
      return null;
    }
    return Function.apply(
      _forward(_real, name),
      invocation.positionalArguments,
      invocation.namedArguments,
    );
  }

  static Function _forward(HttpClient real, Symbol name) {
    switch (name) {
      case #idleTimeout:
        return () => real.idleTimeout;
      case #connectionTimeout:
        return () => real.connectionTimeout;
      case #maxConnectionsPerHost:
        return () => real.maxConnectionsPerHost;
      case #autoUncompress:
        return () => real.autoUncompress;
      case #userAgent:
        return () => real.userAgent;
      case #head:
        return real.head;
      case #headUrl:
        return real.headUrl;
      case #post:
        return real.post;
      case #put:
        return real.put;
      case #putUrl:
        return real.putUrl;
      case #delete:
        return real.delete;
      case #deleteUrl:
        return real.deleteUrl;
      case #patch:
        return real.patch;
      case #patchUrl:
        return real.patchUrl;
      case #addCredentials:
        return real.addCredentials;
      case #addProxyCredentials:
        return real.addProxyCredentials;
    }
    throw UnsupportedError('HttpClient.$name in the store demo');
  }
}

/// Setters on HttpClient, forwarded without dart:mirrors.
class MirrorlessSetter {
  static void Function(HttpClient, Object?)? of(Symbol name) {
    switch (name) {
      case const Symbol('idleTimeout='):
        return (c, v) => c.idleTimeout = v! as Duration;
      case const Symbol('connectionTimeout='):
        return (c, v) => c.connectionTimeout = v as Duration?;
      case const Symbol('maxConnectionsPerHost='):
        return (c, v) => c.maxConnectionsPerHost = v as int?;
      case const Symbol('autoUncompress='):
        return (c, v) => c.autoUncompress = v! as bool;
      case const Symbol('userAgent='):
        return (c, v) => c.userAgent = v as String?;
      case const Symbol('badCertificateCallback='):
        return (c, v) => c.badCertificateCallback =
            v as bool Function(X509Certificate, String, int)?;
      case const Symbol('findProxy='):
        return (c, v) => c.findProxy = v as String Function(Uri)?;
      case const Symbol('authenticate='):
        return (c, v) =>
            c.authenticate = v as Future<bool> Function(Uri, String, String?)?;
      case const Symbol('connectionFactory='):
        return (c, v) => c.connectionFactory =
            v as Future<ConnectionTask<Socket>> Function(Uri, String?, int?)?;
      case const Symbol('keyLog='):
        return (c, v) => c.keyLog = v as void Function(String)?;
    }
    return null;
  }
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri, this._status, this._body);

  @override
  final String method;
  @override
  final Uri uri;
  final int _status;
  final Object? _body;
  final _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResponse(_status, utf8.encode(jsonEncode(_body)));

  @override
  Future<HttpClientResponse> get done => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _FakeResponse(this.statusCode, List<int> bytes)
    : _length = bytes.length,
      super(Stream.value(bytes));

  @override
  final int statusCode;
  final int _length;

  @override
  int get contentLength => _length;

  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Not Found';

  @override
  HttpHeaders get headers => _FakeHeaders(json: true);

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  bool get persistentConnection => false;

  @override
  List<Cookie> get cookies => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders({this.json = false});
  final bool json;

  @override
  ContentType? get contentType => json ? ContentType.json : null;

  @override
  String? value(String name) => json && name.toLowerCase() == 'content-type'
      ? 'application/json; charset=utf-8'
      : null;

  @override
  List<String>? operator [](String name) {
    final v = value(name);
    return v == null ? null : [v];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    if (json) action('content-type', ['application/json; charset=utf-8']);
  }

  @override
  int get contentLength => -1;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
