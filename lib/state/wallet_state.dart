/// The account index: non-secret metadata for every account, plus the derived
/// addresses of the unlocked session.
///
/// Accounts work as in extension 0.1.5. "Add account" creates or restores a
/// recovery phrase of its own, sealed with the same password; that account
/// derives at index 0 of its phrase. Accounts an older build added as HD
/// children of the first phrase keep their index N on that phrase
/// (`m/44'/coin'/0'/0/N`, the path the kernel derives).
///
/// The phrases themselves live only in [sessionProvider] (all of them) and
/// [phraseProvider] (the active account's) while the app is unlocked.
/// Everything persisted here is safe in plain SharedPreferences.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_ui/zunia_ui.dart' show hashSeed, kAvatarPalettes;

@immutable
class WalletAccount {
  const WalletAccount({
    required this.id,
    required this.name,
    required this.index,
    this.phraseId = '',
    this.avatarSeed,
    this.createdAt = 0,
    this.enabledChainIds,
  });

  factory WalletAccount.fromJson(Map<String, dynamic> json) => WalletAccount(
        id: json['id'] as String,
        name: json['name'] as String,
        index: (json['index'] as num).toInt(),
        // Missing in the index written before vault v2; filled on the first
        // unlock, when the migrated phrase gets its id.
        phraseId: json['phraseId'] as String? ?? '',
        avatarSeed: json['avatarSeed'] as String?,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        enabledChainIds: (json['enabledChainIds'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList(),
      );

  final String id;
  final String name;

  /// Derivation index the kernel uses (`m/44'/coin'/0'/0/index`): 0 for an
  /// account with its own phrase, N for an older HD child of the first one.
  /// Signing flows read it as `walletProvider.active.index`.
  final int index;

  /// The sealed phrase this account derives from.
  final String phraseId;

  /// Seed of the account's orb (`ZuniaWalletAvatar`). Chosen so accounts get
  /// different colours; falls back to [id].
  final String? avatarSeed;

  /// Epoch ms; 0 for accounts that predate the field.
  final int createdAt;

  /// Networks this account shows, independent of the others (as in the
  /// extension). Null: the wallet-wide list from before accounts had one.
  final List<String>? enabledChainIds;

  /// An older account derived from the first phrase at [index] > 0. It has
  /// no phrase of its own: backing up the first phrase backs it up.
  bool get isHdChild => index > 0;

  String get avatar => avatarSeed ?? id;

  String get initial => name.trim().isEmpty ? 'W' : name.trim()[0].toUpperCase();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'index': index,
        'phraseId': phraseId,
        if (avatarSeed != null) 'avatarSeed': avatarSeed,
        'createdAt': createdAt,
        if (enabledChainIds != null) 'enabledChainIds': enabledChainIds,
      };

  WalletAccount copyWith({
    String? name,
    String? phraseId,
    String? avatarSeed,
    List<String>? enabledChainIds,
  }) =>
      WalletAccount(
        id: id,
        name: name ?? this.name,
        index: index,
        phraseId: phraseId ?? this.phraseId,
        avatarSeed: avatarSeed ?? this.avatarSeed,
        createdAt: createdAt,
        enabledChainIds: enabledChainIds ?? this.enabledChainIds,
      );
}

/// What is known about a sealed phrase without opening it.
@immutable
class PhraseInfo {
  const PhraseInfo({
    required this.id,
    required this.wordCount,
    this.createdAt = 0,
    this.backupVerified = false,
  });

  factory PhraseInfo.fromJson(String id, Map<String, dynamic> json) =>
      PhraseInfo(
        id: id,
        wordCount: (json['words'] as num?)?.toInt() ?? 12,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        backupVerified: json['verified'] as bool? ?? false,
      );

  final String id;
  final int wordCount;
  final int createdAt;

  /// The user proved they wrote it down (picked the right words). Never set
  /// just because a phrase was typed in to restore it.
  final bool backupVerified;

  Map<String, dynamic> toJson() =>
      {'words': wordCount, 'createdAt': createdAt, 'verified': backupVerified};

  PhraseInfo copyWith({bool? backupVerified}) => PhraseInfo(
        id: id,
        wordCount: wordCount,
        createdAt: createdAt,
        backupVerified: backupVerified ?? this.backupVerified,
      );
}

const kDefaultChainIds = ['safrochain-1'];

@immutable
class WalletData {
  const WalletData({
    this.accounts = const [],
    this.activeId,
    this.globalChainIds = kDefaultChainIds,
    this.phrases = const {},
    this.loaded = false,
  });

  final List<WalletAccount> accounts;
  final String? activeId;

  /// The wallet-wide network list older builds kept; the fallback for an
  /// account without its own.
  final List<String> globalChainIds;

