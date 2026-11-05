/// The wallet side of the in-app browser's `window.zunia`: every provider call
/// a page makes lands here, with the page's origin as the browser saw it
/// (zunia-extension/lib/provider-handler.ts, method for method).
///
/// Keys never enter the WebView. Calls that reveal or sign anything need a
/// live grant for that site and chain; signatures need the user's approval of
/// a prompt that describes the exact bytes the kernel then signs. Every failure
/// leaves as a [ProviderError] with one of the eight codes, so a page can tell
/// a refusal from a bad argument.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zunia_mobile/browser/approval_queue.dart';
import 'package:zunia_mobile/browser/chain_draft.dart';
import 'package:zunia_mobile/browser/fee_tiers.dart';
import 'package:zunia_mobile/browser/origin_risk.dart';
import 'package:zunia_mobile/browser/provider_errors.dart';
import 'package:zunia_mobile/browser/sign_review.dart';
import 'package:zunia_mobile/browser/site_grants.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/cosmos_signing.dart';
import 'package:zunia_mobile/connect/sign_in.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/state/signing_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// What the bridge needs from the rest of the app. The browser screen backs it
/// with Riverpod state; tests back it with fixed values.
abstract class ProviderWallet {
  /// The active account's phrase; null while the wallet is locked.
  String? get phrase;

  /// The active account: its `index` is the derivation index every signature
  /// is made at.
  WalletAccount? get activeAccount;

  /// Completes once the wallet is unlocked; throws LOCKED after [timeout].
  Future<void> whenUnlocked(Duration timeout);

  ChainEntry? findChain(String chainId);

  /// Every chain the wallet knows, registry rows and the user's own.
  List<ChainEntry> get chains;

  /// The id is a row of the bundled registry.
  bool isRegistryChain(String chainId);

  /// Saves a network a site proposed and the user approved.
  Future<void> addChain(ChainEntry entry);

  SigningSettings get settings;

  /// Addresses the address book holds or the user paid through a prompt.
  Future<Set<String>> knownRecipients();

  Future<void> rememberRecipients(Iterable<String> addresses);

  /// cw-ics721 bridges this wallet knows on [chainId].
  Set<String> nftBridges(String chainId) => const {};
}

/// The methods `window.zunia` implements (config/connect.ts `cosmosMethods`,
/// plus `sendTx`, which exists and always refuses).
const kProviderMethods = <String>{
  'enable',
  'disable',
  'getConnectedChains',
  'isLocked',
  'getKey',
  'getAccounts',
  'signAmino',
  'signDirect',
  'signArbitrary',
  'verifyArbitrary',
  'sendTx',
  'experimentalSuggestChain',
  'getChainInfos',
  'getChainInfosWithoutEndpoints',
};

/// Whether a page at [origin] may use the provider at all: https, or http on
/// this device for local dApp development (config/connect.ts
/// `contentScriptMatches`).
bool isProviderOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  final host = uri.host.toLowerCase();
  return uri.scheme == 'http' &&
      (host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]');
}

class _ActiveKey {
  const _ActiveKey(this.account, this.key);

  final WalletAccount account;
  final CosmosSigningKey key;
}

class DappProviderBridge {
  DappProviderBridge({
    required this.wallet,
    required this.grants,
    required this.approvals,
  });

  final ProviderWallet wallet;
  final SiteGrantStore grants;
  final ApprovalQueue approvals;

  /// Runs one call and answers in the bridge's wire shape: `{result}` or
  /// `{error, code}`.
  Future<Map<String, Object?>> handle({
    required String origin,
    required String method,
    required List<dynamic> args,
  }) async {
    try {
      return {'result': await dispatch(origin: origin, method: method, args: args)};
    } catch (error) {
      return asProviderError(error).toWire();
    }
  }

  /// Runs one call. Every failure is a [ProviderError]: the sign-doc and
  /// sign-in checks shared with Zunia Connect keep their codes.
  Future<Object?> dispatch({
    required String origin,
    required String method,
    required List<dynamic> args,
  }) async {
    try {
      return await _dispatch(origin: origin, method: method, args: args);
    } on ProviderError {
      rethrow;
    } on ConnectException catch (error) {
      throw asProviderError(error);
    }
  }

