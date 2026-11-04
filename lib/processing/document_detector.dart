import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'image_ops.dart';

/// Resultado de la detección: esquinas en píxeles de la imagen original.
class DetectionResult {
  const DetectionResult(this.quad, this.confidence);

  final Quad quad;

  /// Puntuación aproximada entre 0 y 1 (soporte de bordes ponderado por área).
  final double confidence;

  @override
  String toString() =>
      'DetectionResult($quad, conf=${confidence.toStringAsFixed(3)})';
}

/// Detector de documentos (hojas, tickets, facturas...) en una foto.
///
/// Estrategia (todo en Dart puro, sin OpenCV):
///  1. Reduce la imagen a ~512 px y calcula gradientes (Sobel) sobre los tres
///     canales de color suavizados; en cada píxel se queda con el canal de
///     mayor contraste (así funciona también papel blanco sobre mesa clara de
///     otro tono).
///  2. Genera candidatos a cuadrilátero por tres vías complementarias:
///       * Transformada de Hough guiada por la orientación del gradiente →
///         combinaciones de 2 rectas "horizontales" + 2 "verticales".
///       * Componentes conexas de bordes Canny (varios umbrales) → envolvente
///         convexa → cuadrilátero de área máxima.
///       * Segmentación por brillo (Otsu) → igual que el anterior.
///  3. Puntúa cada candidato midiendo cuánto de su perímetro coincide con un
///     borde real con la orientación y polaridad correctas, ponderado por el
///     área.
///  4. Refina los mejores ajustando cada lado por mínimos cuadrados a los
///     píxeles de borde cercanos (precisión sub-píxel) y se queda con el mejor.
class DocumentDetector {
  const DocumentDetector({
    this.workSize = 512,
    this.minConfidence = 0.45,
    this.fast = false,
  });

  /// Modo rápido para la vista de cámara en vivo: menos candidatos (un nivel
  /// de Canny menos, menos rectas de Hough, sin segmentación oscura). Unas
  /// 2x más rápido; para la foto final se usa el modo completo.
  final bool fast;

  /// Lado mayor de la imagen de trabajo.
  final int workSize;

  /// Por debajo de esta puntuación se considera que no hay documento claro.
  final double minConfidence;

  DetectionResult? detect(RgbImage image) {
    if (image.width < 32 || image.height < 32) return null;
    final long = math.max(image.width, image.height);
    final small = long > workSize ? limitSize(image, workSize) : image;
    final sx = small.width / image.width;
    final sy = small.height / image.height;

    final analysis = _EdgeAnalysis(small, fast: fast);
    final best = analysis.findDocument();
    if (best == null || best.score < minConfidence) return null;

    final q = analysis
        .fitInside(best.quad)
        .map((p) => Pt((p.x + 0.5) / sx - 0.5, (p.y + 0.5) / sy - 0.5))
        .clampTo(image.width.toDouble(), image.height.toDouble());
    return DetectionResult(q, best.score.clamp(0.0, 1.0).toDouble());
  }
}

class _Candidate {
  _Candidate(this.quad, this.score, this.polarity);

  final Quad quad;
  final double score;
  final int polarity;
}

class _HoughLine {
  _HoughLine(this.theta, this.rho, this.votes);

  final int theta; // grados [0, 180)
  final double rho;
  final int votes;

  double get cosT => math.cos(theta * math.pi / 180);
  double get sinT => math.sin(theta * math.pi / 180);

  Line2 toLine() => Line2(cosT, sinT, rho);
}

class _EdgeAnalysis {
  _EdgeAnalysis(RgbImage img, {this.fast = false})
    : w = img.width,
      h = img.height,
      n = img.width * img.height {
    _computeGradients(img);
  }

  final int w;
  final int h;
  final int n;
  final bool fast;

  late final Float32List gx;
  late final Float32List gy;
  late final Float32List mag;
  late final Uint8List lum;

  /// Canales R, G, B suavizados.
  late final List<Float32List> planes;

  /// Magnitud mínima para considerar que un píxel pertenece a un borde.
  late final double edgeThr;

