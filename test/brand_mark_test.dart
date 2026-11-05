import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zunia_mobile/ui/zunia_mark.dart';

/// The splash continues the native launch screen only if Flutter paints the
/// mark on the same pixels the platform drew. These compare ZuniaMark with the
/// artwork scripts/brand-assets.py generated for iOS and Android.
void main() {
  Future<Uint8List> paintMark(WidgetTester tester, {required double pixelRatio}) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(key: key, child: const ZuniaMark(height: 120)),
        ),
      ),
    );
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  Future<(int, int, Uint8List)> decode(WidgetTester tester, String path) async {
    return (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      final out = (frame.image.width, frame.image.height, data!.buffer.asUint8List());
      frame.image.dispose();
      return out;
    }))!;
  }

  /// Compares premultiplied colour, so edge pixels whose alpha differs by a
  /// rasteriser's rounding do not count as different hues.
  void expectSamePixels(Uint8List a, Uint8List b) {
    expect(a.length, b.length);
    var total = 0;
    var far = 0;
    for (var i = 0; i < a.length; i += 4) {
      for (var c = 0; c < 4; c++) {
        final av = c == 3 ? a[i + 3] : a[i + c] * a[i + 3] ~/ 255;
        final bv = c == 3 ? b[i + 3] : b[i + c] * b[i + 3] ~/ 255;
        final d = (av - bv).abs();
        total += d;
        if (d > 32) far++;
      }
    }
    final mean = total / a.length;
    // Anti-aliasing differs between Skia and cairo along the edges only; the
    // same artwork moved by a third of a point measures mean 1.2 / 3.9% far.
    expect(mean, lessThan(0.5), reason: 'mean channel difference $mean');
    expect(far / (a.length / 4), lessThan(0.01), reason: '$far channels differ by more than 32');
  }

  testWidgets('ZuniaMark paints the iOS launch mark at @3x', (tester) async {
    final flutter = await paintMark(tester, pixelRatio: 3);
    final (w, h, native) =
        await decode(tester, 'ios/Runner/Assets.xcassets/LaunchMark.imageset/LaunchMark@3x.png');
    expect((w, h), (288, 360));
    expectSamePixels(flutter, native);
  });

  testWidgets('ZuniaMark paints the Android launch mark at xxhdpi', (tester) async {
    final flutter = await paintMark(tester, pixelRatio: 3);
    final (_, _, native) =
        await decode(tester, 'android/app/src/main/res/drawable-xxhdpi/splash_mark.png');
    expectSamePixels(flutter, native);
  });

  testWidgets('the Android 12 splash vector keeps the mark at 1:1 in the centre', (tester) async {
    final xml = File('android/app/src/main/res/drawable-v31/splash_icon.xml').readAsStringSync();
    expect(xml, contains('android:width="288dp"'));
    expect(xml, contains('android:viewportWidth="288"'));
    // 96 x 120 grid centred on the 288 canvas: upper chevron starts at (26+96, 20+84).
    expect(xml, contains('android:pathData="M122.000,104.000 L166.000,130.000 L122.000,156.000"'));
  });
}