  Future<Object?> _dispatch({
    required String origin,
    required String method,
    required List<dynamic> args,
  }) async {
    if (!isProviderOrigin(origin)) {
      throw const ProviderError(
        ProviderErrorCode.originMismatch,
        'Zunia answers secure (https) pages only',
      );
    }
    Object? arg(int i) => i < args.length ? args[i] : null;
    switch (method) {
      case 'enable':
        return _enable(origin, arg(0));
      case 'getConnectedChains':
        // Read-only and silent: how a page restores its session on reload
        // without bringing up the unlock screen.
        final chainIds = await grants.connectedChains(origin);
        if (chainIds.isNotEmpty) await grants.touch(origin);
        return chainIds;
      case 'isLocked':
        // Only a connected site hears whether the user is at the wallet.
        if ((await grants.connectedChains(origin)).isEmpty) {
          throw const ProviderError(ProviderErrorCode.notConnected, 'Not authorized');
        }
        return wallet.phrase == null;
      case 'disable':
        final target = arg(0);
        if (target == null) {
          await grants.revokeSite(origin);
        } else {
          for (final chainId in _chainIds(target)) {
            await grants.revokeChain(origin, chainId);
          }
        }
        return null;
      case 'getKey':
        return _getKey(origin, _requireChainId(arg(0)));
      case 'getAccounts':
        // The offline signer always passes its chain. Without one there is no
        // grant to check, so there is nothing to answer.
        final chainId = _requireChainId(arg(0));
        await _requirePermission(origin, chainId);
        final active = _activeKey(await _unlockedPhrase(), chainId);
        await grants.touch(origin, chainId: chainId, address: active.key.address());
        return [
          {
            'address': active.key.address(),
            'algo': active.key.algo,
            'pubkey': active.key.publicKey.toList(),
          },
        ];
      case 'signAmino':
        return _signAmino(origin, args);
      case 'signDirect':
        return _signDirect(origin, args);
      case 'signArbitrary':
        return _signArbitrary(origin, args);
      case 'verifyArbitrary':
        return _verifyArbitrary(origin, args);
      case 'sendTx':
        // The wallet never becomes the broadcaster of record for a payload a
        // site supplied: it signs, and the site broadcasts.
        throw const ProviderError(
          ProviderErrorCode.unsupported,
          'Zunia does not broadcast dApp transactions. Request a signature with '
          'signAmino or signDirect and broadcast it from the dApp.',
        );
      case 'experimentalSuggestChain':
        return _suggestChain(origin, arg(0));
      case 'getChainInfos':
      case 'getChainInfosWithoutEndpoints':
        return publicChainInfos(wallet.chains);
      default:
        throw ProviderError(ProviderErrorCode.unsupported, 'Method not implemented: $method');
    }
  }

  /* ------------------------------------------------------------------------ */

