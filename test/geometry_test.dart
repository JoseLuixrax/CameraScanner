import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/perspective.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('orderCorners', () {
    test('ordena TL, TR, BR, BL desde cualquier orden', () {
      const tl = Pt(10, 12),
          tr = Pt(100, 8),
          br = Pt(105, 140),
          bl = Pt(5, 150);
      for (final input in [
        [br, tl, bl, tr],
        [bl, br, tr, tl],
        [tr, bl, tl, br],
      ]) {
        expect(orderCorners(input), [tl, tr, br, bl]);
      }
    });
  });

  group('Quad', () {
    test('convexidad', () {
      expect(Quad.rect(10, 10).isConvex, isTrue);
      // "Pajarita" (lados cruzados).
      const bow = Quad(Pt(0, 0), Pt(10, 10), Pt(10, 0), Pt(0, 10));
      expect(bow.isConvex, isFalse);
      // Cóncavo.
      const concave = Quad(Pt(0, 0), Pt(10, 0), Pt(3, 3), Pt(0, 10));
      expect(concave.isConvex, isFalse);
    });

    test('área y serialización', () {
      final q = Quad.rect(4, 3);
      expect(q.area, closeTo(12, 1e-9));
      expect(Quad.fromList(q.toList()).points, q.points);
    });
  });

  test('envolvente convexa descarta puntos interiores', () {
    final hull = convexHull(const [
      Pt(0, 0),
      Pt(5, 1),
      Pt(10, 0),
      Pt(9, 5),
      Pt(10, 10),
      Pt(5, 5),
      Pt(0, 10),
    ]);
    expect(hull.length, 4);
    expect(
      hull,
      containsAll(const [Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)]),
    );
  });

  test('cuadrilátero de área máxima en un polígono', () {
    // Octógono: el mayor cuadrilátero inscrito usa vértices alternos.
    final poly = const [
      Pt(3, 0),
      Pt(7, 0),
      Pt(10, 3),
      Pt(10, 7),
      Pt(7, 10),
      Pt(3, 10),
      Pt(0, 7),
      Pt(0, 3),
    ];
    final q = maxAreaQuad(poly)!;
    expect(polygonArea(q).abs(), closeTo(58, 1e-9));
  });

  test('intersección de rectas', () {
    final a = Line2.through(const Pt(0, 0), const Pt(10, 10));
    final b = Line2.through(const Pt(0, 10), const Pt(10, 0));
    final p = a.intersect(b)!;
    expect(p.x, closeTo(5, 1e-9));
    expect(p.y, closeTo(5, 1e-9));
  });

  test('homografía: ida y vuelta', () {
    const src = [Pt(0, 0), Pt(100, 0), Pt(100, 50), Pt(0, 50)];
    const dst = [Pt(12, 30), Pt(140, 10), Pt(150, 90), Pt(5, 120)];
    final h = Homography.fromPoints(src, dst)!;
    final inv = Homography.fromPoints(dst, src)!;
    for (var i = 0; i < 4; i++) {
      final p = h.apply(src[i]);
      expect(p.x, closeTo(dst[i].x, 1e-6));
      expect(p.y, closeTo(dst[i].y, 1e-6));
    }
    final mid = inv.apply(h.apply(const Pt(37, 21)));
    expect(mid.x, closeTo(37, 1e-6));
    expect(mid.y, closeTo(21, 1e-6));
  });
}
