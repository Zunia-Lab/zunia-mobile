// Amino messages a dApp builds, in the kernel's own words.
//
// A port of zunia-core's `crates/cosmos/src/dapp.rs`: the same sentences, the
// same `recipient` and addresses, and the same reasons to refuse to describe a
// message. A message the kernel would not read (a pool id of 0, ticks out of
// order, an address of another chain...) is "unknown" here too, so the sign
// mode a site picks changes neither what the user reads nor what is gated.
//
// What Amino JSON does differently from the proto the kernel reads:
//
// - ids, ticks and heights are strings;
// - `liquidity_amount` and vote weights are decimal strings, which the kernel
//   shows as 18-place decimals (`0.700000000000000000`);
// - a lock's `duration` is nanoseconds, shown in whole seconds, and a duration
//   that is not a whole number of seconds is not described;
// - empty fields are left out (`coins: []`, `admin: ""`), and absence means
//   what empty means to the kernel;
// - `salt` is base64, shown as hex.
//
// Deliberately absent, as in the kernel: authz MsgGrant and MsgExec, feegrant
// MsgGrantAllowance, wasm MsgStoreCode, gov MsgSubmitProposal and the Osmosis
// smartaccount messages. They hand control of the account to someone else or
// run messages nobody has read, so they stay unknown.
part of 'sign_review.dart';

final _int64Max = (BigInt.one << 63) - BigInt.one;
final _int64Min = -(BigInt.one << 63);
final _billion = BigInt.from(1000000000);
final _decOne = BigInt.from(10).pow(18);

/// An `int64` as Amino writes it: a canonical decimal string, in range.
String? _int64(Object? value) {
  if (value is! String || !RegExp(r'^(?:0|-?[1-9]\d{0,18})$').hasMatch(value)) return null;
  final number = BigInt.parse(value);
  return number >= _int64Min && number <= _int64Max ? value : null;
}

/// The integer a decimal string stands for scaled by 10^18, as the kernel
/// reads a plain decimal (`0.5` -> `500000000000000000`). At most 18 places.
String? _scaledDecimal(Object? value) {
  if (value is! String) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d{1,18}))?$').firstMatch(value);
  if (match == null) return null;
  final digits = BigInt.parse('${match.group(1)}${(match.group(2) ?? '').padRight(18, '0')}');
  final text = digits.toString();
  return text.length <= 78 ? text : null;
}

/// `500000000000000000` -> `0.500000000000000000`: the decimal the LCD shows.
String _decimalShown(String scaled) {
  final padded = scaled.padLeft(19, '0');
  return '${padded.substring(0, padded.length - 18)}.${padded.substring(padded.length - 18)}';
}

/// A coin list: absent or null is empty, as Amino omits it. Between [min] and
/// [max] coins, each valid and above zero, no denom twice.
List<FeeCoin>? _coinList(Object? value, {int min = 0, int max = 64}) {
  if (value == null) return min == 0 ? const [] : null;
  if (value is! List) return null;
  if (value.length < min || value.length > max) return null;
  final coins = <FeeCoin>[];
  for (final item in value) {
    final coin = _coin(item, aboveZero: true);
    if (coin == null || coins.any((other) => other.denom == coin.denom)) return null;
    coins.add(coin);
  }
  return coins;
}

String _coinsWords(List<FeeCoin> coins) => coins.map(_coinWords).join(', ');

/// At least one id, none of them zero, none twice.
List<String>? _ids(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final ids = <String>[];
  for (final item in value) {
    final id = _id(item);
    if (id == null || ids.contains(id)) return null;
    ids.add(id);
  }
  return ids;
}

String _positionsWords(List<String> ids) => '${ids.length == 1 ? 'position' : 'positions'} ${ids.join(', ')}';

/// A message type URL that is safe to quote.
bool _plainTypeUrl(Object? value) =>
    value is String && value.length <= 256 && RegExp(r'^/[A-Za-z0-9._]+$').hasMatch(value);