  static String _requireChainId(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const ProviderError.invalid('chainId required');
    }
    return value;
  }

  static List<String> _chainIds(Object? value) {
    final list = value is List ? value : [value];
    return {
      for (final id in list)
        if (id is String && id.trim().isNotEmpty) id,
    }.toList();
  }

  void _requireKnownChain(String chainId) {
    if (wallet.findChain(chainId) == null) {
      throw ProviderError(
        ProviderErrorCode.unknownChain,
        'Zunia does not know the chain $chainId. Add it with experimentalSuggestChain first.',
      );
    }
  }

  Future<void> _requirePermission(String origin, String chainId) async {
    if (!await grants.hasPermission(origin, [chainId])) {
      throw const ProviderError(ProviderErrorCode.notConnected, 'Not authorized');
    }
  }

  Future<String> _unlockedPhrase() async {
    var phrase = wallet.phrase;
    if (phrase == null) {
      await wallet.whenUnlocked(kApprovalTtl);
      phrase = wallet.phrase;
    }
    if (phrase == null) throw const ProviderError(ProviderErrorCode.locked, 'Wallet is locked');
    return phrase;
  }

  _ActiveKey _activeKey(String phrase, String chainId) {
    final account = wallet.activeAccount;
    if (account == null) throw const ProviderError(ProviderErrorCode.internal, 'No account');
    final chain = wallet.findChain(chainId);
    if (chain == null) {
      throw ProviderError(ProviderErrorCode.unknownChain, 'Zunia does not know the chain $chainId.');
    }
    return _ActiveKey(
      account,
      CosmosSigningKey(phrase: phrase, chain: chain, accountIndex: account.index),
    );
  }

  /// The signer the site named must be the account Zunia would sign with.
  static void _assertSigner(Object? requested, String active) {
    if (requested is! String || requested != active) {
      throw const ProviderError.invalid(
        'The requested signer is not the active account for this site. Switch accounts in Zunia and try again.',
      );
    }
  }

  /// After the user approves, the session and the active account are read
  /// again: the wallet may have locked, or the user switched accounts while
  /// the prompt was open. Either way the key checked before is not the one
  /// that would sign.
  _ActiveKey _keyAfterApproval(String chainId, String signer, String accountId) {
    final phrase = wallet.phrase;
    if (phrase == null) {
      throw const ProviderError(ProviderErrorCode.locked, 'Wallet locked before signing');
    }
    final active = _activeKey(phrase, chainId);
    if (active.account.id != accountId) {
      throw const ProviderError.invalid(
        'The active account changed while the request was open. Ask the site to try again.',
      );
    }
    _assertSigner(signer, active.key.address());
    return active;
  }

  List<String> _originWarnings(String origin) => assessOrigin(origin).warnings;

  Future<ReviewContext> _reviewContext(String chainId) async => ReviewContext(
        chain: wallet.findChain(chainId),
        knownRecipients: await wallet.knownRecipients(),
        blindSigning: wallet.settings.blindSigning,
        nftBridges: wallet.nftBridges(chainId),
      );

  Future<ApprovalAnswer> _approve(EnqueuedApproval queued) async {
    final answer = await queued.result;
    if (!answer.approved) throw const ProviderError.rejected();
    return answer;
  }

  /// The tier the user picked, when it differs from the site's fee.
  static FeeTier? _pickedTier(FeeChoice? choice, ApprovalAnswer answer) {
    final tier = answer.feeTier;
    if (choice == null || tier == null) return null;
    return choice.tiers[tier] == choice.site ? null : tier;
  }

  static Map<String, Object?> _stdSignature(CosmosSigningKey key, Uint8List signBytes) =>
      key.stdSignature(signBytes);

  /* ------------------------------------------------------------------------ */

  Future<Object?> _enable(String origin, Object? requested) async {
    final chainIds = _chainIds(requested);
    if (chainIds.isEmpty) throw const ProviderError.invalid('chainId required');
    chainIds.forEach(_requireKnownChain);

    if (wallet.phrase == null) await wallet.whenUnlocked(kApprovalTtl);
    if (await grants.hasPermission(origin, chainIds)) {
      await grants.touch(origin);
      return null;
    }

    final joined = approvals.findPendingEnable(origin);
    final Future<ApprovalAnswer> result;
    if (joined != null) {
      approvals.extendChains(joined.id, chainIds);
      result = joined.result;
    } else {
      final queued = approvals.enqueue(
        kind: ApprovalKind.enable,
        origin: origin,
        chainIds: chainIds,
        title: 'Connect to $origin',
        warnings: _originWarnings(origin),
      );
      result = queued.result;
    }
    final answer = await result;
    if (!answer.approved) throw const ProviderError.rejected();
    // Each call grants its own chains; a joined call's are granted by it.
    await grants.grant(origin, chainIds);
    return null;
  }

  Future<Map<String, Object?>> _getKey(String origin, String chainId) async {
    await _requirePermission(origin, chainId);
    final active = _activeKey(await _unlockedPhrase(), chainId);
    final address = active.key.address();
    await grants.touch(origin, chainId: chainId, address: address);
    return {
      'name': active.account.name,
      'algo': active.key.algo,
      'pubKey': active.key.publicKey.toList(),
      'address': address,
      'bech32Address': address,
      'isNanoLedger': false,
      if (active.key.chain.usesEthAddress) 'ethereumHexAddress': ethereumHexAddress(address),
    };
  }

  Future<Object?> _signAmino(String origin, List<dynamic> args) async {
    final chainId = _requireChainId(args.isNotEmpty ? args[0] : null);
    final signer = args.length > 1 ? args[1] : null;
    final rawDoc = args.length > 2 ? args[2] : null;
    final preferNoSetFee = preferNoSetFeeFrom(args.length > 3 ? args[3] : null);
    await _requirePermission(origin, chainId);
    assertSameChain(chainId, aminoSignDocChainId(rawDoc));
    final signDoc = Map<String, dynamic>.from(rawDoc as Map);
    final before = _activeKey(await _unlockedPhrase(), chainId);
    _assertSigner(signer, before.key.address());

    final review = reviewAminoSignDoc(
      expectedChainId: chainId,
      signDoc: signDoc,
      context: await _reviewContext(chainId),
    );
    if (review.requiresBlindSigning) throw blindSigningRefusal(review);
    final feeChoice = feeChoiceFor(
      wallet.findChain(chainId),
      aminoFeeOf(signDoc),
      preferNoSetFee: preferNoSetFee,
    );
    final answer = await _approve(
      approvals.enqueue(
        kind: ApprovalKind.signAmino,
        origin: origin,
        chainIds: [chainId],
        title: 'Sign transaction on $chainId',
        signer: signer as String,
        review: review,
        feeChoice: feeChoice,
        json: previewJson(signDoc),
        warnings: [..._originWarnings(origin), ...review.warnings],
      ),
    );

    final key = _keyAfterApproval(chainId, signer, before.account.id).key;
    await wallet.rememberRecipients([for (final m in review.messages) ?m.recipient]);

    // The site reads the fee back from `signed`, as CosmJS does, so a tier the
    // user picked is what gets broadcast.
    final tier = _pickedTier(feeChoice, answer);
    final signed = tier != null && feeChoice != null
        ? withAminoFee(signDoc, FeeCoin(feeChoice.denom, feeChoice.amountFor(tier)))
        : signDoc;
    final signature = _stdSignature(key, aminoSignBytes(signed));
    await grants.touch(origin, chainId: chainId, address: key.address());
    return {'signed': signed, 'signature': signature};
  }

  Future<Object?> _signDirect(String origin, List<dynamic> args) async {
    final chainId = _requireChainId(args.isNotEmpty ? args[0] : null);
    final signer = args.length > 1 ? args[1] : null;
    final preferNoSetFee = preferNoSetFeeFrom(args.length > 3 ? args[3] : null);
    await _requirePermission(origin, chainId);
    final doc = DirectSignDoc.fromProvider(args.length > 2 ? args[2] : null);
    assertSameChain(chainId, doc.chainId);
    final signBytes = doc.signBytes;
    final before = _activeKey(await _unlockedPhrase(), chainId);
    _assertSigner(signer, before.key.address());

    final review = reviewDirectSignBytes(
      expectedChainId: chainId,
      signBytes: signBytes,
      context: await _reviewContext(chainId),
    );
    if (review.requiresBlindSigning) throw blindSigningRefusal(review);
    final feeChoice = feeChoiceFor(
      wallet.findChain(chainId),
      authInfoFee(doc.authInfoBytes),
      preferNoSetFee: preferNoSetFee,
    );
    final answer = await _approve(
      approvals.enqueue(
        kind: ApprovalKind.signDirect,
        origin: origin,
        chainIds: [chainId],
        title: 'Sign transaction on $chainId',
        signer: signer as String,
        review: review,
        feeChoice: feeChoice,
        json: directPreviewJson(review),
        warnings: [..._originWarnings(origin), ...review.warnings],
      ),
    );

    final key = _keyAfterApproval(chainId, signer, before.account.id).key;
    await wallet.rememberRecipients([for (final m in review.messages) ?m.recipient]);

    final tier = _pickedTier(feeChoice, answer);
    var signedDoc = doc;
    if (tier != null && feeChoice != null) {
      final coin = FeeCoin(feeChoice.denom, feeChoice.amountFor(tier));
      signedDoc = doc.withAuthInfo(withAuthInfoFee(doc.authInfoBytes, coin));
      // Read the rewritten bytes back: only the fee coin may differ.
      final check = authInfoFee(signedDoc.authInfoBytes);
      if (check == null ||
          check.gas != feeChoice.gas ||
          check.amount.length != 1 ||
          check.amount.single != coin) {
        throw const ProviderError(
          ProviderErrorCode.internal,
          'Zunia could not change the fee safely, so nothing was signed.',
        );
      }
    }
    final signature = _stdSignature(
      key,
      identical(signedDoc, doc) ? signBytes : signedDoc.signBytes,
    );
    await grants.touch(origin, chainId: chainId, address: key.address());
    return {
      'signed': signedDoc.toProviderWire(),
      'signature': signature,
      'feeChanged': !identical(signedDoc, doc),
    };
  }

  Future<Object?> _signArbitrary(String origin, List<dynamic> args) async {
    final chainId = _requireChainId(args.isNotEmpty ? args[0] : null);
    final signer = args.length > 1 ? args[1] : null;
    final data = args.length > 2 ? args[2] : null;
    if (signer is! String || signer.isEmpty) throw const ProviderError.invalid('signer required');
    if (data == null) throw const ProviderError.invalid('data required');
    await _requirePermission(origin, chainId);
    final bytes = data is String ? Uint8List.fromList(utf8.encode(data)) : bytesFromWire(data, 'data');
    if (!adr36PayloadIsSafe(bytes)) {
      throw const ProviderError.invalid(
        'ADR-36 data looks like a transaction sign doc; refusing to sign',
      );
    }
    final signIn = _signInFor(bytes, origin: origin, chainId: chainId, signer: signer);
    final before = _activeKey(await _unlockedPhrase(), chainId);
    _assertSigner(signer, before.key.address());

    await _approve(
      approvals.enqueue(
        kind: ApprovalKind.signArbitrary,
        origin: origin,
        chainIds: [chainId],
        title: signIn != null ? 'Sign in to ${signIn.message.domain}' : 'Sign message on $chainId',
        signer: signer,
        messagePreview: previewText(bytes),
        encoding: data is String ? 'utf8' : 'bytes',
        signIn: signIn?.message,
        signInText: signIn?.text,
        warnings: _originWarnings(origin),
      ),
    );

    final key = _keyAfterApproval(chainId, signer, before.account.id).key;
    final signature = _stdSignature(key, adr36SignBytes(signer, bytes));
    await grants.touch(origin, chainId: chainId, address: key.address());
    // Keplr's contract: the StdSignature itself, which cosmos-kit, graz and
    // the Zunia SDK pass to their ADR-036 verifiers.
    return signature;
  }

  /// The sign-in a message carries, checked against the request, or null for
  /// a plain message. Anything that reads like a sign-in but does not pass is
  /// refused here, before any prompt opens.
  ({SignInMessage message, String text})? _signInFor(
    Uint8List bytes, {
    required String origin,
    required String chainId,
    required String signer,
  }) {
    if (!looksLikeSignIn(utf8.decode(bytes, allowMalformed: true))) return null;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const ProviderError.invalid('The sign-in message is not valid UTF-8');
    }
    final message = parseSignInMessage(text);
    checkSignInBinding(message, origin: origin, chainId: chainId, signer: signer);
    return (message: message, text: text);
  }

  Future<bool> _verifyArbitrary(String origin, List<dynamic> args) async {
    final chainId = _requireChainId(args.isNotEmpty ? args[0] : null);
    final signer = args.length > 1 && args[1] != null ? '${args[1]}' : '';
    final data = args.length > 2 ? args[2] : null;
    final signature = args.length > 3 ? args[3] : null;
    if (signer.isEmpty || data == null || signature == null) {
      throw const ProviderError.invalid('chainId, signer, data, and signature required');
    }
    await _requirePermission(origin, chainId);
    final bytes = data is String ? Uint8List.fromList(utf8.encode(data)) : bytesFromWire(data, 'data');
    if (!adr36PayloadIsSafe(bytes)) return false;

    final Uint8List publicKey;
    final Uint8List signatureBytes;
    if (signature is String) {
      // A bare signature: checked against the active account's key.
      final phrase = wallet.phrase;
      if (phrase == null) throw const ProviderError(ProviderErrorCode.locked, 'Wallet is locked');
      publicKey = _activeKey(phrase, chainId).key.publicKey;
      signatureBytes = _signatureBytes(signature, 'signature');
    } else if (signature is Map) {
      final pubKey = signature['pub_key'];
      final value = pubKey is Map ? pubKey['value'] : null;
      final sig = signature['signature'];
      if (value == null || sig == null || value == '' || sig == '') {
        throw const ProviderError.invalid('signature.pub_key.value and signature.signature required');
      }
      publicKey = _signatureBytes(value, 'pub_key');
      signatureBytes = _signatureBytes(sig, 'signature');
    } else {
      throw const ProviderError.invalid('Invalid signature');
    }
    return verifyAdr36(signer: signer, data: bytes, publicKey: publicKey, signature: signatureBytes);
  }

  /// A key or signature as a page passes it: a byte array, hex (with or
  /// without `0x`) or base64, read the way the extension's `wireBytesOf` does.
  static Uint8List _signatureBytes(Object? raw, String label) {
    if (raw is List) return bytesFromWire(raw, label);
    if (raw is! String) throw ProviderError.invalid('Invalid $label');
    final value = raw.trim();
    final hex = value.startsWith('0x') ? value.substring(2) : value;
    if (hex.isNotEmpty && hex.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      return bytesOfHex(hex);
    }
    try {
      return base64.decode(base64.normalize(value));
    } on FormatException {
      throw ProviderError.invalid('Invalid $label');
    }
  }

  Future<Object?> _suggestChain(String origin, Object? info) async {
    final draft = draftFromSuggestedChain(info, isRegistryChain: wallet.isRegistryChain);
    // Already known, from the registry or an earlier suggestion: nothing to ask.
    if (wallet.findChain(draft.chainId) != null) return null;
    await _approve(
      approvals.enqueue(
        kind: ApprovalKind.suggestChain,
        origin: origin,
        chainIds: [draft.chainId],
        title: 'Add ${draft.chainName}',
        draft: draft,
        warnings: [
          ..._originWarnings(origin),
          'Balances and transactions for this network will go through the endpoints below, which this site chose.',
        ],
      ),
    );
    await wallet.addChain(draft);
    return null;
  }
}

