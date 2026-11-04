import 'dart:math' as math;

import 'package:camera_scanner/processing/document_detector.dart';
import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/synthetic.dart';

void main() {
  const detector = DocumentDetector();

  test('documento en perspectiva sobre madera', () {
    const truth = Quad(
      Pt(180, 200),
      Pt(820, 240),
      Pt(880, 1130),
      Pt(110, 1170),
    );
    final img = syntheticPhoto(width: 1000, height: 1333, corners: truth);
    final r = detector.detect(img)!;
    expect(maxCornerError(r.quad, truth), lessThan(6));
    expect(r.confidence, greaterThan(0.6));
  });

  test('bajo contraste (papel sobre mesa gris clara) con sombra', () {
    const truth = Quad(
      Pt(150, 160),
      Pt(860, 140),
      Pt(880, 1180),
      Pt(120, 1200),
    );
    final img = syntheticPhoto(
      width: 1000,
      height: 1333,
      corners: truth,
      background: const [196, 196, 200],
      shadow: 0.4,
    );
    final r = detector.detect(img)!;
    expect(maxCornerError(r.quad, truth), lessThan(6));
  });

  test('documento girado sobre fondo oscuro', () {
    final c = const Pt(500, 660);
    const hw = 330.0, hh = 466.0;
    final a = 22 * math.pi / 180;
    Pt rot(double x, double y) => Pt(
      c.x + x * math.cos(a) - y * math.sin(a),
      c.y + x * math.sin(a) + y * math.cos(a),
    );
    final truth = Quad.fromPoints(
      orderCorners([rot(-hw, -hh), rot(hw, -hh), rot(hw, hh), rot(-hw, hh)]),
    );
    final img = syntheticPhoto(
      width: 1000,
      height: 1333,
      corners: truth,
      background: const [35, 35, 38],
    );
    final r = detector.detect(img)!;
    expect(maxCornerError(r.quad, truth), lessThan(6));
  });

  test('esquina fuera del encuadre: se ajusta al borde de la foto', () {
    const truth = Quad(Pt(-60, 100), Pt(880, 170), Pt(930, 1240), Pt(80, 1270));
    final img = syntheticPhoto(width: 1000, height: 1333, corners: truth);
    final r = detector.detect(img)!;
    // TL debe quedar sobre el borde izquierdo, en la recta superior.
    final top = Line2.through(truth.tl, truth.tr);
    final expectedTl = top.intersect(
      Line2.through(const Pt(0, 0), const Pt(0, 1)),
    )!;
    expect(r.quad.tl.distanceTo(expectedTl), lessThan(8));
    expect(r.quad.tr.distanceTo(truth.tr), lessThan(6));
    expect(r.quad.br.distanceTo(truth.br), lessThan(6));
    expect(r.quad.bl.distanceTo(truth.bl), lessThan(6));
  });

  test('sin documento: devuelve null', () {
    final rnd = math.Random(3);
    final img = RgbImage(640, 480);
    for (var i = 0; i < img.data.length; i++) {
      img.data[i] = 120 + rnd.nextInt(20);
    }
    expect(detector.detect(img), isNull);
  });

  test('imagen diminuta: no falla', () {
    expect(detector.detect(RgbImage(10, 10)), isNull);
  });
}
