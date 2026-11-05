/// Which sites may see which chains, for how long, and what each was shown
/// (zunia-extension/lib/permissions.ts and lib/provider-events.ts).
///
/// A grant is per site and per chain, and each chain lapses 7 days after the
/// user last approved it (config/security.yaml `default_ttl_days`). A site
/// never learns which other sites are connected: events are addressed to one
/// origin. The store keeps, per chain, the address the site was handed and,
/// per site, when it last used the grant, which the Connected sites screen
/// shows.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long an approval of a chain lasts.
const kGrantTtl = Duration(days: 7);

/// A use closer than this to the last recorded one is not written again.
const _touchInterval = Duration(minutes: 1);

const _kGrants = 'zunia.browser.grants.v2';

/// Where 0.1.0 builds before this kept `origin → [chainId]`, with no expiry.
const _kLegacyPermissions = 'zunia.browser.permissions';

@immutable
class ChainGrant {
  const ChainGrant({
    required this.chainId,
    required this.grantedAt,
    required this.expiresAt,
    this.address,
  });

  factory ChainGrant.fromJson(String chainId, Map<String, dynamic> json) => ChainGrant(
        chainId: chainId,
        grantedAt: DateTime.fromMillisecondsSinceEpoch((json['grantedAt'] as num?)?.toInt() ?? 0),
        expiresAt: DateTime.fromMillisecondsSinceEpoch((json['expiresAt'] as num?)?.toInt() ?? 0),
        address: json['address'] as String?,
      );

  final String chainId;
  final DateTime grantedAt;
  final DateTime expiresAt;

  /// The address the site was handed on this chain, once it read one.
  final String? address;

  bool activeAt(DateTime now) => expiresAt.isAfter(now);

  ChainGrant copyWith({DateTime? grantedAt, DateTime? expiresAt, String? address}) => ChainGrant(
        chainId: chainId,
        grantedAt: grantedAt ?? this.grantedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        address: address ?? this.address,
      );

  Map<String, dynamic> toJson() => {
        'grantedAt': grantedAt.millisecondsSinceEpoch,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'address': ?address,
      };
}

@immutable
class SiteGrant {
  const SiteGrant({
    required this.origin,
    required this.createdAt,
    required this.chains,
    this.lastUsedAt,
  });

  factory SiteGrant.fromJson(String origin, Map<String, dynamic> json) {
    final chains = <String, ChainGrant>{};
    final raw = json['chains'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.value is Map) {
          chains['${entry.key}'] = ChainGrant.fromJson(
            '${entry.key}',
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    final used = (json['lastUsedAt'] as num?)?.toInt();
    return SiteGrant(
      origin: origin,
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num?)?.toInt() ?? 0),
      lastUsedAt: used == null ? null : DateTime.fromMillisecondsSinceEpoch(used),
      chains: chains,
    );
  }

  final String origin;
  final DateTime createdAt;

  /// Last time the site used the grant: a key read, a signature, a reconnect.
  final DateTime? lastUsedAt;
  final Map<String, ChainGrant> chains;

  /// Chains the site may use at [now], sorted.
  List<String> activeChainIds(DateTime now) =>
      [for (final g in chains.values) if (g.activeAt(now)) g.chainId]..sort();

  /// When the last chain lapses: then the site is disconnected.
  DateTime? get expiresAt => chains.isEmpty
      ? null
      : chains.values.map((g) => g.expiresAt).reduce((a, b) => a.isAfter(b) ? a : b);

  SiteGrant copyWith({DateTime? lastUsedAt, Map<String, ChainGrant>? chains}) => SiteGrant(
        origin: origin,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        chains: chains ?? this.chains,
      );

  Map<String, dynamic> toJson() => {
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.millisecondsSinceEpoch,
        'chains': {for (final g in chains.values) g.chainId: g.toJson()},
      };
}

/// Events a connected site hears (zunia-extension/lib/provider-events.ts).
enum ProviderEventName { accountsChanged, chainChanged, disconnect, locked }

@immutable
class SiteEvent {
  const SiteEvent(this.origin, this.event, [this.chainIds]);

  final String origin;
  final ProviderEventName event;

  /// chainChanged: every chain the site may use now. disconnect: the chains it
  /// lost, or null for all.
  final List<String>? chainIds;

  Map<String, Object?>? get data => chainIds == null ? null : {'chainIds': chainIds};

  @override
  bool operator ==(Object other) =>
      other is SiteEvent &&
      other.origin == origin &&
      other.event == event &&
      listEquals(other.chainIds, chainIds);

  @override
  int get hashCode => Object.hash(origin, event, Object.hashAll(chainIds ?? const []));

  @override
  String toString() => 'SiteEvent($origin, ${event.name}, $chainIds)';
}