  final Map<String, PhraseInfo> phrases;
  final bool loaded;

  WalletAccount? get active {
    if (accounts.isEmpty) return null;
    for (final a in accounts) {
      if (a.id == activeId) return a;
    }
    return accounts.first;
  }

  /// Networks the active account shows.
  List<String> get enabledChainIds {
    final own = active?.enabledChainIds;
    if (own != null && own.isNotEmpty) return own;
    return globalChainIds.isEmpty ? kDefaultChainIds : globalChainIds;
  }

  PhraseInfo? phraseOf(WalletAccount account) => phrases[account.phraseId];

  /// Accounts that use [phraseId] (its own account plus any HD children).
  List<WalletAccount> accountsOf(String phraseId) =>
      [for (final a in accounts) if (a.phraseId == phraseId) a];

  WalletAccount? byId(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  WalletData copyWith({
    List<WalletAccount>? accounts,
    String? activeId,
    List<String>? globalChainIds,
    Map<String, PhraseInfo>? phrases,
    bool? loaded,
  }) {
    return WalletData(
      accounts: accounts ?? this.accounts,
      activeId: activeId ?? this.activeId,
      globalChainIds: globalChainIds ?? this.globalChainIds,
      phrases: phrases ?? this.phrases,
      loaded: loaded ?? this.loaded,
    );
  }
}

const _kAccounts = 'zunia.wallet.accounts';
const _kActive = 'zunia.wallet.activeAccount';
const _kChains = 'zunia.wallet.enabledChains';
const _kPhrases = 'zunia.wallet.phrases';

/// Account names as the extension cleans them: single spaces, 32 characters.
String cleanAccountName(String? name, String fallback) {
  final trimmed = (name ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return fallback;
  return trimmed.length > 32 ? trimmed.substring(0, 32) : trimmed;
}

final Random _random = Random.secure();

/// An orb seed whose palette no other account uses, while one is left
/// (extension `pickAvatarSeed`, against the Flutter avatar's palettes).
String pickAvatarSeed(Iterable<String> taken) {
  int palette(String seed) => hashSeed(seed) % kAvatarPalettes.length;
  final used = taken.map(palette).toSet();
  String candidate(int i) =>
      'orb-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$i-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';
  for (var i = 0; i < 48; i++) {
    final seed = candidate(i);
    if (used.length >= kAvatarPalettes.length || !used.contains(palette(seed))) {
      return seed;
    }
  }
  return candidate(48);
}

String _newAccountId() =>
    'acct-${List.generate(6, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

class WalletController extends StateNotifier<WalletData> {
  WalletController(this._ref) : super(const WalletData()) {
    ready = _restore();
  }

  final Ref _ref;

  /// Completes after the first disk restore finishes (or is superseded by a write).
  late final Future<void> ready;

  /// Bumped on every write so a late restore cannot clobber newer state.
  int _generation = 0;

  Future<void> _restore() async {
    final started = _generation;
    final store = await SharedPreferences.getInstance();
    if (started != _generation) return;
    final rawAccounts = store.getString(_kAccounts);
    final accounts = rawAccounts == null
        ? <WalletAccount>[]
        : (jsonDecode(rawAccounts) as List<dynamic>)
            .map((e) => WalletAccount.fromJson(e as Map<String, dynamic>))
            .toList();
    final rawPhrases = store.getString(_kPhrases);
    final phrases = <String, PhraseInfo>{};
    if (rawPhrases != null) {
      final map = jsonDecode(rawPhrases) as Map<String, dynamic>;
      for (final e in map.entries) {
        phrases[e.key] =
            PhraseInfo.fromJson(e.key, e.value as Map<String, dynamic>);
      }
    }
    if (started != _generation || !mounted) return;
    state = WalletData(
      accounts: accounts,
      activeId: store.getString(_kActive),
      globalChainIds: store.getStringList(_kChains) ?? kDefaultChainIds,
      phrases: phrases,
      loaded: true,
    );
  }

  /// Applies [next] now and writes it. The phrase is swapped before the
  /// account, both synchronously: a listener on the active account (Connect
  /// re-announcing accounts, for one) already reads the new phrase.
  Future<void> _persist(WalletData next) async {
    _generation++;
    _syncPhrase(next);
    state = next.copyWith(loaded: true);
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kAccounts,
      jsonEncode(next.accounts.map((a) => a.toJson()).toList()),
    );
    if (next.activeId != null) {
      await store.setString(_kActive, next.activeId!);
    } else {
      await store.remove(_kActive);
    }
    await store.setStringList(_kChains, next.globalChainIds);
    await store.setString(
      _kPhrases,
      jsonEncode({for (final p in next.phrases.values) p.id: p.toJson()}),
    );
  }

  /// Points [phraseProvider] at the active account of [next], when unlocked.
  void _syncPhrase(WalletData next) {
    final session = _ref.read(sessionProvider);
    if (session == null) return;
    final account = next.active;
    final phrase = account == null ? null : session.phraseFor(account.phraseId);
    final notifier = _ref.read(phraseProvider.notifier);
    if (notifier.state != phrase) notifier.state = phrase;
  }

  /// The first account of a new or restored wallet.
  Future<void> initialise({
    required String walletName,
    required List<String> enabledChainIds,
    required String phraseId,
    required int wordCount,
    bool backupVerified = false,
  }) async {
    await ready;
    final now = DateTime.now().millisecondsSinceEpoch;
    final chains =
        enabledChainIds.isEmpty ? kDefaultChainIds : [...enabledChainIds];
    final account = WalletAccount(
      id: _newAccountId(),
      name: cleanAccountName(walletName, 'Account 1'),
      index: 0,
      phraseId: phraseId,
      avatarSeed: pickAvatarSeed(const []),
      createdAt: now,
      enabledChainIds: chains,
    );
    await _persist(
      WalletData(
        accounts: [account],
        activeId: account.id,
        globalChainIds: chains,
        phrases: {
          phraseId: PhraseInfo(
            id: phraseId,
            wordCount: wordCount,
            createdAt: now,
            backupVerified: backupVerified,
          ),
        },
        loaded: true,
      ),
    );
  }

  /// An account with its own phrase, already sealed as [phraseId]. Becomes
  /// the active account; the session must hold the phrase first.
  Future<WalletAccount> addPhraseAccount({
    required String name,
    required String phraseId,
    required int wordCount,
    List<String>? enabledChainIds,
    bool backupVerified = false,
  }) async {
    await ready;
    final now = DateTime.now().millisecondsSinceEpoch;
    final account = WalletAccount(
      id: _newAccountId(),
      name: cleanAccountName(name, 'Account ${state.accounts.length + 1}'),
      index: 0,
      phraseId: phraseId,
      avatarSeed: pickAvatarSeed(state.accounts.map((a) => a.avatar)),
      createdAt: now,
      enabledChainIds: enabledChainIds == null || enabledChainIds.isEmpty
          ? null
          : [...{...enabledChainIds}],
    );
    await _persist(
      state.copyWith(
        accounts: [...state.accounts, account],
        activeId: account.id,
        phrases: {
          ...state.phrases,
          phraseId: PhraseInfo(
            id: phraseId,
            wordCount: wordCount,
            createdAt: now,
            backupVerified: backupVerified,
          ),
        },
      ),
    );
    return account;
  }

  Future<void> renameAccount(String id, String name) async {
    await ready;
    await _persist(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            if (a.id == id)
              a.copyWith(name: cleanAccountName(name, a.name))
            else
              a,
        ],
      ),
    );
  }