/// An address the kernel would take as a [derived] one: 20 or 32 bytes, under
/// the prefix of the signer, which is the first of [accounts].
bool _addressesOfThisChain(List<Object?> accounts, [List<Object?> derived = const []]) {
  for (final account in accounts) {
    if (_account(account) == null) return false;
  }
  if (accounts.isEmpty) return derived.isEmpty;
  final prefix = shownAddressPrefix(accounts.first);
  if (prefix == null) return false;
  return derived.every((address) => shownAddressPrefix(address) == prefix);
}

/// A contract message: any JSON object or array, as the chain's Amino JSON
/// holds it.
bool _contractMessage(Object? value) => value is Map || value is List;

/// One entry of a multi-send: an address and its coins.
({String address, List<FeeCoin> coins})? _entry(Object? value) {
  final entry = _fields(value);
  if (entry == null) return null;
  final address = _renderable(entry['address']);
  final coins = _coinList(entry['coins'], min: 1);
  return address == null || coins == null ? null : (address: address, coins: coins);
}

List<({String address, List<FeeCoin> coins})>? _entries(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final out = <({String address, List<FeeCoin> coins})>[];
  for (final item in value) {
    final entry = _entry(item);
    if (entry == null) return null;
    out.add(entry);
  }
  return out;
}

Map<String, BigInt> _totals(List<({String address, List<FeeCoin> coins})> entries) {
  final sums = <String, BigInt>{};
  for (final entry in entries) {
    for (final coin in entry.coins) {
      sums[coin.denom] = (sums[coin.denom] ?? BigInt.zero) + BigInt.parse(coin.amount);
    }
  }
  return sums;
}