  void _computeGradients(RgbImage img) {
    planes = List.generate(
      3,
      (c) => gaussianBlur(channelPlane(img, c), w, h, 1.6),
    );
    gx = Float32List(n);
    gy = Float32List(n);
    mag = Float32List(n);
    lum = Uint8List(n);
    final r = planes[0], g = planes[1], b = planes[2];
    for (var i = 0; i < n; i++) {
      lum[i] = (0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i]).round().clamp(
        0,
        255,
      );
    }
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        var best = -1.0;
        var bx = 0.0, by = 0.0;
        for (var c = 0; c < 3; c++) {
          final p = planes[c];
          final sx =
              (p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]) -
              (p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1]);
          final sy =
              (p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]) -
              (p[i - w - 1] + 2 * p[i - w] + p[i - w + 1]);
          final m = sx * sx + sy * sy;
          if (m > best) {
            best = m;
            bx = sx;
            by = sy;
          }
        }
        gx[i] = bx;
        gy[i] = by;
        mag[i] = math.sqrt(best);
      }
    }
    // Ruido de fondo ≈ mediana de la magnitud (dominan zonas planas).
    final median = percentile(mag, 0.5);
    edgeThr = (median * 2.5).clamp(8.0, 32.0).toDouble();
  }

  // ---------------------------------------------------------------------
  // Búsqueda principal
  // ---------------------------------------------------------------------

  _Candidate? findDocument() {
    final nms = _nonMaxSuppression();
    final strong = percentile(nms, 0.5, skipZeros: true);

    final candidates = <_Candidate>[];
    void addQuad(Quad? q) {
      if (q == null) return;
      final c = _score(q);
      if (c != null) candidates.add(c);
    }

    // Varios niveles de sensibilidad para Canny. Los dos primeros dependen
    // del ruido de fondo (bordes de papel de poco contraste); el último, de
    // la intensidad típica de los bordes (útil con fondos muy texturados).
    final levels = <double>{
      edgeThr * 1.5,
      edgeThr * 3,
      if (!fast) math.max(edgeThr * 3, strong * 0.6),
    }.toList();

    Uint8List? houghEdges;
    for (var li = 0; li < levels.length; li++) {
      final high = levels[li];
      final edges = _hysteresis(nms, math.max(edgeThr, high * 0.4), high);
      if (li == 0) houghEdges = edges;
      for (final r in fast ? const [1] : const [1, 2]) {
        final dil = dilateMask(edges, w, h, r);
        for (final q in _componentQuads(dil, eight: true)) {
          addQuad(q);
        }
      }
    }

    // Hough sobre los bordes del nivel más sensible.
    if (houghEdges != null) {
      for (final q in _houghQuads(houghEdges)) {
        addQuad(q);
      }
    }

    // Segmentación por brillo (papel claro sobre fondo oscuro y viceversa).
    final t = otsuThreshold(lum);
    for (final bright in fast ? const [true] : const [true, false]) {
      final mask = Uint8List(n);
      for (var i = 0; i < n; i++) {
        mask[i] = (bright ? lum[i] > t : lum[i] <= t) ? 1 : 0;
      }
      final opened = dilateMask(erodeMask(mask, w, h, 2), w, h, 2);
      for (final q in _componentQuads(opened, eight: false)) {
        addQuad(q);
      }
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));

    // Refina los mejores y vuelve a puntuar.
    _Candidate? best;
    final seen = <Quad>[];
    for (final c in candidates.take(fast ? 6 : 12)) {
      if (seen.any((s) => _quadDistance(s, c.quad) < 3)) continue;
      seen.add(c.quad);
      var cur = c;
      for (var iter = 0; iter < 2; iter++) {
        final refined = _refine(cur.quad, cur.polarity);
        if (refined == null) break;
        final rc = _score(refined);
        if (rc == null || rc.score < cur.score - 0.02) break;
        cur = rc;
      }
      if (best == null || cur.score > best.score) best = cur;
      if (seen.length >= (fast ? 3 : 6)) break;
    }
    return best;
  }

  double _quadDistance(Quad a, Quad b) {
    final pa = a.points, pb = b.points;
    var m = 0.0;
    for (var i = 0; i < 4; i++) {
      m = math.max(m, pa[i].distanceTo(pb[i]));
    }
    return m;
  }

  // ---------------------------------------------------------------------
  // Canny
  // ---------------------------------------------------------------------

  Float32List _nonMaxSuppression() {
    final out = Float32List(n);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final m = mag[i];
        if (m < edgeThr) continue;
        final ax = gx[i].abs();
        final ay = gy[i].abs();
        double a, b;
        if (ay <= ax * 0.4142) {
          a = mag[i - 1];
          b = mag[i + 1];
        } else if (ay >= ax * 2.4142) {
          a = mag[i - w];
          b = mag[i + w];
        } else if (gx[i] * gy[i] > 0) {
          a = mag[i - w - 1];
          b = mag[i + w + 1];
        } else {
          a = mag[i - w + 1];
          b = mag[i + w - 1];
        }
        if (m >= a && m > b) out[i] = m;
      }
    }
    return out;
  }

  Uint8List _hysteresis(Float32List nms, double low, double high) {
    final out = Uint8List(n);
    final stack = Int32List(n);
    for (var i = 0; i < n; i++) {
      if (out[i] != 0 || nms[i] < high) continue;
      var sp = 0;
      out[i] = 1;
      stack[sp++] = i;
      while (sp > 0) {
        final j = stack[--sp];
        final x = j % w;
        final y = j ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            final k = yy * w + xx;
            if (out[k] == 0 && nms[k] >= low) {
              out[k] = 1;
              stack[sp++] = k;
            }
          }
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Candidatos por componentes conexas
  // ---------------------------------------------------------------------

  List<Quad> _componentQuads(Uint8List mask, {required bool eight}) {
    final labels = Int32List(n);
    final queue = Int32List(n);
    final rowMin = Int32List(h);
    final rowMax = Int32List(h);
    final quads = <Quad>[];
    var label = 0;
    final minW = w * 0.2;
    final minH = h * 0.2;

    for (var start = 0; start < n; start++) {
      if (mask[start] == 0 || labels[start] != 0) continue;
      label++;
      var head = 0, tail = 0;
      queue[tail++] = start;
      labels[start] = label;
      var minX = w, maxX = 0, minY = h, maxY = 0;
      while (head < tail) {
        final j = queue[head++];
        final x = j % w;
        final y = j ~/ w;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (!eight && dx != 0 && dy != 0) continue;
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            final k = yy * w + xx;
            if (mask[k] != 0 && labels[k] == 0) {
              labels[k] = label;
              queue[tail++] = k;
            }
          }
        }
      }
      if (maxX - minX < minW || maxY - minY < minH) continue;

      // Extremos por fila → envolvente convexa.
      for (var y = minY; y <= maxY; y++) {
        rowMin[y] = w;
        rowMax[y] = -1;
      }
      for (var q = 0; q < tail; q++) {
        final j = queue[q];
        final x = j % w;
        final y = j ~/ w;
        if (x < rowMin[y]) rowMin[y] = x;
        if (x > rowMax[y]) rowMax[y] = x;
      }
      final pts = <Pt>[];
      for (var y = minY; y <= maxY; y++) {
        if (rowMax[y] < 0) continue;
        pts.add(Pt(rowMin[y].toDouble(), y.toDouble()));
        if (rowMax[y] != rowMin[y]) {
          pts.add(Pt(rowMax[y].toDouble(), y.toDouble()));
        }
      }
      final q = _quadFromPoints(pts);
      if (q != null) quads.add(q);
    }
    return quads;
  }

  Quad? _quadFromPoints(List<Pt> pts) {
    if (pts.length < 4) return null;
    final hull = convexHull(pts);
    if (hull.length < 4) return null;
    if (polygonArea(hull).abs() < 0.08 * w * h) return null;
    var perim = 0.0;
    for (var i = 0; i < hull.length; i++) {
      perim += hull[i].distanceTo(hull[(i + 1) % hull.length]);
    }
    var eps = perim * 0.005;
    var simple = simplifyClosedPolygon(hull, eps);
    while (simple.length > 14) {
      eps *= 1.5;
      simple = simplifyClosedPolygon(hull, eps);
    }
    final quad = maxAreaQuad(simple);
    if (quad == null) return null;
    return Quad.fromPoints(orderCorners(quad));
  }

  // ---------------------------------------------------------------------
  // Candidatos por Hough
  // ---------------------------------------------------------------------

  List<Quad> _houghQuads(Uint8List edges) {
    final diag = math.sqrt(w * w + h * h).ceil();
    final nRho = 2 * diag + 1;
    const nTheta = 180;
    final cosT = Float64List(nTheta);
    final sinT = Float64List(nTheta);
    for (var t = 0; t < nTheta; t++) {
      cosT[t] = math.cos(t * math.pi / 180);
      sinT[t] = math.sin(t * math.pi / 180);
    }
    final acc = Int32List(nTheta * nRho);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        if (edges[i] == 0) continue;
        var deg = math.atan2(gy[i], gx[i]) * 180 / math.pi;
        if (deg < 0) deg += 180;
        final base = deg.round();
        for (var dt = -5; dt <= 5; dt++) {
          final t = (base + dt) % nTheta;
          final rho = x * cosT[t] + y * sinT[t];
          acc[t * nRho + (rho + diag).round()]++;
        }
      }
    }

    final minVotes = math.max(15, (0.12 * math.min(w, h)).round());
    final peaks = <_HoughLine>[];
    for (var t = 0; t < nTheta; t++) {
      for (var r = 0; r < nRho; r++) {
        final v = acc[t * nRho + r];
        if (v < minVotes) continue;
        var isMax = true;
        for (var dt = -2; dt <= 2 && isMax; dt++) {
          final tt = (t + dt + nTheta) % nTheta;
          for (var dr = -3; dr <= 3; dr++) {
            if (dt == 0 && dr == 0) continue;
            final rr = r + dr;
            if (rr < 0 || rr >= nRho) continue;
            final o = acc[tt * nRho + rr];
            if (o > v || (o == v && (dt < 0 || (dt == 0 && dr < 0)))) {
              isMax = false;
              break;
            }
          }
        }
        if (isMax) peaks.add(_HoughLine(t, (r - diag).toDouble(), v));
      }
    }
    peaks.sort((a, b) => b.votes.compareTo(a.votes));

    final maxLines = fast ? 6 : 8;
    final horiz = <_HoughLine>[];
    final vert = <_HoughLine>[];
    bool similar(_HoughLine a, _HoughLine b) {
      var dt = (a.theta - b.theta).abs();
      var dr = (a.rho - b.rho).abs();
      if (dt > 90) {
        dt = 180 - dt;
        dr = (a.rho + b.rho).abs();
      }
      return dt <= 4 && dr <= 8;
    }

    for (final p in peaks) {
      final isHoriz = p.theta >= 45 && p.theta < 135;
      final list = isHoriz ? horiz : vert;
      if (list.length >= maxLines) continue;
      if (list.any((o) => similar(o, p))) continue;
      list.add(p);
      if (horiz.length >= maxLines && vert.length >= maxLines) break;
    }

    final quads = <Quad>[];
    final cx = w / 2, cy = h / 2;
    for (var a = 0; a < horiz.length; a++) {
      for (var b = a + 1; b < horiz.length; b++) {
        var top = horiz[a], bottom = horiz[b];
        final ya = (top.rho - cx * top.cosT) / top.sinT;
        final yb = (bottom.rho - cx * bottom.cosT) / bottom.sinT;
        if ((ya - yb).abs() < 0.15 * h) continue;
        if (ya > yb) {
          final tmp = top;
          top = bottom;
          bottom = tmp;
        }
        for (var c = 0; c < vert.length; c++) {
          for (var d = c + 1; d < vert.length; d++) {
            var left = vert[c], right = vert[d];
            final xc = (left.rho - cy * left.sinT) / left.cosT;
            final xd = (right.rho - cy * right.sinT) / right.cosT;
            if ((xc - xd).abs() < 0.15 * w) continue;
            if (xc > xd) {
              final tmp = left;
              left = right;
              right = tmp;
            }
            final lt = top.toLine(), lb = bottom.toLine();
            final ll = left.toLine(), lr = right.toLine();
            final ptl = lt.intersect(ll);
            final ptr = lt.intersect(lr);
            final pbr = lb.intersect(lr);
            final pbl = lb.intersect(ll);
            if (ptl == null || ptr == null || pbr == null || pbl == null) {
              continue;
            }
            final pts = [ptl, ptr, pbr, pbl];
            // Se permiten esquinas fuera de la foto (documento cortado); al
            // final se ajustan al encuadre con [fitInside].
            final margin = _outsideMargin;
            if (pts.any(
              (p) =>
                  p.x < -margin ||
                  p.y < -margin ||
                  p.x > w - 1 + margin ||
                  p.y > h - 1 + margin,
            )) {
              continue;
            }
            quads.add(Quad.fromPoints(pts));
          }
        }
      }
    }
    return quads;
  }

  // ---------------------------------------------------------------------
  // Puntuación
  // ---------------------------------------------------------------------

  bool _onBorder(Pt a, Pt b) {
    const m = 3.0;
    final r = w - 1 - m, bt = h - 1 - m;
    return (a.x <= m && b.x <= m) ||
        (a.y <= m && b.y <= m) ||
        (a.x >= r && b.x >= r) ||
        (a.y >= bt && b.y >= bt);
  }

  double get _outsideMargin => 0.25 * math.max(w, h);

  /// Soporte del lado [a]→[b]: fracción de muestras visibles que caen sobre un
  /// borde con la orientación esperada. [polarity] = +1 si el interior es más
  /// claro. Devuelve también qué fracción del lado está dentro de la foto.
  ({double support, double visible, double strength}) _sideSupport(
    Pt a,
    Pt b,
    int polarity,
  ) {
    final d = b - a;
    final len = d.length;
    if (len < 2) return (support: 0, visible: 0, strength: 0);
    // Normal hacia el interior (orden TL→TR→BR→BL con Y hacia abajo).
    final nx = -d.y / len * polarity;
    final ny = d.x / len * polarity;
    final samples = math.max(10, (len / 1.5).round());
    var ok = 0, total = 0;
    var strength = 0.0;
    for (var s = 0; s < samples; s++) {
      final t = 0.04 + 0.92 * s / (samples - 1);
      final px = a.x + d.x * t;
      final py = a.y + d.y * t;
      if (px < 1 || py < 1 || px > w - 2 || py > h - 2) continue;
      total++;
      var best = 0.0;
      for (var o = -2; o <= 2; o++) {
        final xi = (px + nx * o).round();
        final yi = (py + ny * o).round();
        if (xi < 1 || yi < 1 || xi >= w - 1 || yi >= h - 1) continue;
        final i = yi * w + xi;
        final m = mag[i];
        if (m < edgeThr) continue;
        final proj = gx[i] * nx + gy[i] * ny;
        if (proj >= 0.8 * m && proj > best) best = proj;
      }
      if (best > 0) {
        ok++;
        strength += best;
      }
    }
    return (
      support: total == 0 ? 0 : ok / total,
      visible: total / samples,
      strength: ok == 0 ? 0 : strength / ok,
    );
  }

  /// Contraste de región a ambos lados del lado [a]→[b]: compara el color
  /// medio de franjas anchas (3–12 px) dentro y fuera, por tramos. Distingue
  /// el borde real del papel (papel vs. mesa) de una línea de texto (texto y
  /// papel a ambos lados → medias parecidas).
  double _sideContrast(Pt a, Pt b) {
    final d = b - a;
    final len = d.length;
    final nx = -d.y / len, ny = d.x / len;
    const segments = 6;
    const depths = [3.0, 6.0, 9.0, 12.0];
    final pr = planes[0], pg = planes[1], pb = planes[2];
    var good = 0, total = 0;
    for (var s = 0; s < segments; s++) {
      final t0 = 0.05 + 0.9 * s / segments;
      final t1 = 0.05 + 0.9 * (s + 1) / segments;
      final steps = math.max(3, ((t1 - t0) * len / 3).round());
      var ir = 0.0, ig = 0.0, ib = 0.0, or = 0.0, og = 0.0, ob = 0.0;
      var cnt = 0;
      for (var k = 0; k < steps; k++) {
        final t = t0 + (t1 - t0) * (k + 0.5) / steps;
        final px = a.x + d.x * t, py = a.y + d.y * t;
        for (final dep in depths) {
          final xi = (px + nx * dep).round(), yi = (py + ny * dep).round();
          final xo = (px - nx * dep).round(), yo = (py - ny * dep).round();
          if (xi < 0 || yi < 0 || xi >= w || yi >= h) continue;
          if (xo < 0 || yo < 0 || xo >= w || yo >= h) continue;
          final ii = yi * w + xi, io = yo * w + xo;
          ir += pr[ii];
          ig += pg[ii];
          ib += pb[ii];
          or += pr[io];
          og += pg[io];
          ob += pb[io];
          cnt++;
        }
      }
      if (cnt < 4) continue;
      total++;
      final dr = (ir - or) / cnt, dg = (ig - og) / cnt, db = (ib - ob) / cnt;
      if (math.sqrt(dr * dr + dg * dg + db * db) > 15) good++;
    }
    return total == 0 ? 0.5 : good / total;
  }

  _Candidate? _score(Quad q) {
    if (!q.isConvex) return null;
    final areaRatio = math.min(1.0, q.area / (w * h));
    if (areaRatio < 0.08) return null;
    final minSide = 0.12 * math.min(w, h);
    final pts = q.points;
    for (var i = 0; i < 4; i++) {
      if (pts[i].distanceTo(pts[(i + 1) % 4]) < minSide) return null;
    }
    for (final a in q.interiorAngles) {
      if (a < 35 || a > 145) return null;
    }

    // El contraste de región no depende de la polaridad.
    final contrast = List<double?>.filled(4, null);

    double bestScore = -1;
    var bestPol = 1;
    for (final pol in const [1, -1]) {
      var sum = 0.0;
      var minS = 1.0;
      var real = 0;
      var sharp = 0.0;
      for (var i = 0; i < 4; i++) {
        final a = pts[i], b = pts[(i + 1) % 4];
        double s;
        if (_onBorder(a, b)) {
          s = 0.5; // lado pegado al borde de la foto: documento cortado.
        } else {
          final sup = _sideSupport(a, b, pol);
          if (sup.visible < 0.3) {
            s = 0.5; // lado casi entero fuera de la foto.
          } else {
            final c = contrast[i] ??= _sideContrast(a, b);
            s = sup.support * (0.25 + 0.75 * c);
            sharp += math.min(1.0, sup.strength / (6 * edgeThr));
            real++;
          }
        }
        sum += s;
        minS = math.min(minS, s);
      }
      if (real < 2) continue;
      final mean = sum / 4;
      // Penaliza lados sin apenas soporte.
      final support = minS < 0.2 ? mean * 0.6 : mean;
      var score = support * (0.7 + 0.3 * math.sqrt(areaRatio));
      // Bordes nítidos (papel) frente a difusos (sombra proyectada, reflejos).
      score *= 0.85 + 0.15 * (sharp / real);
      // Lo normal es papel más claro que el fondo.
      if (pol < 0) score *= 0.94;
      if (score > bestScore) {
        bestScore = score;
        bestPol = pol;
      }
    }
    if (bestScore < 0) return null;
    return _Candidate(q, bestScore, bestPol);
  }

  /// Ajusta al encuadre las esquinas que quedan fuera de la foto deslizándolas
  /// por uno de sus lados hasta el borde (el que conserva más área).
  Quad fitInside(Quad q) {
    final maxX = (w - 1).toDouble(), maxY = (h - 1).toDouble();
    bool inside(Pt p) =>
        p.x >= -1e-6 &&
        p.y >= -1e-6 &&
        p.x <= maxX + 1e-6 &&
        p.y <= maxY + 1e-6;
    final pts = q.points;
    if (pts.every(inside)) return q;

    // Punto donde el segmento p0 (dentro) → p1 (fuera) sale del rectángulo.
    Pt exitPoint(Pt p0, Pt p1) {
      final dx = p1.x - p0.x, dy = p1.y - p0.y;
      var t = 1.0;
      if (dx < 0) t = math.min(t, (0 - p0.x) / dx);
      if (dx > 0) t = math.min(t, (maxX - p0.x) / dx);
      if (dy < 0) t = math.min(t, (0 - p0.y) / dy);
      if (dy > 0) t = math.min(t, (maxY - p0.y) / dy);
      return Pt(p0.x + dx * t, p0.y + dy * t);
    }

    final out = [...pts];
    for (var i = 0; i < 4; i++) {
      if (inside(pts[i])) continue;
      final prev = pts[(i + 3) % 4], next = pts[(i + 1) % 4];
      final options = <Pt>[
        if (inside(prev)) exitPoint(prev, pts[i]),
        if (inside(next)) exitPoint(next, pts[i]),
      ];
      if (options.isEmpty) {
        out[i] = Pt(pts[i].x.clamp(0.0, maxX), pts[i].y.clamp(0.0, maxY));
        continue;
      }
      var best = options.first;
      var bestArea = -1.0;
      for (final o in options) {
        final cand = [...out]..[i] = o;
        final a = polygonArea(cand).abs();
        if (a > bestArea) {
          bestArea = a;
          best = o;
        }
      }
      out[i] = best;
    }
    final fitted = Quad.fromPoints(out);
    return fitted.isConvex ? fitted : q.clampTo(maxX, maxY);
  }

  // ---------------------------------------------------------------------
  // Refinamiento sub-píxel
  // ---------------------------------------------------------------------

  Quad? _refine(Quad q, int polarity) {
    final pts = q.points;
    final lines = <Line2>[];
    for (var s = 0; s < 4; s++) {
      final a = pts[s], b = pts[(s + 1) % 4];
      final orig = Line2.through(a, b);
      if (_onBorder(a, b)) {
        lines.add(orig);
        continue;
      }
      final d = b - a;
      final len = d.length;
      final dirX = d.x / len, dirY = d.y / len;
      final nx = -dirY * polarity, ny = dirX * polarity;
      const band = 3.5;
      final x0 = math.max(1, (math.min(a.x, b.x) - band).floor());
      final x1 = math.min(w - 2, (math.max(a.x, b.x) + band).ceil());
      final y0 = math.max(1, (math.min(a.y, b.y) - band).floor());
      final y1 = math.min(h - 2, (math.max(a.y, b.y) + band).ceil());
      var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
      var count = 0;
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          final vx = x - a.x, vy = y - a.y;
          final t = (vx * dirX + vy * dirY) / len;
          if (t < 0.1 || t > 0.9) continue;
          final dist = vx * -dirY + vy * dirX;
          if (dist.abs() > band) continue;
          final i = y * w + x;
          final m = mag[i];
          if (m < edgeThr) continue;
          final proj = gx[i] * nx + gy[i] * ny;
          if (proj < 0.8 * m) continue;
          final wt = proj;
          sw += wt;
          sx += wt * x;
          sy += wt * y;
          sxx += wt * x * x;
          syy += wt * y * y;
          sxy += wt * x * y;
          count++;
        }
      }
      if (count < 0.3 * len || sw <= 0) {
        lines.add(orig);
        continue;
      }
      final mx = sx / sw, my = sy / sw;
      final cxx = sxx / sw - mx * mx;
      final cyy = syy / sw - my * my;
      final cxy = sxy / sw - mx * my;
      // Dirección principal (autovector del mayor autovalor).
      final angle = 0.5 * math.atan2(2 * cxy, cxx - cyy);
      var ex = math.cos(angle), ey = math.sin(angle);
      if (ex * dirX + ey * dirY < 0) {
        ex = -ex;
        ey = -ey;
      }
      // Evita giros bruscos respecto al lado original.
      if (ex * dirX + ey * dirY < math.cos(8 * math.pi / 180)) {
        lines.add(orig);
        continue;
      }
      lines.add(Line2.pointDir(Pt(mx, my), Pt(ex, ey)));
    }
    final corners = <Pt>[];
    for (var i = 0; i < 4; i++) {
      final p = lines[(i + 3) % 4].intersect(lines[i]);
      if (p == null) return null;
      corners.add(p);
    }
    final refined = Quad.fromPoints(corners);
    if (!refined.isConvex) return null;
    final maxMove = math.max(4.0, 0.05 * math.sqrt(w * w + h * h));
    for (var i = 0; i < 4; i++) {
      if (corners[i].distanceTo(pts[i]) > maxMove) return null;
    }
    final m = _outsideMargin;
    if (corners.any(
      (p) => p.x < -m || p.y < -m || p.x > w - 1 + m || p.y > h - 1 + m,
    )) {
      return null;
    }
    return refined;
  }
}
