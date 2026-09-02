import 'package:flutter/material.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Confirmation after a send or stake review. No hash is shown because the
/// wallet does not broadcast yet.
class TransferSentScreen extends StatelessWidget {
  const TransferSentScreen({
    super.key,
    required this.title,
    required this.summary,
  });

  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 40,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 280,
                      height: 280,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            s.info.withValues(alpha: 0.35),
                            s.info.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
                child: Column(
                  children: [
                    const Spacer(),
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.accent.withValues(alpha: 0.24),
                        border: Border.all(
                          color: s.info.withValues(alpha: 0.6),
                        ),
                      ),
                      child: Icon(Icons.check, color: s.info, size: 34),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 25,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.9,
                        color: s.fg,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      summary,
                      textAlign: TextAlign.center,
                      style: zuniaSans(
                        fontSize: 13,
                        height: 1.6,
                        color: s.fgMuted,
                      ),
                    ),
                    const SizedBox(height: 26),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: s.surfaceRaisedGradient,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            const ZuniaKeyValueRow(
                              label: 'Source tx',
                              value: 'pending',
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Packet ack',
                                  style: zuniaMono(
                                    fontSize: 11,
                                    color: s.fgMuted,
                                  ),
                                ),
                                Text(
                                  'waiting',
                                  style: zuniaMono(
                                    fontSize: 11,
                                    color: s.info,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const ZuniaKeyValueRow(
                              label: 'Status',
                              value: 'on device',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    const ZuniaCallout(
                      tone: ZuniaCalloutTone.info,
                      title: 'Waiting on a signer',
                      body:
                          'The transfer is assembled on this device. It will leave '
                          'once a broadcast endpoint is configured.',
                    ),
                    const SizedBox(height: 16),
                    ZuniaButton(
                      label: 'Done',
                      size: ZuniaButtonSize.lg,
                      onPressed: () =>
                          Navigator.of(context).popUntil((r) => r.isFirst),
                    ),
                    const SizedBox(height: 14),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context).popUntil((r) => r.isFirst),
                      child: Text(
                        'Back to wallet',
                        style: zuniaMono(fontSize: 11.5, color: s.fgDim),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
