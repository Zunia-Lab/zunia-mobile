/// Presents what sites and apps ask for while the wallet is unlocked: one
/// sheet at a time, oldest first, whatever the transport (Zunia Connect or
/// WalletConnect), and the links that waited behind the lock screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/connect/app_return.dart';
import 'package:zunia_mobile/connect/wallet_signer.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/native_request_sheets.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

class ConnectInbox extends ConsumerStatefulWidget {
  const ConnectInbox({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ConnectInbox> createState() => _ConnectInboxState();
}

class _ConnectInboxState extends ConsumerState<ConnectInbox>
    with WidgetsBindingObserver {
  final _subs = <StreamSubscription<dynamic>>[];
  ProviderSubscription<String?>? _accountSub;
  late final DeepLinkHandler _deep;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _deep = ref.read(deepLinkHandlerProvider);
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_listen);
  }

  void _listen() {
    if (!mounted) return;
    final native = ref.read(nativeConnectProvider);
    _subs
      ..add(native.changes.listen((_) => _showNext()))
      ..add(native.notices.listen(_onNotice))
      ..add(_deep.dappRequests.listen(_onDappLink));
    // By account id, not derivation index: accounts with their own phrase all
    // derive at index 0, and switching between them must still re-announce.
    _accountSub = ref.listenManual<String?>(
      walletProvider.select((w) => w.active?.id),
      _onAccountChanged,
    );
    // Links opened while the wallet was locked, then whatever waits.
    unawaited(_deep.attach());
    _showNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(ref.read(walletConnectProvider).resume());
        // The request the user left for is the first thing they see.
        _showNext();
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _subs) {
      sub.cancel();
    }
    _accountSub?.close();
    _deep.detach();
    super.dispose();
  }

  void _onNotice(NativeConnectNotice notice) {
    if (!mounted) return;
    final target = notice.returnTarget;
    if (notice.error) unawaited(ZuniaHaptics.warning());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(notice.message),
        action: target == null
            ? null
            : SnackBarAction(
                label: 'Return',
                onPressed: () => unawaited(_openReturn(target)),
              ),
      ),
    );
  }

  static Future<void> _openReturn(ReturnTarget target) async {
    try {
      await launchUrl(target.uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('return link: $e');
    }
  }

  /// Shows what sites asked for, one sheet at a time, oldest first.
  Future<void> _showNext() async {
    if (!mounted || _busy) return;
    // Nothing is shown, let alone signed, behind the lock screen.
    if (ref.read(phraseProvider) == null) return;
    final native = ref.read(nativeConnectProvider);
    final pending = native.pendingRequests;
    if (pending.isEmpty) return;
    final request = pending.first;
    _busy = true;
    try {
      switch (request) {
        case NativeConnectRequest():
          await showNativeConnectSheet(context, request: request);
          // Dismissed without a choice: that is a no.
          if (native.isPending(request)) await native.rejectConnect(request);
        case NativeSignRequest():
          await showNativeSignSheet(context, request: request);
          if (native.isPending(request)) await native.rejectSign(request);
      }
    } catch (e) {
      debugPrint('connect request: $e');
    } finally {
      _busy = false;
    }
    unawaited(_showNext());
  }

  Future<void> _onDappLink(Uri url) async {
    if (!mounted) return;
    // Waits for the sheet in front, like any other request.
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
    }
    _busy = true;
    try {
      if (await confirmOpenDapp(context, url) && mounted) {
        await DappBrowserScreen.open(context, url: url.toString());
      }
    } finally {
      _busy = false;
    }
    unawaited(_showNext());
  }

  void _onAccountChanged(String? previous, String? next) {
    if (next == null || previous == null || previous == next) return;
    // The phrase is swapped before the account (WalletController._persist).
    final phrase = ref.read(phraseProvider);
    if (phrase == null) return;
    final active = ref.read(walletProvider).active;
    final index = active?.index ?? 0;
    final name = active?.name;
    List<NativeConnectAccount> accountsFor(List<String> chainIds) =>
        connectAccountsFor(
          phrase: phrase,
          accountIndex: index,
          chainIds: chainIds,
          accountName: name,
        );
    unawaited(
      ref
          .read(nativeConnectProvider)
          .switchAccount(accountIndex: index, accountsFor: accountsFor),
    );
    unawaited(
      ref
          .read(walletConnectProvider)
          .switchAccount(accountIndex: index, accountsFor: accountsFor),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Any app can open `zunia://dapp?url=...`, so the user sees the address and
/// decides before anything loads.
Future<bool> confirmOpenDapp(BuildContext context, Uri url) {
  return showZuniaConfirm(
    context,
    title: 'Open ${url.host}?',
    message:
        '${url.toString()}\n\nA link asked Zunia to open this site in its '
        'browser, where it can ask to connect to your wallet. Open it only if '
        'you trust it.',
    confirmLabel: 'Open',
  );
}
