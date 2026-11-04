import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../processing/geometry.dart';

/// Editor de las 4 esquinas del documento sobre la foto.
///
/// * Arrastra una esquina para moverla (con lupa para precisión).
/// * Arrastra el punto medio de un lado para desplazar ese lado entero.
///
/// [quad] está normalizado (0..1) respecto a la imagen.
class CropEditor extends StatefulWidget {
  const CropEditor({
    super.key,
    required this.image,
    required this.imageSize,
    required this.quad,
    required this.onChanged,
  });

  final ImageProvider image;
  final Size imageSize;
  final Quad quad;
  final ValueChanged<Quad> onChanged;

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  static const double _padding = 28;
  static const double _hitRadius = 40;
  static const Size _loupeSize = Size(120, 120);

  /// 0..3 esquinas, 4..7 puntos medios de los lados, null = nada.
  int? _active;
  Offset? _touch;

  /// Estado al empezar el arrastre: se calcula siempre el desplazamiento
  /// total desde aquí (no se acumulan deltas), así no se pierde movimiento
  /// aunque lleguen varios eventos táctiles antes de reconstruir el widget.
  Offset _dragOrigin = Offset.zero;
  Quad _dragQuad = Quad.rect(1, 1);

  Rect _imageRect(Size box) {
    final avail = Size(
      math.max(1, box.width - _padding * 2),
      math.max(1, box.height - _padding * 2),
    );
    final fitted = applyBoxFit(BoxFit.contain, widget.imageSize, avail);
    final size = fitted.destination;
    return Rect.fromLTWH(
      (box.width - size.width) / 2,
      (box.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  Offset _toScreen(Pt p, Rect r) =>
      Offset(r.left + p.x * r.width, r.top + p.y * r.height);

  Pt _toNorm(Offset o, Rect r) => Pt(
    ((o.dx - r.left) / r.width).clamp(0.0, 1.0),
    ((o.dy - r.top) / r.height).clamp(0.0, 1.0),
  );

  List<Offset> _handles(Quad quad, Rect r) {
    final c = quad.points.map((p) => _toScreen(p, r)).toList();
    return [
      ...c,
      for (var i = 0; i < 4; i++) Offset.lerp(c[i], c[(i + 1) % 4], 0.5)!,
    ];
  }

  void _onPanStart(DragStartDetails d, Rect r) {
    final handles = _handles(widget.quad, r);
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < handles.length; i++) {
      // Las esquinas tienen prioridad sobre los puntos medios.
      final dist = (handles[i] - d.localPosition).distance + (i >= 4 ? 12 : 0);
      if (dist < bestD) {
        bestD = dist;
        best = i;
      }
    }
    if (best != null && bestD <= _hitRadius) {
      _dragOrigin = d.localPosition;
      _dragQuad = widget.quad;
      setState(() {
        _active = best;
        _touch = handles[best!];
      });
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Rect r) {
    final a = _active;
    if (a == null) return;
    final total = d.localPosition - _dragOrigin;
    final q = _dragQuad;
    if (a < 4) {
      final np = _toNorm(_toScreen(q.points[a], r) + total, r);
      widget.onChanged(q.withCorner(a, np));
      setState(() => _touch = _toScreen(np, r));
    } else {
      final i = a - 4;
      final j = (i + 1) % 4;
      final pts = q.points;
      pts[i] = _toNorm(_toScreen(pts[i], r) + total, r);
      pts[j] = _toNorm(_toScreen(pts[j], r) + total, r);
      widget.onChanged(Quad.fromPoints(pts));
      setState(
        () => _touch = Offset.lerp(
          _toScreen(pts[i], r),
          _toScreen(pts[j], r),
          0.5,
        ),
      );
    }
  }

  void _onPanEnd() => setState(() {
    _active = null;
    _touch = null;
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final r = _imageRect(box);
        final valid = widget.quad.isConvex;

        Widget? loupe;
        final touch = _touch;
        if (touch != null && _active != null && _active! < 4) {
          // Lupa por encima del dedo (o por debajo si no cabe).
          var center = touch - const Offset(0, 110);
          if (center.dy - _loupeSize.height / 2 < 0) {
            center = touch + const Offset(0, 110);
          }
          center = Offset(
            center.dx.clamp(
              _loupeSize.width / 2,
              math.max(_loupeSize.width / 2, box.width - _loupeSize.width / 2),
            ),
            center.dy,
          );
          loupe = Positioned(
            left: center.dx - _loupeSize.width / 2,
            top: center.dy - _loupeSize.height / 2,
            child: RawMagnifier(
              size: _loupeSize,
              magnificationScale: 2.2,
              focalPointOffset: touch - center,
              decoration: const MagnifierDecoration(
                shape: CircleBorder(
                  side: BorderSide(color: Colors.white, width: 3),
                ),
                shadows: [BoxShadow(blurRadius: 8, color: Colors.black45)],
              ),
              child: CustomPaint(
                size: _loupeSize,
                painter: _CrosshairPainter(scheme.primary),
              ),
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Empieza a contar desde que se toca: la esquina sigue al dedo sin
          // el retraso del "touch slop".
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _onPanStart(d, r),
          onPanUpdate: (d) => _onPanUpdate(d, r),
          onPanEnd: (_) => _onPanEnd(),
          onPanCancel: _onPanEnd,
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: r,
                child: Image(
                  image: widget.image,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _QuadPainter(
                    handles: _handles(widget.quad, r),
                    imageRect: r,
                    active: _active,
                    color: valid ? scheme.primary : scheme.error,
                  ),
                ),
              ),
              ?loupe,
            ],
          ),
        );
      },
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter({
    required this.handles,
    required this.imageRect,
    required this.active,
    required this.color,
  });

  final List<Offset> handles;
  final Rect imageRect;
  final int? active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final corners = handles.sublist(0, 4);
    final quadPath = Path()..addPolygon(corners, true);

    // Oscurece lo que queda fuera del documento.
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(imageRect)
      ..addPath(quadPath, Offset.zero);
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    canvas.drawPath(
      quadPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color,
    );

    // Puntos medios.
    for (var i = 4; i < 8; i++) {
      final isActive = active == i;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: handles[i], width: 26, height: 10),
        const Radius.circular(5),
      );
      final a = corners[i - 4], b = corners[(i - 3) % 4];
      final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
      canvas.save();
      canvas.translate(handles[i].dx, handles[i].dy);
      canvas.rotate(angle);
      canvas.translate(-handles[i].dx, -handles[i].dy);
      canvas.drawRRect(rrect, Paint()..color = isActive ? color : Colors.white);
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      canvas.restore();
    }

    // Esquinas: anillos huecos para no tapar el punto exacto.
    for (var i = 0; i < 4; i++) {
      final isActive = active == i;
      canvas.drawCircle(
        handles[i],
        isActive ? 18 : 14,
        Paint()..color = color.withValues(alpha: isActive ? 0.35 : 0.2),
      );
      canvas.drawCircle(
        handles[i],
        isActive ? 18 : 14,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.white,
      );
      canvas.drawCircle(handles[i], 3, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) =>
      old.handles != handles || old.active != active || old.color != color;
}

class _CrosshairPainter extends CustomPainter {
  _CrosshairPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.drawLine(c - const Offset(14, 0), c + const Offset(14, 0), p);
    canvas.drawLine(c - const Offset(0, 14), c + const Offset(0, 14), p);
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.color != color;
}
