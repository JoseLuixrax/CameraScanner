import 'dart:math' as math;

import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:camera_scanner/processing/perspective.dart';

/// Genera una "foto" sintética: un documento (papel claro con líneas de
/// texto) en perspectiva sobre un fondo con textura.
RgbImage syntheticPhoto({
  required int width,
  required int height,
  required Quad corners,
  List<int> background = const [110, 80, 55],
  List<int> paper = const [240, 238, 232],
  double shadow = 0,
  int seed = 7,
}) {
  final rnd = math.Random(seed);
  final img = RgbImage(width, height);
  // Homografía imagen → documento (cuadrado unidad).
  final h = Homography.fromPoints(corners.points, const [
    Pt(0, 0),
    Pt(1, 0),
    Pt(1, 1),
    Pt(0, 1),
  ])!;
  // Patrón de "palabras": por línea, segmentos de distinta longitud.
  final words = <List<double>>[];
  for (var line = 0; line < 30; line++) {
    final segs = <double>[];
    var x = 0.08;
    while (x < 0.9) {
      final len = 0.03 + rnd.nextDouble() * 0.1;
      segs.addAll([x, math.min(0.92, x + len)]);
      x += len + 0.02;
    }
    words.add(segs);
  }
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = h.apply(Pt(x + 0.5, y + 0.5));
      final o = (y * width + x) * 3;
      // Iluminación no uniforme (sombra diagonal).
      final light = 1 - shadow * (1 - (x / width + y / height) / 2);
      List<num> c;
      if (p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1) {
        c = paper;
        final lineF = (p.y - 0.12) / 0.028;
        final line = lineF.floor();
        if (line >= 0 && line < 28 && lineF - line < 0.45) {
          final segs = words[line];
          for (var s = 0; s < segs.length; s += 2) {
            if (p.x >= segs[s] && p.x <= segs[s + 1]) {
              c = const [40, 40, 45];
              break;
            }
          }
        }
      } else {
        final grain = math.sin(x * 0.15 + math.sin(y * 0.02) * 3) * 12;
        final n = rnd.nextInt(17) - 8;
        c = [
          background[0] + grain + n,
          background[1] + grain + n,
          background[2] + grain + n,
        ];
      }
      for (var k = 0; k < 3; k++) {
        img.data[o + k] = (c[k] * light).round().clamp(0, 255);
      }
    }
  }
  return img;
}

/// Proyecta un rectángulo `w x h` (plano Z = 0) con una cámara pinhole de
/// focal [f] (px), rotación (grados) y distancia [dist].
Quad projectRectangle({
  required double w,
  required double h,
  required double f,
  required int imageWidth,
  required int imageHeight,
  double rx = 0,
  double ry = 0,
  double rz = 0,
  double dist = 1000,
}) {
  final ax = rx * math.pi / 180,
      ay = ry * math.pi / 180,
      az = rz * math.pi / 180;
  List<double> rot(List<double> v) {
    // Rx
    var x = v[0];
    var y = v[1] * math.cos(ax) - v[2] * math.sin(ax);
    var z = v[1] * math.sin(ax) + v[2] * math.cos(ax);
    // Ry
    final x2 = x * math.cos(ay) + z * math.sin(ay);
    final z2 = -x * math.sin(ay) + z * math.cos(ay);
    x = x2;
    z = z2;
    // Rz
    final x3 = x * math.cos(az) - y * math.sin(az);
    final y3 = x * math.sin(az) + y * math.cos(az);
    return [x3, y3, z];
  }

  Pt proj(double X, double Y) {
    final p = rot([X, Y, 0]);
    final z = p[2] + dist;
    return Pt(f * p[0] / z + imageWidth / 2, f * p[1] / z + imageHeight / 2);
  }

  return Quad(
    proj(-w / 2, -h / 2),
    proj(w / 2, -h / 2),
    proj(w / 2, h / 2),
    proj(-w / 2, h / 2),
  );
}

double maxCornerError(Quad a, Quad b) {
  var m = 0.0;
  for (var i = 0; i < 4; i++) {
    m = math.max(m, a.points[i].distanceTo(b.points[i]));
  }
  return m;
}