/// What each site hears after the grants went from [before] to [after]. Only
/// chain lists count: bookkeeping (last use, addresses) changes nothing a site
/// may do.
List<SiteEvent> grantChangeEvents(
  Map<String, SiteGrant> before,
  Map<String, SiteGrant> after,
  DateTime now,
) {
  final events = <SiteEvent>[];
  final origins = {...before.keys, ...after.keys}.toList()..sort();
  for (final origin in origins) {
    final was = before[origin]?.activeChainIds(now) ?? const <String>[];
    final next = after[origin]?.activeChainIds(now) ?? const <String>[];
    if (listEquals(was, next)) continue;
    if (next.isEmpty) {
      events.add(SiteEvent(origin, ProviderEventName.disconnect));
      continue;
    }
    final lost = was.where((id) => !next.contains(id)).toList();
    if (lost.isNotEmpty) events.add(SiteEvent(origin, ProviderEventName.disconnect, lost));
    events.add(SiteEvent(origin, ProviderEventName.chainChanged, next));
  }
  return events;
}

class SiteGrantStore {
  SiteGrantStore({DateTime Function()? clock, this.ttl = kGrantTtl}) : _clock = clock ?? DateTime.now;

  /// The app's one store: every browser tab and the Connected sites screen
  /// read and write through it, so a revoke reaches an open page at once.
  static final shared = SiteGrantStore();

  final DateTime Function() _clock;
  final Duration ttl;

  final _events = StreamController<SiteEvent>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Future<void> _pending = Future.value();

  /// Events for open pages, each addressed to one origin.
  Stream<SiteEvent> get events => _events.stream;

  /// Any change, bookkeeping included, for screens listing grants.
  Stream<void> get changes => _changes.stream;

  DateTime get now => _clock();

