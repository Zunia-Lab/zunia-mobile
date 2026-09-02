import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Camera QR scanner for WalletConnect / payment URIs.
///
/// Design treats pairing as passcode-gated before a code is shown. This screen
/// is the scan half of that flow; chrome matches the Pair a device aesthetic.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({
    super.key,
    this.title = 'Pair a device',
    this.extractAddress = false,
  });

  final String title;
  /// When true, only pop if the QR contains a bech32 address.
  final bool extractAddress;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;
  String _mode = 'scan';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    if (widget.extractAddress) {
      final address = extractBech32Address(raw);
      if (address == null) return;
      _handled = true;
      Navigator.of(context).pop(address);
      return;
    }
    _handled = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ZuniaScreenScaffold(
          title: widget.title,
          onBack: () => Navigator.of(context).pop(),
          trailing: widget.extractAddress
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: s.success,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'unlocked',
                      style: zuniaMono(fontSize: 9.5, color: s.success),
                    ),
                  ],
                ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.extractAddress)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: ZuniaSegmented<String>(
                    value: _mode,
                    onChanged: (v) => setState(() => _mode = v),
                    options: const {
                      'show': 'Show code',
                      'scan': 'Scan code',
                    },
                  ),
                ),
              Expanded(
                child: !widget.extractAddress && _mode == 'show'
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(26, 24, 26, 12),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 68,
                              height: 68,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                gradient: s.accentGradient,
                                boxShadow: [
                                  BoxShadow(
                                    color: s.accent.withValues(alpha: 0.45),
                                    blurRadius: 34,
                                    offset: const Offset(0, 14),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.lock_outline,
                                size: 32,
                                color: s.accentFg,
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              'Passcode required',
                              textAlign: TextAlign.center,
                              style: zuniaSans(
                                fontSize: 21,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.5,
                                color: s.fg,
                              ),
                            ),
                            const SizedBox(height: 11),
                            Text(
                              'A pairing code exposes read access to your '
                              'accounts, so Zunia asks for your passcode before '
                              'generating one. Use Scan code to import from '
                              'another device.',
                              textAlign: TextAlign.center,
                              style: zuniaSans(
                                fontSize: 12.5,
                                height: 1.6,
                                color: s.fgMuted,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Code expires 60 s after unlock',
                              style: zuniaMono(fontSize: 10.5, color: s.fgDim),
                            ),
                          ],
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              MobileScanner(
                                controller: _controller,
                                onDetect: _onDetect,
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        s.scrim.withValues(alpha: 0.85),
                                      ],
                                    ),
                                  ),
                                  child: Text(
                                    'Point at a WalletConnect or address QR',
                                    textAlign: TextAlign.center,
                                    style: zuniaSans(
                                      fontSize: 13,
                                      color: s.fg,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: s.warning.withValues(alpha: 0.1),
                    border: Border.all(
                      color: s.warning.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s.warning,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Never show a pairing code to anyone. It grants '
                          'read access.',
                          style: zuniaSans(
                            fontSize: 10,
                            height: 1.4,
                            color: s.warning.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          footer: _mode == 'show'
              ? ZuniaButton(
                  label: 'Switch to scan',
                  size: ZuniaButtonSize.lg,
                  onPressed: () => setState(() => _mode = 'scan'),
                )
              : null,
        ),
      ),
    );
  }
}
