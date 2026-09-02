import 'package:flutter/material.dart';
import 'package:qr/qr.dart' as qr;
import 'package:zunia_ui/zunia_ui.dart';

/// QR code rendered on device. An address never travels to an image service.
class QrCode extends StatelessWidget {
  const QrCode({super.key, required this.data, this.size = 190});

  final String data;
  final double size;

  static qr.QrImage? _encode(String data) {
    try {
      return qr.QrImage(
        qr.QrCode.fromData(
          data: data,
          errorCorrectLevel: qr.QrErrorCorrectLevel.M,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ZuniaSemanticsExt.of(context);
    final image = _encode(data);
    if (image == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(Icons.qr_code_2, size: size * 0.4, color: s.fgDim),
        ),
      );
    }

    // The quiet zone and light modules must stay white for scanners, so this
    // block does not follow the app theme.
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.image);

  final qr.QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final modules = image.moduleCount;
    final cell = size.width / modules;
    final paint = Paint()..color = const Color(0xFF000000);

    for (var x = 0; x < modules; x++) {
      for (var y = 0; y < modules; y++) {
        if (!image.isDark(y, x)) continue;
        canvas.drawRect(
          // A hair of overdraw keeps neighbouring modules from showing seams
          // at fractional device pixel ratios.
          Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
