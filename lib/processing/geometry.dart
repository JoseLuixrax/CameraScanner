import 'dart:math' as math;

/// Punto 2D en coordenadas de imagen (x hacia la derecha, y hacia abajo).
class Pt {
  const Pt(this.x, this.y);

  final double x;
  final double y;

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double s) => Pt(x * s, y * s);

  double dot(Pt o) => x * o.x + y * o.y;
  double cross(Pt o) => x * o.y - y * o.x;
  double get length => math.sqrt(x * x + y * y);
  double distanceTo(Pt o) => (this - o).length;

  @override
  bool operator ==(Object other) => other is Pt && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Pt(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Cuadrilátero con las esquinas en orden: superior-izquierda, superior-derecha,
/// inferior-derecha, inferior-izquierda (sentido horario en pantalla).
class Quad {
  const Quad(this.tl, this.tr, this.br, this.bl);

  factory Quad.fromPoints(List<Pt> p) {
    assert(p.length == 4);
    return Quad(p[0], p[1], p[2], p[3]);
  }

  /// Rectángulo completo `[0, w] x [0, h]`.
  factory Quad.rect(double w, double h) =>
      Quad(const Pt(0, 0), Pt(w, 0), Pt(w, h), Pt(0, h));

  /// Lista plana `[x0, y0, x1, y1, ...]` (útil para serializar / isolates).
  factory Quad.fromList(List<double> v) {
    assert(v.length == 8);
    return Quad(Pt(v[0], v[1]), Pt(v[2], v[3]), Pt(v[4], v[5]), Pt(v[6], v[7]));
  }

  final Pt tl;
  final Pt tr;
  final Pt br;
  final Pt bl;

  List<Pt> get points => [tl, tr, br, bl];

  List<double> toList() => [tl.x, tl.y, tr.x, tr.y, br.x, br.y, bl.x, bl.y];

  Quad map(Pt Function(Pt p) f) => Quad(f(tl), f(tr), f(br), f(bl));

  Quad scale(double sx, double sy) => map((p) => Pt(p.x * sx, p.y * sy));

  /// Recorta las esquinas al rectángulo `[0, w] x [0, h]`.
  Quad clampTo(double w, double h) => map(
    (p) => Pt(p.x.clamp(0.0, w).toDouble(), p.y.clamp(0.0, h).toDouble()),
  );

  Quad withCorner(int index, Pt p) {
    final pts = points;
    pts[index] = p;
    return Quad.fromPoints(pts);
  }

  double get area => polygonArea(points).abs();

  double get perimeter {
    final p = points;
    var s = 0.0;
    for (var i = 0; i < 4; i++) {
      s += p[i].distanceTo(p[(i + 1) % 4]);
    }
    return s;
  }

  /// `true` si el cuadrilátero es convexo y no degenerado.
  bool get isConvex {
    final p = points;
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = p[i];
      final b = p[(i + 1) % 4];
      final c = p[(i + 2) % 4];
      final z = (b - a).cross(c - b);
      if (z.abs() < 1e-9) return false;
      final s = z > 0 ? 1 : -1;
      if (sign == 0) {
        sign = s;
      } else if (s != sign) {
        return false;
      }
    }
    return true;
  }

  /// Ángulos interiores en grados.
  List<double> get interiorAngles {
    final p = points;
    final out = <double>[];
    for (var i = 0; i < 4; i++) {
      final prev = p[(i + 3) % 4];
      final cur = p[i];
      final next = p[(i + 1) % 4];
      final a = prev - cur;
      final b = next - cur;
      final cosA = a.dot(b) / (a.length * b.length + 1e-12);
      out.add(math.acos(cosA.clamp(-1.0, 1.0)) * 180 / math.pi);
    }
    return out;
  }

  @override
  String toString() => 'Quad($tl, $tr, $br, $bl)';
}

/// Área con signo (fórmula del lazo). Positiva para orden TL→TR→BR→BL con
/// el eje Y hacia abajo.
double polygonArea(List<Pt> p) {
  var s = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i];
    final b = p[(i + 1) % p.length];
    s += a.x * b.y - b.x * a.y;
  }
  return s / 2;
}

