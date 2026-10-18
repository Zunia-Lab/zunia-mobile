/// "Pair a device": scan a site's or an app's code with the phone (or paste
/// the link), so someone without the extension can still use their wallet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/chains/chain_catalog.dart';
import 'package:zunia_mobile/connect/connect_crypto.dart';
import 'package:zunia_mobile/connect/connect_links.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/screens/connect_inbox.dart';
import 'package:zunia_mobile/screens/dapp_browser_screen.dart';
import 'package:zunia_mobile/screens/qr_scanner_screen.dart';
import 'package:zunia_mobile/screens/send_screen.dart';
import 'package:zunia_mobile/state/wallet_state.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Opens the camera, then acts on what was scanned.
Future<void> openPairDevice(BuildContext context, WidgetRef ref) async {
  final code = await Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const QrScannerScreen()));
  if (!context.mounted || code == null || code.isEmpty) return;
  await routeScannedCode(context, ref, code);
}

/// Acts on a scanned or pasted code. A scanned code was not opened by a
/// site on this phone, so nothing here ever sends the user to another app.
Future<void> routeScannedCode(
  BuildContext context,
  WidgetRef ref,
  String code,
) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  switch (classifyLink(code, scanned: true)) {
    case PairLink(:final link):
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Contacting the site…'),
          duration: Duration(seconds: 30),
        ),
      );
      try {
        // The connect sheet opens with the code once the site's request is in.
        await ref.read(nativeConnectProvider).pair(link);
        messenger.hideCurrentSnackBar();
      } catch (error) {
        say(_messageOf(error));
      }
    case WakeLink(:final sessionId):
      if (!ref.read(nativeConnectProvider).wake(sessionId)) {
        say('This code is for a site this phone is not connected to.');
      }
    case WalletConnectPairLink(:final uri):
      final wc = ref.read(walletConnectProvider);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Contacting the app…'),
          duration: Duration(seconds: 30),
        ),
      );
      try {
        if (!wc.isReady) await wc.init();
        await wc.pair(uri);
        messenger.hideCurrentSnackBar();
      } catch (error) {
        say(_messageOf(error, walletConnect: true));
      }
    case WalletConnectWakeLink():
      await ref.read(walletConnectProvider).wake();
    case DappLink(:final url):
      if (await confirmOpenDapp(context, url) && context.mounted) {
        await DappBrowserScreen.open(context, url: url.toString());
      }
    case AddressLink(:final address):
      if (context.mounted) await _onAddress(context, ref, address);
    case UnsupportedLink(:final reason):
      say(reason);
    case null:
      say('Zunia does not recognise this code.');
  }
}

String _messageOf(Object error, {bool walletConnect = false}) {
  if (error is ConnectException) return error.message;
  return walletConnect
      ? 'WalletConnect could not pair. Ask the app for a new code.'
      : 'Something went wrong. Ask the site for a new code.';
}

/// A payment address: offer to send to it.
Future<void> _onAddress(
  BuildContext context,
  WidgetRef ref,
  String address,
) async {
  final prefix = address.toLowerCase().split('1').first;
  final accounts = ref.read(chainAccountsProvider);
  String? chainId;
  for (final a in accounts) {
    if (a.chain.bech32Prefix == prefix) {
      chainId = a.chain.chainId;
      break;
    }
  }
  if (chainId == null && ChainCatalog.isLoaded) {
    for (final chain in ChainCatalog.instance.all) {
      if (chain.bech32Prefix == prefix) {
        chainId = chain.chainId;
        break;
      }
    }
  }
  final choice = await showZuniaActionSheet<String>(
    context,
    title: truncateAddress(address),
    message: chainId == null
        ? 'Zunia has no network for this address prefix ($prefix).'
        : 'An address on $chainId.',
    actions: [
      if (chainId != null)
        const ZuniaAlertAction(
          label: 'Send to this address',
          value: 'send',
          isDefault: true,
        ),
      const ZuniaAlertAction(label: 'Copy address', value: 'copy'),
    ],
  );
  if (!context.mounted || choice == null) return;
  await Clipboard.setData(ClipboardData(text: address));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (choice == 'send') {
    // Send picks the recipient on its next step; the address is on the
    // clipboard for it.
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => SendScreen(chainId: chainId))),
    );
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Address copied. Paste it as the recipient.'),
      ),
    );
  } else {
    messenger.showSnackBar(const SnackBar(content: Text('Address copied')));
  }
}
