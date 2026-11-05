/// Requests waiting for the user (zunia-extension/lib/approvals.ts): each one
/// expires 5 minutes after it arrived, at most 3 wait at once and the rest are
/// refused, and calls to `enable` from the same site share one prompt.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/sign_in.dart';

/// config/security.yaml `approvals.ttl_minutes`.
const kApprovalTtl = Duration(minutes: 5);

/// config/security.yaml `rate_limits.max_pending_approvals`.
const kMaxPendingApprovals = 3;

enum ApprovalKind {
  enable('Connection request'),
  signAmino('Signature request'),
  signDirect('Signature request'),
  signArbitrary('Message signature'),
  suggestChain('Add network request');

  const ApprovalKind(this.label);

  /// The prompt's header.
  final String label;

  bool get signs => this == signAmino || this == signDirect || this == signArbitrary;
}

/// What approving does, spelled out on the prompt: users read "Approve" as
/// "the transfer happens", and for every kind here it does not.
String approvalEffect(ApprovalKind kind, {bool signIn = false}) {
  if (signIn) {
    return 'Signing proves to this site that you control this address. It is not a '
        'transaction: nothing is sent and no funds move.';
  }
  return switch (kind) {
    ApprovalKind.enable =>
      'Approving lets this site read your addresses on these networks. It cannot move '
          'funds, and nothing is signed.',
    ApprovalKind.signAmino || ApprovalKind.signDirect =>
      'Approving signs this transaction and returns the signature to the site. Zunia '
          'does not broadcast it; the site submits it to the network.',
    ApprovalKind.signArbitrary =>
      'Approving signs this off-chain message (ADR-036) and returns the signature to the '
          'site. It cannot move funds by itself.',
    ApprovalKind.suggestChain =>
      'Approving adds this network to your wallet. Nothing is signed and no funds move.',
  };
}

/// The user's answer.
@immutable
class ApprovalAnswer {
  const ApprovalAnswer({required this.approved, this.feeTier});

  const ApprovalAnswer.approve({this.feeTier}) : approved = true;

  final bool approved;

  /// A fee tier picked in place of the site's fee; null keeps the site's.
  final FeeTier? feeTier;
}

class ApprovalRequest {
  ApprovalRequest({
    required this.id,
    required this.kind,
    required this.origin,
    required List<String> chainIds,
    required this.createdAt,
    required this.expiresAt,
    required this.title,
    this.warnings = const [],
    this.signer,
    this.review,
    this.feeChoice,
    this.json,
    this.messagePreview,
    this.encoding,
    this.signIn,
    this.signInText,
    this.draft,
  }) : chainIds = List.of(chainIds);

  final String id;
  final ApprovalKind kind;
  final String origin;

  /// Chains the request is about; a joined `enable` adds to it.
  List<String> chainIds;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String title;
  final List<String> warnings;

  /// The address the site asked to sign with.
  final String? signer;

  /// Transactions: what the prompt says about them.
  final SignReview? review;
  final FeeChoice? feeChoice;

  /// The "Raw transaction", whole.
  final String? json;

  /// Messages: the text, or hex for bytes that are not readable text.
  final String? messagePreview;

  /// `utf8` or `bytes`.
  final String? encoding;

  /// A sign-in the bridge already matched to this site, chain and account.
  final SignInMessage? signIn;
  final String? signInText;

  /// A network a site proposes.
  final ChainEntry? draft;
}

typedef EnqueuedApproval = ({String id, Future<ApprovalAnswer> result});