/// Ordena 4 puntos como TL, TR, BR, BL.
List<Pt> orderCorners(List<Pt> pts) {
  assert(pts.length == 4);
  final cx = pts.fold<double>(0, (s, p) => s + p.x) / 4;
  final cy = pts.fold<double>(0, (s, p) => s + p.y) / 4;
  final sorted = [...pts]
    ..sort(
      (a, b) => math
          .atan2(a.y - cy, a.x - cx)
          .compareTo(math.atan2(b.y - cy, b.x - cx)),
    );
  // Con Y hacia abajo, ángulo creciente = sentido horario en pantalla.
  var start = 0;
  var best = double.infinity;
  for (var i = 0; i < 4; i++) {
    final s = sorted[i].x + sorted[i].y;
    if (s < best) {
      best = s;
      start = i;
    }
  }
  return List.generate(4, (i) => sorted[(start + i) % 4]);
}

/// Envolvente convexa (cadena monótona de Andrew).
List<Pt> convexHull(List<Pt> points) {
  if (points.length < 3) return [...points];
  final p = [...points]
    ..sort((a, b) {
      final c = a.x.compareTo(b.x);
      return c != 0 ? c : a.y.compareTo(b.y);
    });
  double cross(Pt o, Pt a, Pt b) => (a - o).cross(b - o);
  final lower = <Pt>[];
  for (final pt in p) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, pt) <= 0) {
      lower.removeLast();
    }
    lower.add(pt);
  }
  final upper = <Pt>[];
  for (final pt in p.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, pt) <= 0) {
      upper.removeLast();
    }
    upper.add(pt);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Simplificación Douglas-Peucker de un polígono cerrado.
List<Pt> simplifyClosedPolygon(List<Pt> poly, double epsilon) {
  if (poly.length <= 4) return [...poly];
  // Partimos el polígono por el punto 0 y su punto más lejano.
  var far = 0;
  var farD = -1.0;
  for (var i = 1; i < poly.length; i++) {
    final d = poly[0].distanceTo(poly[i]);
    if (d > farD) {
      farD = d;
      far = i;
    }
  }
  final a = _douglasPeucker(poly.sublist(0, far + 1), epsilon);
  final b = _douglasPeucker([...poly.sublist(far), poly[0]], epsilon);
  return [...a.sublist(0, a.length - 1), ...b.sublist(0, b.length - 1)];
}

List<Pt> _douglasPeucker(List<Pt> pts, double eps) {
  if (pts.length < 3) return pts;
  final a = pts.first;
  final b = pts.last;
  final ab = b - a;
  final len = ab.length;
  var idx = -1;
  var maxD = 0.0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = len < 1e-9
        ? pts[i].distanceTo(a)
        : (ab.cross(pts[i] - a)).abs() / len;
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD <= eps || idx < 0) return [a, b];
  final left = _douglasPeucker(pts.sublist(0, idx + 1), eps);
  final right = _douglasPeucker(pts.sublist(idx), eps);
  return [...left.sublist(0, left.length - 1), ...right];
}

/// Cuadrilátero de área máxima con vértices en un polígono convexo ordenado.
/// Pensado para polígonos pequeños (ya simplificados).
List<Pt>? maxAreaQuad(List<Pt> poly) {
  final n = poly.length;
  if (n < 4) return null;
  if (n == 4) return [...poly];
  var best = -1.0;
  List<Pt>? bestQ;
  for (var i = 0; i < n - 3; i++) {
    for (var j = i + 1; j < n - 2; j++) {
      for (var k = j + 1; k < n - 1; k++) {
        for (var l = k + 1; l < n; l++) {
          final q = [poly[i], poly[j], poly[k], poly[l]];
          final a = polygonArea(q).abs();
          if (a > best) {
            best = a;
            bestQ = q;
          }
        }
      }
    }
  }
  return bestQ;
}

/// Recta en forma implícita `a*x + b*y = c`, con (a, b) unitario.
class Line2 {
  const Line2(this.a, this.b, this.c);

  factory Line2.through(Pt p, Pt q) {
    final d = q - p;
    final len = d.length;
    final a = -d.y / len;
    final b = d.x / len;
    return Line2(a, b, a * p.x + b * p.y);
  }

  /// Recta que pasa por [p] con dirección [dir].
  factory Line2.pointDir(Pt p, Pt dir) => Line2.through(p, p + dir);

  final double a;
  final double b;
  final double c;

  Pt? intersect(Line2 o) {
    final det = a * o.b - b * o.a;
    if (det.abs() < 1e-9) return null;
    return Pt((c * o.b - b * o.c) / det, (a * o.c - c * o.a) / det);
  }

  double distance(Pt p) => (a * p.x + b * p.y - c).abs();
}