/// What the prompt shows of a message: the text when it is plain printable
/// text (tab and line breaks allowed), cut at 280 characters; hex otherwise,
/// so a hidden character cannot change what the user reads.
String previewText(Uint8List bytes) {
  String? text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = null;
  }
  if (text != null && RegExp(r'^[\x09\x0a\x0d\x20-\x7e]*$').hasMatch(text)) {
    return text.length > 280 ? '${text.substring(0, 277)}…' : text;
  }
  final hex = StringBuffer();
  for (final b in bytes) {
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  final all = hex.toString();
  return all.length > 96 ? '0x${all.substring(0, 96)}…' : '0x$all';
}

/// Chains a page may learn about. Never endpoints: a user's own node URL can
/// carry a key.
List<Map<String, Object?>> publicChainInfos(List<ChainEntry> chains) {
  final byId = <String, Map<String, Object?>>{};
  for (final c in chains) {
    final p = c.bech32Prefix;
    final feeDenom = c.feeMinimalDenom.isEmpty ? c.coinMinimalDenom : c.feeMinimalDenom;
    byId[c.chainId] = {
      'chainId': c.chainId,
      'chainName': c.chainName,
      'bech32Prefix': p,
      'bip44': {'coinType': c.coinType},
      'network': c.network,
      'currencies': [
        {
          'coinDenom': c.coinDenom,
          'coinMinimalDenom': c.coinMinimalDenom,
          'coinDecimals': c.coinDecimals,
        },
      ],
      'feeCurrencies': [
        {
          'coinDenom': c.feeMinimalDenom.isEmpty ? c.coinDenom : c.feeDenom,
          'coinMinimalDenom': feeDenom,
          'coinDecimals': c.feeMinimalDenom.isEmpty ? c.coinDecimals : c.feeDecimals,
          'gasPriceStep': c.gasPriceStep ?? const {'low': 0.01, 'average': 0.025, 'high': 0.04},
        },
      ],
      'bech32Config': {
        'bech32PrefixAccAddr': p,
        'bech32PrefixAccPub': '${p}pub',
        'bech32PrefixValAddr': '${p}valoper',
        'bech32PrefixValPub': '${p}valoperpub',
        'bech32PrefixConsAddr': '${p}valcons',
        'bech32PrefixConsPub': '${p}valconspub',
      },
      if (c.features != null) 'features': c.features,
    };
  }
  return byId.values.toList();
}