class ApprovalQueue {
  ApprovalQueue({
    this.ttl = kApprovalTtl,
    this.maxPending = kMaxPendingApprovals,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxPending;
  final DateTime Function() _clock;

  final List<ApprovalRequest> _queue = [];
  final Map<String, Completer<ApprovalAnswer>> _completers = {};
  final Map<String, Timer> _timers = {};
  final _changes = StreamController<List<ApprovalRequest>>.broadcast();
  final _random = Random.secure();

  /// The queue after every change.
  Stream<List<ApprovalRequest>> get changes => _changes.stream;

  List<ApprovalRequest> get pending => List.unmodifiable(_queue);

  ApprovalRequest? get current => _queue.isEmpty ? null : _queue.first;

  bool isPending(String id) => _completers.containsKey(id);

  String _newId() =>
      List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  void _notify() {
    if (!_changes.isClosed) _changes.add(pending);
  }

  /// Queues a request. Throws when [maxPending] already wait: a page that
  /// fires requests in a loop gets errors, not a stack of prompts.
  EnqueuedApproval enqueue({
    required ApprovalKind kind,
    required String origin,
    required List<String> chainIds,
    required String title,
    List<String> warnings = const [],
    String? signer,
    SignReview? review,
    FeeChoice? feeChoice,
    String? json,
    String? messagePreview,
    String? encoding,
    SignInMessage? signIn,
    String? signInText,
    ChainEntry? draft,
  }) {
    if (_queue.length >= maxPending) {
      throw ProviderError(
        ProviderErrorCode.internal,
        'Too many pending approvals (max $maxPending)',
      );
    }
    final created = _clock();
    final request = ApprovalRequest(
      id: _newId(),
      kind: kind,
      origin: origin,
      chainIds: chainIds,
      createdAt: created,
      expiresAt: created.add(ttl),
      title: title,
      warnings: warnings,
      signer: signer,
      review: review,
      feeChoice: feeChoice,
      json: json,
      messagePreview: messagePreview,
      encoding: encoding,
      signIn: signIn,
      signInText: signInText,
      draft: draft,
    );
    final completer = Completer<ApprovalAnswer>();
    _queue.add(request);
    _completers[request.id] = completer;
    _timers[request.id] = Timer(ttl, () {
      _settle(
        request.id,
        error: const ProviderError(
          ProviderErrorCode.userRejected,
          'Request expired before it was answered',
        ),
      );
    });
    _notify();
    return (id: request.id, result: completer.future);
  }

  bool _settle(String id, {ApprovalAnswer? answer, ProviderError? error}) {
    final index = _queue.indexWhere((r) => r.id == id);
    if (index < 0) return false;
    _queue.removeAt(index);
    _timers.remove(id)?.cancel();
    final completer = _completers.remove(id);
    if (completer != null && !completer.isCompleted) {
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(answer);
      }
    }
    _notify();
    return true;
  }

  /// A pending connection request from the same site: dApps often call
  /// `enable` for several chains at once, and those calls share one prompt.
  EnqueuedApproval? findPendingEnable(String origin) {
    for (final request in _queue) {
      if (request.kind == ApprovalKind.enable && request.origin == origin) {
        final completer = _completers[request.id];
        if (completer != null) return (id: request.id, result: completer.future);
      }
    }
    return null;
  }

  /// Adds chains to a pending connection request; the user sees the merged list.
  void extendChains(String id, Iterable<String> chainIds) {
    for (final request in _queue) {
      if (request.id != id) continue;
      final merged = {...request.chainIds, ...chainIds}.toList();
      if (merged.length == request.chainIds.length) return;
      request.chainIds = merged;
      _notify();
      return;
    }
  }

  bool resolve(String id, ApprovalAnswer answer) =>
      answer.approved ? _settle(id, answer: answer) : reject(id);

  /// The page reads the reason, so it keeps Keplr's wording by default.
  bool reject(
    String id, {
    String reason = 'Request rejected',
    String code = ProviderErrorCode.userRejected,
  }) =>
      _settle(id, error: ProviderError(code, reason));

  /// Rejects every pending request [where] selects. Returns how many.
  int rejectWhere(
    bool Function(ApprovalRequest request) where, {
    String reason = 'Request rejected',
    String code = ProviderErrorCode.userRejected,
  }) {
    final ids = [for (final r in _queue) if (where(r)) r.id];
    for (final id in ids) {
      reject(id, reason: reason, code: code);
    }
    return ids.length;
  }

  void dispose({String reason = 'Request rejected'}) {
    rejectWhere((_) => true, reason: reason);
    _changes.close();
  }
}