  /// Removes one account and returns the phrase id nothing uses any more
  /// (to delete from the vault), or null. Refuses the last account.
  Future<String?> removeAccount(String id) async {
    await ready;
    final target = state.byId(id);
    if (target == null) return null;
    if (state.accounts.length <= 1) {
      throw StateError('Keep at least one account');
    }
    final rest = [for (final a in state.accounts) if (a.id != id) a];
    final orphan = rest.any((a) => a.phraseId == target.phraseId)
        ? null
        : target.phraseId;
    final phrases = {...state.phrases};
    if (orphan != null) phrases.remove(orphan);
    final activeId =
        state.activeId == id || state.byId(state.activeId ?? '') == null
            ? rest.first.id
            : state.activeId;
    await _persist(
      state.copyWith(accounts: rest, activeId: activeId, phrases: phrases),
    );
    return orphan;
  }

  /// Makes [id] the active account. The phrase swaps in the same frame.
  Future<void> selectAccount(String id) async {
    await ready;
    if (state.byId(id) == null || state.activeId == id) return;
    await _persist(state.copyWith(activeId: id));
  }

  Future<void> setBackupVerified(String phraseId, bool verified) async {
    await ready;
    final info = state.phrases[phraseId];
    if (info == null || info.backupVerified == verified) return;
    await _persist(
      state.copyWith(
        phrases: {...state.phrases, phraseId: info.copyWith(backupVerified: verified)},
      ),
    );
  }

  /// Networks for the active account.
  Future<void> setEnabledChains(List<String> chainIds) async {
    await ready;
    final next = chainIds.isEmpty ? kDefaultChainIds : [...{...chainIds}];
    final active = state.active;
    if (active == null) {
      await _persist(state.copyWith(globalChainIds: next));
      return;
    }
    await _persist(
      state.copyWith(
        accounts: [
          for (final a in state.accounts)
            if (a.id == active.id) a.copyWith(enabledChainIds: next) else a,
        ],
      ),
    );
  }

