import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The Zunia mark, painted from its construction instead of from a bitmap.
///
/// Two chevrons on a 96 x 120 grid, 24 stroke, round caps, as zunia-brand
/// defines them. Painting it means it is already on screen in the first frame
/// (an image would still be decoding) and stays sharp at any size, which is
/// what lets the splash continue the native launch screen without a jump.
///
/// [color] null draws the full-colour mark (zunia-mark-clean.svg); a colour
/// draws the one-colour mark whose upper chevron cuts a gap through the lower
/// one (zunia-mark-current.svg).
///
/// scripts/brand-assets.py renders the native launch and icon artwork from the
/// same geometry and colours: change both together.
class ZuniaMark extends StatelessWidget {
  const ZuniaMark({
    super.key,
    this.height = 120,
    this.color,
    this.semanticLabel,
  });

  /// Height of the 96 x 120 grid box; the width follows at 4:5.
  final double height;
  final Color? color;

  /// Null keeps the mark out of the semantics tree (decorative use).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final mark = CustomPaint(
      size: Size(height * ZuniaMarkPainter.gridWidth / ZuniaMarkPainter.gridHeight, height),
      painter: ZuniaMarkPainter(color: color),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}

class ZuniaMarkPainter extends CustomPainter {
  const ZuniaMarkPainter({this.color});

  final Color? color;

  static const double gridWidth = 96;
  static const double gridHeight = 120;
  static const double _stroke = 24;
  static const double _gapStroke = 30;

  static const _upper = [Offset(26, 20), Offset(70, 46), Offset(26, 72)];
  static const _lower = [Offset(26, 48), Offset(70, 74), Offset(26, 100)];

  // zunia-mark-clean.svg declares these in objectBoundingBox units over each
  // path's geometry; [_userSpace] turns them into the shader's user space.
  static final _upperShader = _gradient(
    _upper,
    const Offset(0.1, 0),
    const Offset(0.95, 0.9),
    const [Color(0xFFFF1B0C), Color(0xFFFF4E12), Color(0xFFFF8A17)],
    const [0, 0.55, 1],
  );
  static final _lowerShader = _gradient(
    _lower,
    const Offset(0.1, 1),
    const Offset(0.95, 0.1),
    const [Color(0xFFFF9A05), Color(0xFFFFBE14), Color(0xFFFFE05C)],
    const [0, 0.55, 1],
  );
  static final _crossShader = _gradient(
    _lower,
    Offset.zero,
    const Offset(1, 1),
    const [Color(0xFFD42800), Color(0xFFFF6A05)],
    const [0, 1],
  );

  /// The two ribbons overlap where the upper chevron's second arm crosses the
  /// lower one's first arm. Two equal strokes cross in a parallelogram, and it
  /// lies inside both straight runs (clear of the caps), so it is exactly the
  /// region the SVG masks and paints with the crossing gradient.
  static final Path _crossing = () {
    const h = _stroke / 2;
    final corners = <Offset>[];
    for (final (su, sl) in const [(1, 1), (1, -1), (-1, -1), (-1, 1)]) {
      corners.add(
        _intersect(
          _offsetLine(_upper[1], _upper[2], h * su),
          _offsetLine(_lower[0], _lower[1], h * sl),
        ),
      );
    }
    return Path()..addPolygon(corners, true);
  }();

  static (Offset, Offset) _offsetLine(Offset a, Offset b, double by) {
    final d = b - a;
    final n = Offset(-d.dy, d.dx) / d.distance;
    return (a + n * by, d);
  }

  static Offset _intersect((Offset, Offset) l1, (Offset, Offset) l2) {
    final (p, r) = l1;
    final (q, s) = l2;
    final cross = r.dx * s.dy - r.dy * s.dx;
    final t = ((q.dx - p.dx) * s.dy - (q.dy - p.dy) * s.dx) / cross;
    return p + r * t;
  }

  /// SVG evaluates a bounding-box gradient in the box's unit square, so on a
  /// box that is not square the colour bands are not perpendicular to the
  /// start-end line in user space. Solve for the user-space line along which
  /// the colour actually changes.
  static ui.Gradient _gradient(
    List<Offset> points,
    Offset from,
    Offset to,
    List<Color> colors,
    List<double> stops,
  ) {
    final box = _bounds(points);
    final d = to - from;
    final length2 = d.dx * d.dx + d.dy * d.dy;
    final gx = d.dx / (box.width * length2);
    final gy = d.dy / (box.height * length2);
    final g2 = gx * gx + gy * gy;
    final start = Offset(box.left + from.dx * box.width, box.top + from.dy * box.height);
    return ui.Gradient.linear(start, start + Offset(gx / g2, gy / g2), colors, stops);
  }

  static Rect _bounds(List<Offset> points) {
    var r = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  static Path _chevron(List<Offset> p) => Path()
    ..moveTo(p[0].dx, p[0].dy)
    ..lineTo(p[1].dx, p[1].dy)
    ..lineTo(p[2].dx, p[2].dy);

  static Paint _strokePaint(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / gridHeight;
    canvas.save();
    canvas.translate((size.width - gridWidth * scale) / 2, 0);
    canvas.scale(scale);
    final mono = color;
    if (mono == null) {
      canvas.drawPath(_chevron(_upper), _strokePaint(_stroke)..shader = _upperShader);
      canvas.drawPath(_chevron(_lower), _strokePaint(_stroke)..shader = _lowerShader);
      canvas.drawPath(_crossing, Paint()..shader = _crossShader);
    } else {
      // The gap is cut from the lower ribbon only, so it needs its own layer.
      canvas.saveLayer(const Rect.fromLTWH(0, 0, gridWidth, gridHeight), Paint());
      canvas.drawPath(_chevron(_lower), _strokePaint(_stroke)..color = mono);
      canvas.drawPath(
        _chevron(_upper),
        _strokePaint(_gapStroke)..blendMode = BlendMode.dstOut,
      );
      canvas.restore();
      canvas.drawPath(_chevron(_upper), _strokePaint(_stroke)..color = mono);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ZuniaMarkPainter oldDelegate) => oldDelegate.color != color;
}