bool _sameTotals(Map<String, BigInt> a, Map<String, BigInt> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

_Description? _multiSend(Map<String, dynamic> value) {
  final inputs = _entries(value['inputs']);
  final outputs = _entries(value['outputs']);
  if (inputs == null || outputs == null) return null;
  if (!_sameTotals(_totals(inputs), _totals(outputs))) return null;
  if (!_addressesOfThisChain(
    [for (final input in inputs) input.address],
    [for (final output in outputs) output.address],
  )) {
    return null;
  }
  final inputAddresses = inputs.map((i) => i.address).toSet();
  final others = outputs.map((o) => o.address).where((a) => !inputAddresses.contains(a)).toList();
  final recipient = others.isNotEmpty && others.every((a) => a == others.first) ? others.first : null;
  List<Object?> shown(List<({String address, List<FeeCoin> coins})> entries) => [
    for (final e in entries)
      {
        'address': e.address,
        'coins': [for (final c in e.coins) c.toJson()],
      },
  ];
  return _said(
    'Send ${outputs.map((o) => '${_coinsWords(o.coins)} to ${o.address}').join('; ')} '
    'in one multi-send paid by ${inputs.map((i) => '${i.address} (${_coinsWords(i.coins)})').join('; ')}',
    recipient: recipient,
    detail: {'kind': 'multi-send', 'inputs': shown(inputs), 'outputs': shown(outputs)},
  );
}

_Description? _instantiate(Map<String, dynamic> value, {required bool v2}) {
  final sender = value['sender'];
  final admin = value['admin'] ?? '';
  final codeId = _id(value['code_id']);
  final label = _nonEmpty(value['label']);
  final funds = _coinList(value['funds']);
  if (admin is! String || codeId == null || label == null || funds == null) return null;
  if (!value.containsKey('msg') || !_contractMessage(value['msg'])) return null;
  String? saltHex;
  var fixMsg = false;
  if (v2) {
    final salt = value['salt'];
    if (salt is! String) return null;
    final List<int> bytes;
    try {
      bytes = base64.decode(salt);
    } on FormatException {
      return null;
    }
    // Canonical base64 only: what is shown must be what the bytes are.
    if (bytes.isEmpty || bytes.length > 64 || base64.encode(bytes) != salt) return null;
    saltHex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
    final fix = value['fix_msg'] ?? false;
    if (fix is! bool) return null;
    fixMsg = fix;
  }
  if (!_addressesOfThisChain([sender], [if (admin.isNotEmpty) admin])) return null;
  var text = 'Instantiate code $codeId as a new contract${v2 ? ' at a salt-derived address' : ''}';
  text += admin.isEmpty ? ' with no admin' : ' with admin $admin';
  if (funds.isNotEmpty) text += ', sending ${_coinsWords(funds)}';
  return _said(
    text,
    recipient: admin.isEmpty ? null : admin,
    detail: {
      'kind': 'instantiate-contract',
      'codeId': codeId,
      'label': label,
      'admin': admin.isEmpty ? null : admin,
      'msg': value['msg'],
      'funds': [for (final c in funds) c.toJson()],
      if (v2) 'salt': saltHex,
      if (v2) 'fixMsg': fixMsg,
    },
  );
}

_Description? _migrate(Map<String, dynamic> value) {
  final codeId = _id(value['code_id']);
  final contract = value['contract'];
  if (codeId == null || !value.containsKey('msg') || !_contractMessage(value['msg'])) return null;
  if (!_addressesOfThisChain([value['sender']], [contract])) return null;
  return _said(
    'Migrate contract $contract to code $codeId',
    detail: {'kind': 'migrate-contract', 'contract': contract, 'codeId': codeId, 'msg': value['msg']},
  );
}

/// A lock's duration in whole seconds, from the nanoseconds Amino writes.
String? _durationSeconds(Object? value) {
  final text = value is int ? '$value' : value;
  if (text is! String || !RegExp(r'^[1-9]\d{0,18}$').hasMatch(text)) return null;
  final nanos = BigInt.parse(text);
  if (nanos > _int64Max || nanos % _billion != BigInt.zero) return null;
  return (nanos ~/ _billion).toString();
}

_Description? Function(Map<String, dynamic>) _weightedVote() => (value) {
  final proposal = _id(value['proposal_id']);
  final options = value['options'];
  if (proposal == null || options is! List || options.isEmpty) return null;
  if (value.containsKey('metadata') && value['metadata'] is! String) return null;
  var total = BigInt.zero;
  final labels = <String>[];
  final words = <String>[];
  for (final item in options) {
    final entry = _fields(item);
    final label = entry == null ? null : _voteLabel(entry['option']);
    final scaled = entry == null ? null : _scaledDecimal(entry['weight']);
    if (label == null || scaled == null || scaled == '0' || labels.contains(label)) return null;
    labels.add(label);
    total += BigInt.parse(scaled);
    words.add('$label ${_decimalShown(scaled)}');
  }
  if (total != _decOne || !_addressesOfThisChain([value['voter']])) return null;
  return _said('Vote ${words.join(', ')} on proposal $proposal');
};

_Description? _withAccounts(
  Map<String, dynamic> value,
  List<String> accountKeys,
  List<String> derivedKeys,
  _Description? Function() describe,
) =>
    _addressesOfThisChain(
      [for (final key in accountKeys) value[key]],
      [for (final key in derivedKeys) value[key]],
    )
    ? describe()
    : null;

/// The describers of the messages a dApp builds, by Amino name.
final Map<String, _Description? Function(Map<String, dynamic>)> _dappDescribers = {
  // -- concentrated liquidity ---------------------------------------------------------------
  'osmosis/cl-create-position': (v) {
    final pool = _id(v['pool_id']);
    final lower = _int64(v['lower_tick']);
    final upper = _int64(v['upper_tick']);
    final coins = _coinList(v['tokens_provided'], min: 1, max: 2);
    final min0 = _amount(v['token_min_amount0']);
    final min1 = _amount(v['token_min_amount1']);
    if (pool == null || lower == null || upper == null || coins == null || min0 == null || min1 == null) {
      return null;
    }
    if (BigInt.parse(lower) >= BigInt.parse(upper)) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Create a concentrated liquidity position in pool $pool between ticks $lower and $upper '
        'with ${_coinsWords(coins)}, accepting at least $min0 of the pool\'s token0 and $min1 of its token1',
      ),
    );
  },
  'osmosis/cl-add-to-position': (v) {
    final position = _id(v['position_id']);
    final amount0 = _amount(v['amount0']);
    final amount1 = _amount(v['amount1']);
    final min0 = _amount(v['token_min_amount0']);
    final min1 = _amount(v['token_min_amount1']);
    if (position == null || amount0 == null || amount1 == null || min0 == null || min1 == null) return null;
    if (amount0 == '0' && amount1 == '0') return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Add $amount0 of the pool\'s token0 and $amount1 of its token1 to concentrated liquidity '
        'position $position, using at least $min0 and $min1 of them; the message names no denoms',
      ),
    );
  },
  'osmosis/cl-withdraw-position': (v) {
    final position = _id(v['position_id']);
    final scaled = _scaledDecimal(v['liquidity_amount']);
    if (position == null || scaled == null || scaled == '0') return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Withdraw ${_decimalShown(scaled)} liquidity units (the message names no denom) from '
        'concentrated liquidity position $position',
      ),
    );
  },
  'osmosis/cl-col-sp-rewards': (v) {
    final ids = _ids(v['position_ids']);
    return ids == null
        ? null
        : _withAccounts(
            v,
            ['sender'],
            [],
            () => _said('Collect the spread rewards of concentrated liquidity ${_positionsWords(ids)}'),
          );
  },
  'osmosis/cl-collect-incentives': (v) {
    final ids = _ids(v['position_ids']);
    return ids == null
        ? null
        : _withAccounts(
            v,
            ['sender'],
            [],
            () => _said('Collect the incentives of concentrated liquidity ${_positionsWords(ids)}'),
          );
  },
  'osmosis/cl-transfer-positions': (v) {
    final ids = _ids(v['position_ids']);
    if (ids == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      ['new_owner'],
      () => _said(
        'Transfer concentrated liquidity ${_positionsWords(ids)} to ${v['new_owner']}',
        recipient: v['new_owner'] as String,
      ),
    );
  },
  // -- classic pools ------------------------------------------------------------------------
  'osmosis/gamm/join-pool': (v) {
    final pool = _id(v['pool_id']);
    final shares = _positive(v['share_out_amount']);
    final maxs = _coinList(v['token_in_maxs'], min: 1);
    if (pool == null || shares == null || maxs == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Join pool $pool for exactly $shares gamm/pool/$pool shares, paying at most ${_coinsWords(maxs)}',
      ),
    );
  },
  'osmosis/gamm/exit-pool': (v) {
    final pool = _id(v['pool_id']);
    final shares = _positive(v['share_in_amount']);
    final mins = _coinList(v['token_out_mins']);
    if (pool == null || shares == null || mins == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Exit pool $pool by burning $shares gamm/pool/$pool shares, '
        '${mins.isEmpty ? 'with no minimum amount out' : 'receiving at least ${_coinsWords(mins)}'}',
      ),
    );
  },
  'osmosis/gamm/join-swap-extern-amount-in': (v) {
    final pool = _id(v['pool_id']);
    final token = _coin(v['token_in'], aboveZero: true);
    final minimum = _positive(v['share_out_min_amount']);
    if (pool == null || token == null || minimum == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Join pool $pool with ${_coinWords(token)} alone, receiving at least $minimum gamm/pool/$pool shares',
      ),
    );
  },
  'osmosis/gamm/exit-swap-share-amount-in': (v) {
    final pool = _id(v['pool_id']);
    final denom = _denom(v['token_out_denom']);
    final shares = _positive(v['share_in_amount']);
    final minimum = _positive(v['token_out_min_amount']);
    if (pool == null || denom == null || shares == null || minimum == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Exit pool $pool by burning $shares gamm/pool/$pool shares for $denom alone, '
        'receiving at least $minimum $denom',
      ),
    );
  },
  'osmosis/gamm/join-swap-share-amount-out': (v) {
    final pool = _id(v['pool_id']);
    final denom = _denom(v['token_in_denom']);
    final shares = _positive(v['share_out_amount']);
    final maximum = _positive(v['token_in_max_amount']);
    if (pool == null || denom == null || shares == null || maximum == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Join pool $pool with $denom alone, paying at most $maximum $denom for exactly $shares '
        'gamm/pool/$pool shares',
      ),
    );
  },
  'osmosis/gamm/exit-swap-extern-amount-out': (v) {
    final pool = _id(v['pool_id']);
    final token = _coin(v['token_out'], aboveZero: true);
    final maximum = _positive(v['share_in_max_amount']);
    if (pool == null || token == null || maximum == null) return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Exit pool $pool receiving exactly ${_coinWords(token)} alone, burning at most $maximum '
        'gamm/pool/$pool shares',
      ),
    );
  },
  'osmosis/gamm/swap-exact-amount-in': _swapExactIn,
  'osmosis/gamm/swap-exact-amount-out': _swapExactOut,
  // -- lockups and superfluid staking -------------------------------------------------------
  'osmosis/lockup/lock-tokens': (v) {
    final seconds = _durationSeconds(v['duration']);
    final coins = _coinList(v['coins'], min: 1);
    if (seconds == null || coins == null) return null;
    return _withAccounts(v, ['owner'], [], () => _said('Lock ${_coinsWords(coins)} for $seconds seconds'));
  },
  'osmosis/lockup/begin-unlock-period-lock': (v) {
    final lock = _id(v.containsKey('ID') ? v['ID'] : v['id']);
    final coins = _coinList(v['coins']);
    if (lock == null || coins == null) return null;
    return _withAccounts(
      v,
      ['owner'],
      [],
      () => _said(
        coins.isEmpty
            ? 'Begin unlocking all the tokens of lock $lock'
            : 'Begin unlocking ${_coinsWords(coins)} from lock $lock',
      ),
    );
  },
  'osmosis/lockup/begin-unlock-tokens': (v) =>
      _withAccounts(v, ['owner'], [], () => _said('Begin unlocking every lock owned by ${v['owner']}')),
  'osmosis/superfluid-delegate': (v) {
    final lock = _id(v['lock_id']);
    return lock == null
        ? null
        : _withAccounts(
            v,
            ['sender', 'val_addr'],
            [],
            () => _said('Superfluid-delegate lock $lock to validator ${v['val_addr']}'),
          );
  },
  'osmosis/superfluid-undelegate': (v) {
    final lock = _id(v['lock_id']);
    return lock == null
        ? null
        : _withAccounts(v, ['sender'], [], () => _said('Superfluid-undelegate lock $lock'));
  },
  'osmosis/lock-and-superfluid-delegate': (v) {
    final coins = _coinList(v['coins'], min: 1);
    return coins == null
        ? null
        : _withAccounts(
            v,
            ['sender', 'val_addr'],
            [],
            () =>
                _said('Lock ${_coinsWords(coins)} and superfluid-delegate it to validator ${v['val_addr']}'),
          );
  },
  'osmosis/superfluid-unbond-lock': (v) {
    final lock = _id(v['lock_id']);
    return lock == null
        ? null
        : _withAccounts(v, ['sender'], [], () => _said('Superfluid-unbond lock $lock'));
  },
  'osmosis/superfluid-undelegate-unbond-lock': _superfluidUndelegateAndUnbond,
  'osmosis/sf-undelegate-and-unbond-lock': _superfluidUndelegateAndUnbond,
  'osmosis/full-range-and-sf-delegate': (v) {
    final pool = _id(v['pool_id']);
    final coins = _coinList(v['coins'], min: 1, max: 2);
    if (pool == null || coins == null) return null;
    return _withAccounts(
      v,
      ['sender', 'val_addr'],
      [],
      () => _said(
        'Create a full-range concentrated liquidity position in pool $pool with ${_coinsWords(coins)} '
        'and superfluid-delegate it to validator ${v['val_addr']}',
      ),
    );
  },
  'osmosis/add-to-cl-superfluid-position': (v) {
    final position = _id(v['position_id']);
    final first = _coin(v['token_desired0']);
    final second = _coin(v['token_desired1']);
    if (position == null || first == null || second == null) return null;
    if (first.amount == '0' && second.amount == '0') return null;
    return _withAccounts(
      v,
      ['sender'],
      [],
      () => _said(
        'Add ${_coinWords(first)} and ${_coinWords(second)} to superfluid concentrated liquidity '
        'position $position',
      ),
    );
  },
  // -- the Cosmos SDK -----------------------------------------------------------------------
  'cosmos-sdk/MsgMultiSend': _multiSend,
  'cosmos-sdk/MsgCancelUnbondingDelegation': (v) {
    final amount = _coin(v['amount'], aboveZero: true);
    final height = _int64(v['creation_height']);
    if (amount == null || height == null || BigInt.parse(height) <= BigInt.zero) return null;
    return _withAccounts(
      v,
      ['delegator_address', 'validator_address'],
      [],
      () => _said(
        'Cancel the unbonding of ${_coinWords(amount)} from ${v['validator_address']}, '
        'created at height $height',
      ),
    );
  },
  'cosmos-sdk/MsgModifyWithdrawAddress': (v) => _withAccounts(
    v,
    ['delegator_address'],
    ['withdraw_address'],
    () => _said(
      'Set the address that receives your staking rewards to ${v['withdraw_address']}',
      recipient: v['withdraw_address'] as String,
    ),
  ),
  'cosmos-sdk/MsgWithdrawValCommission': (v) => _withAccounts(
    v,
    ['validator_address'],
    [],
    () => _said('Withdraw the commission of validator ${v['validator_address']}'),
  ),
  'cosmos-sdk/MsgFundCommunityPool': (v) {
    final coins = _coinList(v['amount'], min: 1);
    return coins == null
        ? null
        : _withAccounts(
            v,
            ['depositor'],
            [],
            () => _said('Fund the community pool with ${_coinsWords(coins)}'),
          );
  },
  'cosmos-sdk/MsgDeposit': _deposit,
  'cosmos-sdk/v1/MsgDeposit': _deposit,
  'cosmos-sdk/MsgVoteWeighted': _weightedVote(),
  'cosmos-sdk/v1/MsgVoteWeighted': _weightedVote(),
  'cosmos-sdk/MsgRevoke': (v) {
    if (!_plainTypeUrl(v['msg_type_url'])) return null;
    return _withAccounts(
      v,
      ['granter'],
      ['grantee'],
      () => _said('Revoke the authorization given to ${v['grantee']} for ${v['msg_type_url']}'),
    );
  },
  'cosmos-sdk/MsgRevokeAllowance': (v) => _withAccounts(
    v,
    ['granter'],
    ['grantee'],
    () => _said('Revoke the fee allowance given to ${v['grantee']}'),
  ),
  // -- CosmWasm -----------------------------------------------------------------------------
  'wasm/MsgInstantiateContract': (v) => _instantiate(v, v2: false),
  'wasm/MsgInstantiateContract2': (v) => _instantiate(v, v2: true),
  'wasm/MsgMigrateContract': _migrate,
  'wasm/MsgUpdateAdmin': (v) => _withAccounts(
    v,
    ['sender'],
    ['new_admin', 'contract'],
    () => _said(
      'Make ${v['new_admin']} the admin of contract ${v['contract']}',
      recipient: v['new_admin'] as String,
    ),
  ),
  'wasm/MsgClearAdmin': (v) => _withAccounts(
    v,
    ['sender'],
    ['contract'],
    () => _said('Clear the admin of contract ${v['contract']}, so nobody can migrate it again'),
  ),
};

