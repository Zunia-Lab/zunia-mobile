import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zunia_mobile/connect/connect_links.dart';
import 'package:zunia_mobile/util/address_payload.dart';
import 'package:zunia_ui/zunia_ui.dart';

/// Full-screen camera for codes: Zunia Connect and WalletConnect pairing
/// codes, wake links and payment addresses. Pops with the code as read.
///
/// Codes this screen does not take keep the camera running and say why, the
/// way the system camera ignores a QR code it cannot open. Someone pairing a
/// desktop site can also paste the link they copied.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({
    super.key,
    this.title = 'Pair a device',
    this.extractAddress = false,
  });

  final String title;

  /// Only take codes that hold a bech32 address, and pop with the address.
  final bool extractAddress;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String? _hint;
  String? _lastRejected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_handled) unawaited(_controller.start());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// What to pop with for [raw], or null with [_hint] saying why not.
  String? _accept(String raw) {
    if (widget.extractAddress) {
      final address = extractBech32Address(raw);
      if (address == null) _hint = 'That code has no address in it';
      return address;
    }
    switch (classifyLink(raw, scanned: true)) {
      case null:
        _hint = 'Zunia does not recognise this code';
        return null;
      case UnsupportedLink(:final reason):
        _hint = reason;
        return null;
      default:
        return raw.trim();
    }
  }

  void _take(String raw, {required bool fromCamera}) {
    if (_handled) return;
    final value = _accept(raw);
    if (value == null) {
      if (_lastRejected != raw) {
        _lastRejected = raw;
        unawaited(ZuniaHaptics.warning());
      }
      setState(() {});
      return;
    }
    _handled = true;
    unawaited(fromCamera ? ZuniaHaptics.light() : ZuniaHaptics.selection());
    unawaited(_controller.stop());
    Navigator.of(context).pop(value);
  }

  void _onDetect(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    _take(raw, fromCamera: true);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _hint = 'The clipboard is empty. Copy the link first.');
      return;
    }
    _take(text, fromCamera: false);
  }

  String get _instructions => widget.extractAddress
      ? 'Point at an address code'
      : 'Point at the code on the site or app';

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final side = (size.shortestSide * 0.68).clamp(180.0, 320.0);
            final window = Rect.fromCenter(
              center: Offset(size.width / 2, size.height * 0.44),
              width: side,
              height: side,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  scanWindow: window,
                  errorBuilder: (context, error) => _CameraUnavailable(
                    error: error,
                    onPaste: _paste,
                    hint: _hint,
                    extractAddress: widget.extractAddress,
                  ),
                ),
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _controller,
                  builder: (context, state, _) => state.error != null
                      ? const SizedBox.shrink()
                      : IgnorePointer(
                          child: CustomPaint(
                            painter: _ViewfinderPainter(
                              window: window,
                              scrim: Colors.black.withValues(alpha: 0.55),
                              corner: s.accent,
                            ),
                          ),
                        ),
                ),
                SafeArea(
                  child: Column(
                    children: [
                      _TopBar(
                        title: widget.title,
                        controller: _controller,
                        onClose: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      _BottomPanel(
                        instructions: _instructions,
                        hint: _hint,
                        controller: _controller,
                        onPaste: _paste,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.controller,
    required this.onClose,
  });

  final String title;
  final MobileScannerController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cupertino = ZuniaPlatform.isCupertino(context);
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: Icon(
              cupertino ? CupertinoIcons.xmark : Icons.close,
              color: Colors.white,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: cupertino ? TextAlign.center : TextAlign.start,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: zuniaSans(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: controller,
            builder: (context, state, _) {
              final torch = state.torchState;
              if (torch == TorchState.unavailable || state.error != null) {
                return const SizedBox(width: 52);
              }
              final on = torch == TorchState.on;
              return IconButton(
                tooltip: on ? 'Turn off the light' : 'Turn on the light',
                onPressed: () {
                  unawaited(ZuniaHaptics.selection());
                  unawaited(controller.toggleTorch());
                },
                icon: Icon(
                  cupertino
                      ? (on ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt)
                      : (on ? Icons.flashlight_on : Icons.flashlight_off),
                  color: on ? const Color(0xFFFFD60A) : Colors.white,
                ),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.instructions,
    required this.hint,
    required this.controller,
    required this.onPaste,
  });

  final String instructions;
  final String? hint;
  final MobileScannerController controller;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.error != null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                instructions,
                textAlign: TextAlign.center,
                style: zuniaSans(fontSize: 15, color: Colors.white),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: hint == null
                    ? const SizedBox(height: 8, key: ValueKey('none'))
                    : Padding(
                        key: ValueKey(hint),
                        padding: const EdgeInsets.only(top: 10),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            hint!,
                            textAlign: TextAlign.center,
                            style: zuniaSans(
                              fontSize: 13,
                              height: 1.35,
                              color: const Color(0xFFFFD60A),
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              _GlassButton(
                icon: Icons.content_paste,
                label: 'Paste a link',
                onPressed: onPaste,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: zuniaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// No camera: denied, missing or failing. Pasting still works.
class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({
    required this.error,
    required this.onPaste,
    required this.hint,
    required this.extractAddress,
  });

  final MobileScannerException error;
  final VoidCallback onPaste;
  final String? hint;
  final bool extractAddress;

  bool get _denied =>
      error.errorCode == MobileScannerErrorCode.permissionDenied;

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    return ColoredBox(
      color: s.screenMid,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 72, 28, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _denied
                      ? Icons.no_photography_outlined
                      : Icons.videocam_off_outlined,
                  size: 44,
                  color: s.fgMuted,
                ),
                const SizedBox(height: 18),
                Text(
                  _denied
                      ? 'Camera access is off'
                      : 'The camera is not available',
                  textAlign: TextAlign.center,
                  style: zuniaSans(
                    fontSize: 19,
                    fontWeight: FontWeight.w500,
                    color: s.fg,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _denied
                      ? 'Allow Zunia to use the camera in Settings to scan codes. '
                            'You can also paste a link you copied.'
                      : 'You can paste a link you copied instead.',
                  textAlign: TextAlign.center,
                  style: zuniaSans(fontSize: 14, height: 1.5, color: s.fgMuted),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    hint!,
                    textAlign: TextAlign.center,
                    style: zuniaSans(fontSize: 13, color: s.warning),
                  ),
                ],
                const SizedBox(height: 24),
                if (_denied)
                  ZuniaButton(
                    label: 'Open Settings',
                    size: ZuniaButtonSize.lg,
                    onPressed: () => unawaited(openAppSettings()),
                  ),
                const SizedBox(height: 10),
                ZuniaButton(
                  label: 'Paste a link',
                  variant: ZuniaButtonVariant.secondary,
                  size: ZuniaButtonSize.lg,
                  onPressed: onPaste,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _settingsChannel = MethodChannel('zunia/settings');

/// This app's page in the system Settings, where camera access is granted.
Future<void> openAppSettings() async {
  try {
    if (Platform.isIOS) {
      await launchUrl(Uri.parse('app-settings:'));
    } else {
      await _settingsChannel.invokeMethod<void>('openAppSettings');
    }
  } catch (e) {
    debugPrint('open settings: $e');
  }
}

/// Dims everything but the scan window and draws its corners.
class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({
    required this.window,
    required this.scrim,
    required this.corner,
  });

  final Rect window;
  final Color scrim;
  final Color corner;

  @override
  void paint(Canvas canvas, Size size) {
    final rounded = RRect.fromRectAndRadius(window, const Radius.circular(22));
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rounded);
    canvas.drawPath(outside, Paint()..color = scrim);

    final pen = Paint()
      ..color = corner
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const arm = 28.0;
    const r = 22.0;
    final l = window.left, t = window.top, ri = window.right, b = window.bottom;
    final path = Path()
      ..moveTo(l, t + arm)
      ..lineTo(l, t + r)
      ..arcToPoint(Offset(l + r, t), radius: const Radius.circular(r))
      ..lineTo(l + arm, t)
      ..moveTo(ri - arm, t)
      ..lineTo(ri - r, t)
      ..arcToPoint(Offset(ri, t + r), radius: const Radius.circular(r))
      ..lineTo(ri, t + arm)
      ..moveTo(ri, b - arm)
      ..lineTo(ri, b - r)
      ..arcToPoint(Offset(ri - r, b), radius: const Radius.circular(r))
      ..lineTo(ri - arm, b)
      ..moveTo(l + arm, b)
      ..lineTo(l + r, b)
      ..arcToPoint(Offset(l, b - r), radius: const Radius.circular(r))
      ..lineTo(l, b - arm);
    canvas.drawPath(path, pen);
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.window != window || old.scrim != scrim || old.corner != corner;
}
