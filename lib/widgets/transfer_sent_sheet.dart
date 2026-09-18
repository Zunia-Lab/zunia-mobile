import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen success after a wallet-originated broadcast.
Future<void> showTransferSent(
  BuildContext context, {
  required String txHash,
  String title = 'Transfer sent',
  VoidCallback? onDone,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _TransferSentPage(
        title: title,
        txHash: txHash,
        onDone: onDone,
      ),
    ),
  );
}

class _TransferSentPage extends StatelessWidget {
  const _TransferSentPage({
    required this.title,
    required this.txHash,
    this.onDone,
  });

  final String title;
  final String txHash;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: title,
          onBack: () {
            onDone?.call();
            Navigator.of(context).pop();
          },
          body: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            child: ZuniaTransferSent(
              title: title,
              hash: txHash,
              step: 2,
              total: 3,
              steps: const [
                (label: 'Signed', state: 'done'),
                (label: 'Broadcast', state: 'done'),
                (label: 'Included', state: 'current'),
              ],
              onDone: () {
                onDone?.call();
                Navigator.of(context).pop();
              },
            ),
          ),
        ),
      ),
    );
  }
}
