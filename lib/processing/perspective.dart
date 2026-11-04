import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'image_ops.dart';

/// Homografía 3x3 (h22 = 1) que transforma puntos de un plano a otro.
class Homography {
  Homography._(this.m);

  final Float64List m;

  /// Homografía que lleva `src[i]` a `dst[i]` (4 correspondencias).
  static Homography? fromPoints(List<Pt> src, List<Pt> dst) {
    assert(src.length == 4 && dst.length == 4);
    // Sistema 8x8 aumentado.
    final a = List.generate(8, (_) => Float64List(9));
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y;
      final u = dst[i].x, v = dst[i].y;
      a[2 * i].setAll(0, [x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
      a[2 * i + 1].setAll(0, [0, 0, 0, x, y, 1, -v * x, -v * y, v]);
    }
    // Eliminación gaussiana con pivoteo parcial.
    for (var col = 0; col < 8; col++) {
      var piv = col;
      for (var r = col + 1; r < 8; r++) {
        if (a[r][col].abs() > a[piv][col].abs()) piv = r;
      }
      if (a[piv][col].abs() < 1e-12) return null;
      if (piv != col) {
        final t = a[piv];
        a[piv] = a[col];
        a[col] = t;
      }
      final p = a[col][col];
      for (var r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = a[r][col] / p;
        if (f == 0) continue;
        for (var c = col; c < 9; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    final m = Float64List(9);
    for (var i = 0; i < 8; i++) {
      m[i] = a[i][8] / a[i][i];
    }
    m[8] = 1;
    return Homography._(m);
  }

  Pt apply(Pt p) {
    final z = m[6] * p.x + m[7] * p.y + m[8];
    return Pt(
      (m[0] * p.x + m[1] * p.y + m[2]) / z,
      (m[3] * p.x + m[4] * p.y + m[5]) / z,
    );
  }
}

/// Estima el tamaño (ancho, alto) del documento rectificado a partir de las
/// esquinas en la foto, corrigiendo la relación de aspecto con el modelo de
/// cámara pinhole (Zhang & He, "Whiteboard scanning and image enhancement").
({int width, int height}) estimateOutputSize(
  Quad q,
  int imageWidth,
  int imageHeight, {
  int maxSide = 3000,
}) {
  final wTop = q.tl.distanceTo(q.tr), wBottom = q.bl.distanceTo(q.br);
  final hLeft = q.tl.distanceTo(q.bl), hRight = q.tr.distanceTo(q.br);
  var outW = math.max(wTop, wBottom);
  var outH = math.max(hLeft, hRight);
  if (outW < 1 || outH < 1) return (width: 1, height: 1);

  final ratio = trueAspectRatio(q, imageWidth, imageHeight);
  if (ratio != null) {
    final visible = outW / outH;
    if (ratio < visible) {
      outW = outH * ratio;
    } else {
      outH = outW / ratio;
    }
  }
  final long = math.max(outW, outH);
  if (long > maxSide) {
    outW *= maxSide / long;
    outH *= maxSide / long;
  }
  return (width: math.max(1, outW.round()), height: math.max(1, outH.round()));
}

/// Relación ancho/alto real del rectángulo fotografiado, o `null` si no se
/// puede estimar con fiabilidad.
double? trueAspectRatio(Quad q, int imageWidth, int imageHeight) {
  final u0 = imageWidth / 2, v0 = imageHeight / 2;
  final longSide = math.max(imageWidth, imageHeight).toDouble();
  List<double> h(Pt p) => [p.x - u0, p.y - v0, 1.0];
  final m1 = h(q.tl), m2 = h(q.tr), m3 = h(q.bl), m4 = h(q.br);

  List<double> cross(List<double> a, List<double> b) => [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  final d2 = dot(cross(m2, m4), m3);
  final d3 = dot(cross(m3, m4), m2);
  if (d2.abs() < 1e-9 || d3.abs() < 1e-9) return null;
  final k2 = dot(cross(m1, m4), m3) / d2;
  final k3 = dot(cross(m1, m4), m2) / d3;
  final n2 = [k2 * m2[0] - m1[0], k2 * m2[1] - m1[1], k2 * m2[2] - m1[2]];
  final n3 = [k3 * m3[0] - m1[0], k3 * m3[1] - m1[1], k3 * m3[2] - m1[2]];

  double ratioWith(double f2) => math.sqrt(
    (n2[0] * n2[0] + n2[1] * n2[1] + f2 * n2[2] * n2[2]) /
        (n3[0] * n3[0] + n3[1] * n3[1] + f2 * n3[2] * n3[2]),
  );

  double? result;
  final denom = n2[2] * n3[2];
  if (denom.abs() > 1e-12) {
    final f2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / denom;
    final f = f2 > 0 ? math.sqrt(f2) : -1;
    // Distancia focal plausible para un móvil: 0.4x – 3x el lado mayor.
    if (f > 0.4 * longSide && f < 3 * longSide) {
      result = ratioWith(f2);
    }
  }
  // Si la estimación es inestable (casi frontal), asume focal típica.
  result ??= ratioWith(math.pow(0.85 * longSide, 2).toDouble());
  if (!result.isFinite || result < 0.1 || result > 10) return null;
  return result;
}

/// Rectifica la región [quad] de [src] en una imagen de `outW x outH`.
RgbImage warpPerspective(RgbImage src, Quad quad, int outW, int outH) {
  final hm = Homography.fromPoints([
    const Pt(0, 0),
    Pt(outW.toDouble(), 0),
    Pt(outW.toDouble(), outH.toDouble()),
    Pt(0, outH.toDouble()),
  ], quad.points);
  if (hm == null) {
    throw StateError('No se puede calcular la transformación de perspectiva');
  }
  final m = hm.m;
  final out = RgbImage(outW, outH);
  final o = out.data;
  final s = src.data;
  final sw = src.width, sh = src.height;
  final maxX = sw - 1.0, maxY = sh - 1.0;
  var oi = 0;
  for (var y = 0; y < outH; y++) {
    final yc = y + 0.5;
    var xs = m[0] * 0.5 + m[1] * yc + m[2];
    var ys = m[3] * 0.5 + m[4] * yc + m[5];
    var zs = m[6] * 0.5 + m[7] * yc + m[8];
    for (var x = 0; x < outW; x++) {
      var u = xs / zs - 0.5;
      var v = ys / zs - 0.5;
      xs += m[0];
      ys += m[3];
      zs += m[6];
      if (u < 0) {
        u = 0;
      } else if (u > maxX) {
        u = maxX;
      }
      if (v < 0) {
        v = 0;
      } else if (v > maxY) {
        v = maxY;
      }
      final x0 = u.toInt(), y0 = v.toInt();
      final x1 = x0 < sw - 1 ? x0 + 1 : x0;
      final y1 = y0 < sh - 1 ? y0 + 1 : y0;
      final fx = u - x0, fy = v - y0;
      final i00 = (y0 * sw + x0) * 3;
      final i10 = (y0 * sw + x1) * 3;
      final i01 = (y1 * sw + x0) * 3;
      final i11 = (y1 * sw + x1) * 3;
      final w00 = (1 - fx) * (1 - fy);
      final w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy;
      final w11 = fx * fy;
      for (var c = 0; c < 3; c++) {
        final val =
            s[i00 + c] * w00 +
            s[i10 + c] * w10 +
            s[i01 + c] * w01 +
            s[i11 + c] * w11;
        o[oi++] = (val + 0.5).toInt();
      }
    }
  }
  return out;
}

/// Rectifica con anti-aliasing: si la salida es bastante más pequeña que la
/// región de origen, reduce antes la imagen fuente promediando áreas.
RgbImage warpDocument(RgbImage src, Quad quad, int outW, int outH) {
  final srcLong = math.max(
    math.max(quad.tl.distanceTo(quad.tr), quad.bl.distanceTo(quad.br)),
    math.max(quad.tl.distanceTo(quad.bl), quad.tr.distanceTo(quad.br)),
  );
  final outLong = math.max(outW, outH);
  final ratio = outLong / srcLong;
  if (ratio < 0.7) {
    final f = ratio * 1.25;
    final rw = math.max(1, (src.width * f).round());
    final rh = math.max(1, (src.height * f).round());
    final reduced = resizeArea(src, rw, rh);
    final q = quad.scale(rw / src.width, rh / src.height);
    return warpPerspective(reduced, q, outW, outH);
  }
  return warpPerspective(src, quad, outW, outH);
}