_Description? _deposit(Map<String, dynamic> value) {
  final proposal = _id(value['proposal_id']);
  final coins = _coinList(value['amount'], min: 1);
  if (proposal == null || coins == null) return null;
  return _withAccounts(
    value,
    ['depositor'],
    [],
    () => _said('Deposit ${_coinsWords(coins)} on proposal $proposal'),
  );
}

_Description? _superfluidUndelegateAndUnbond(Map<String, dynamic> value) {
  final lock = _id(value['lock_id']);
  final coin = _coin(value['coin'], aboveZero: true);
  if (lock == null || coin == null) return null;
  return _withAccounts(
    value,
    ['sender'],
    [],
    () => _said('Superfluid-undelegate lock $lock and unbond ${_coinWords(coin)} from it'),
  );
}

/// Amino types that are never described, in step with the kernel: they hand
/// control of the account to someone else, or run messages nobody has read.
bool _neverDescribed(String type) =>
    const {
      'cosmos-sdk/MsgGrant',
      'cosmos-sdk/MsgExec',
      'cosmos-sdk/MsgGrantAllowance',
      'wasm/MsgStoreCode',
      'cosmos-sdk/MsgSubmitProposal',
      'cosmos-sdk/v1/MsgSubmitProposal',
    }.contains(type) ||
    type.startsWith('osmosis/smartaccount/');