  Future<void> toggleChain(String chainId) async {
    final next = [...state.enabledChainIds];
    if (!next.remove(chainId)) next.add(chainId);
    await setEnabledChains(next);
  }

  /// Brings the index in line with what the vault holds, after an unlock:
  /// gives the accounts of a migrated vault their phrase id, recreates an
  /// account for a sealed phrase nothing points at, drops accounts whose
  /// phrase is gone, and hands out distinct orb seeds.
  Future<void> reconcile(VaultUnlock unlock) async {
    await ready;
    final vaultIds = [...unlock.phrases.keys, ...unlock.unreadable];
    if (vaultIds.isEmpty) return;
    final primary = vaultIds.first;
    final migration = unlock.migration;
    final now = DateTime.now().millisecondsSinceEpoch;

    final accounts = <WalletAccount>[];
    for (final a in state.accounts) {
      final phraseId = a.phraseId.isEmpty
          ? (migration?.phraseId ?? primary)
          : a.phraseId;
      if (!vaultIds.contains(phraseId)) continue;
      accounts.add(phraseId == a.phraseId ? a : a.copyWith(phraseId: phraseId));
    }
    for (final id in vaultIds) {
      if (accounts.any((a) => a.phraseId == id)) continue;
      accounts.add(
        WalletAccount(
          id: _newAccountId(),
          name: 'Account ${accounts.length + 1}',
          index: 0,
          phraseId: id,
          createdAt: now,
        ),
      );
    }

    final taken = <String>[];
    final seeded = <WalletAccount>[];
    for (final a in accounts) {
      if (a.avatarSeed != null) {
        taken.add(a.avatarSeed!);
        seeded.add(a);
      } else {
        final seed = pickAvatarSeed(taken);
        taken.add(seed);
        seeded.add(a.copyWith(avatarSeed: seed));
      }
    }

    final phrases = <String, PhraseInfo>{};
    for (final id in vaultIds) {
      final known = state.phrases[id];
      final phrase = unlock.phrases[id];
      phrases[id] = known ??
          PhraseInfo(
            id: id,
            wordCount: phrase == null ? 12 : phrase.split(' ').length,
            createdAt: now,
            backupVerified:
                migration?.phraseId == id && migration!.backupVerified,
          );
    }

    final activeId = seeded.any((a) => a.id == state.activeId)
        ? state.activeId
        : seeded.first.id;
    await _persist(
      state.copyWith(accounts: seeded, activeId: activeId, phrases: phrases),
    );
  }

  Future<void> clear() async {
    _generation++;
    final store = await SharedPreferences.getInstance();
    await store.remove(_kAccounts);
    await store.remove(_kActive);
    await store.remove(_kChains);
    await store.remove(_kPhrases);
    state = const WalletData(loaded: true);
  }
}

final walletProvider = StateNotifierProvider<WalletController, WalletData>(
  (ref) => WalletController(ref),
);

/// Every phrase of the unlocked session, by phrase id. Null while locked.
final sessionProvider = StateProvider<UnlockedVault?>((ref) => null);

/// Recovery phrase of the active account. Null while locked; never persisted.
/// Every signing flow reads it, together with `walletProvider.active.index`.
final phraseProvider = StateProvider<String?>((ref) => null);

@immutable
class ChainAccount {
  const ChainAccount({required this.chain, required this.address});

  final ChainEntry chain;
  final String address;
}

/// Address per enabled chain for the active account.
final chainAccountsProvider = Provider<List<ChainAccount>>((ref) {
  final phrase = ref.watch(phraseProvider);
  final wallet = ref.watch(walletProvider);
  final account = wallet.active;
  if (phrase == null || account == null || !ChainCatalog.isLoaded) {
    return const [];
  }

  final catalog = ChainCatalog.instance;
  final kernel = WalletKernel.instance;
  final out = <ChainAccount>[];
  for (final chainId in wallet.enabledChainIds) {
    final chain = catalog.find(chainId);
    if (chain == null) continue;
    try {
      final derived = kernel.deriveAddress(
        phrase: phrase,
        chain: chain,
        accountIndex: account.index,
      );
      out.add(ChainAccount(chain: chain, address: derived.address));
    } catch (_) {
      // A single unusable chain entry should not blank the whole list.
    }
  }
  return out;
});

/// Primary address shown in headers: the first enabled chain, pinned order.
final primaryAddressProvider = Provider<String?>((ref) {
  final accounts = ref.watch(chainAccountsProvider);
  return accounts.isEmpty ? null : accounts.first.address;
});