  /// Runs read-modify-write updates one after another: a site reading keys
  /// for several chains at once would otherwise lose all but one write.
  Future<T> _serialized<T>(Future<T> Function() task) {
    final run = _pending.then((_) => task());
    _pending = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Map<String, SiteGrant>> _load() async {
    final store = await SharedPreferences.getInstance();
    final out = <String, SiteGrant>{};
    final raw = store.getString(_kGrants);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          if (entry.value is Map) {
            out[entry.key] = SiteGrant.fromJson(entry.key, Map<String, dynamic>.from(entry.value as Map));
          }
        }
      } on FormatException {
        // A corrupt store connects nothing; sites ask again.
      }
    }
    final legacy = store.getString(_kLegacyPermissions);
    if (legacy != null) {
      // Grants from before expiry existed: kept, and lapse a week from now.
      try {
        final map = jsonDecode(legacy) as Map<String, dynamic>;
        final at = now;
        for (final entry in map.entries) {
          if (out.containsKey(entry.key) || entry.value is! List) continue;
          out[entry.key] = SiteGrant(
            origin: entry.key,
            createdAt: at,
            lastUsedAt: null,
            chains: {
              for (final id in (entry.value as List).whereType<String>())
                id: ChainGrant(chainId: id, grantedAt: at, expiresAt: at.add(ttl)),
            },
          );
        }
      } on FormatException {
        // Nothing to carry over.
      }
      await store.remove(_kLegacyPermissions);
      await _save(out, store: store);
    }
    return out;
  }

  Future<void> _save(Map<String, SiteGrant> grants, {SharedPreferences? store}) async {
    final prefs = store ?? await SharedPreferences.getInstance();
    await prefs.setString(
      _kGrants,
      jsonEncode({for (final e in grants.entries) e.key: e.value.toJson()}),
    );
  }

  /// Applies [change] to the stored grants and tells open pages what changed.
  Future<T> _update<T>(T Function(Map<String, SiteGrant> grants) change) {
    return _serialized(() async {
      final before = await _load();
      final after = {for (final e in before.entries) e.key: e.value};
      final result = change(after);
      await _save(after);
      for (final event in grantChangeEvents(before, after, now)) {
        _events.add(event);
      }
      _changes.add(null);
      return result;
    });
  }

  /// The chains [origin] may use right now, without touching the grant.
  Future<List<String>> connectedChains(String origin) async {
    final grant = (await _serialized(_load))[origin];
    return grant?.activeChainIds(now) ?? const [];
  }

  Future<bool> hasPermission(String origin, Iterable<String> chainIds) async {
    final active = await connectedChains(origin);
    return chainIds.every(active.contains);
  }

  /// Live grants, after deleting the lapsed ones (which tells their sites).
  Future<List<SiteGrant>> listActive() async {
    await sweep();
    final grants = await _serialized(_load);
    final at = now;
    final out = [
      for (final grant in grants.values)
        if (grant.activeChainIds(at).isNotEmpty) grant,
    ];
    out.sort((a, b) => (b.lastUsedAt ?? b.createdAt).compareTo(a.lastUsedAt ?? a.createdAt));
    return out;
  }

  /// Deletes chains past their expiry. Their sites hear `disconnect`.
  Future<void> sweep() async {
    final at = now;
    await _serialized(() async {
      final before = await _load();
      final after = <String, SiteGrant>{};
      final events = <SiteEvent>[];
      for (final grant in before.values) {
        final lapsed = [for (final c in grant.chains.values) if (!c.activeAt(at)) c.chainId]..sort();
        final kept = {
          for (final c in grant.chains.values)
            if (c.activeAt(at)) c.chainId: c,
        };
        if (kept.isNotEmpty) after[grant.origin] = grant.copyWith(chains: kept);
        if (lapsed.isEmpty) continue;
        // A lapsed chain no longer counts as active, so the events are said
        // here rather than by comparing active lists: what the site lost.
        if (kept.isEmpty) {
          events.add(SiteEvent(grant.origin, ProviderEventName.disconnect));
        } else {
          events
            ..add(SiteEvent(grant.origin, ProviderEventName.disconnect, lapsed))
            ..add(SiteEvent(grant.origin, ProviderEventName.chainChanged, kept.keys.toList()..sort()));
        }
      }
      if (events.isEmpty) return;
      await _save(after);
      events.forEach(_events.add);
      _changes.add(null);
    });
  }

  /// When the next chain lapses, or null when none will.
  Future<DateTime?> nextExpiry() async {
    final grants = await _serialized(_load);
    DateTime? next;
    for (final grant in grants.values) {
      for (final chain in grant.chains.values) {
        if (next == null || chain.expiresAt.isBefore(next)) next = chain.expiresAt;
      }
    }
    return next;
  }

  /// Approve [chainIds] for [origin]: each lasts [ttl] from now.
  Future<void> grant(String origin, Iterable<String> chainIds) => _update((grants) {
        final at = now;
        final existing = grants[origin];
        final chains = {
          for (final c in existing?.chains.values ?? const <ChainGrant>[])
            if (c.activeAt(at)) c.chainId: c,
        };
        for (final id in chainIds) {
          final kept = chains[id];
          chains[id] = ChainGrant(
            chainId: id,
            grantedAt: at,
            expiresAt: at.add(ttl),
            address: kept?.address,
          );
        }
        grants[origin] = SiteGrant(
          origin: origin,
          createdAt: existing?.createdAt ?? at,
          lastUsedAt: at,
          chains: chains,
        );
      });

  /// Note that [origin] used its grant, and which address it was handed.
  /// Writes at most once a minute unless the address is new. Bookkeeping only:
  /// it never fails a request.
  Future<void> touch(String origin, {String? chainId, String? address}) async {
    try {
      final at = now;
      final grant = (await _serialized(_load))[origin];
      if (grant == null || grant.activeChainIds(at).isEmpty) return;
      final chain = chainId == null ? null : grant.chains[chainId];
      final exposed = chain != null && address != null && chain.activeAt(at) && chain.address != address;
      final stale = grant.lastUsedAt == null || at.difference(grant.lastUsedAt!) >= _touchInterval;
      if (!exposed && !stale) return;
      await _update((grants) {
        final current = grants[origin];
        if (current == null) return;
        grants[origin] = current.copyWith(
          lastUsedAt: at,
          chains: exposed
              ? {...current.chains, chainId!: current.chains[chainId]!.copyWith(address: address)}
              : current.chains,
        );
      });
    } catch (_) {
      // Bookkeeping never fails a request.
    }
  }

  Future<void> revokeSite(String origin) => _update((grants) {
        grants.remove(origin);
      });

  Future<void> revokeChain(String origin, String chainId) => _update((grants) {
        final grant = grants[origin];
        if (grant == null) return;
        final chains = {...grant.chains}..remove(chainId);
        if (chains.isEmpty) {
          grants.remove(origin);
        } else {
          grants[origin] = grant.copyWith(chains: chains);
        }
      });

  /// Forget every site. Returns the origins that still had a live grant.
  Future<List<String>> revokeAll() => _update((grants) {
        final at = now;
        final live = [
          for (final g in grants.values)
            if (g.activeChainIds(at).isNotEmpty) g.origin,
        ];
        grants.clear();
        return live;
      });

  /// Tells [origin]'s open page something that is not a grant change
  /// (an account switch, the wallet locking).
  void notify(SiteEvent event) => _events.add(event);

  @visibleForTesting
  Future<void> dispose() async {
    await _events.close();
    await _changes.close();
  }
}

final siteGrantStoreProvider = Provider<SiteGrantStore>((ref) => SiteGrantStore.shared);

/// Live grants, newest use first, refreshed whenever the store changes.
final siteGrantsProvider = StreamProvider<List<SiteGrant>>((ref) async* {
  final store = ref.watch(siteGrantStoreProvider);
  yield await store.listActive();
  await for (final _ in store.changes) {
    yield await store.listActive();
  }
});
