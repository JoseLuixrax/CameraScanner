import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:camera_scanner/processing/perspective.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/synthetic.dart';

void main() {
  group('relación de aspecto real (modelo pinhole)', () {
    const w = 1500, h = 2000;
    const a4 = 297 / 210;
    final poses = <String, List<double>>{
      'inclinado 35° en X': [-35, 8, 4],
      'inclinado en Y': [10, -30, -6],
      'casi frontal': [3, -2, 1],
      'girado 20° en Z': [-20, 0, 20],
    };
    for (final e in poses.entries) {
      test('A4 vertical, ${e.key}', () {
        final q = projectRectangle(
          w: 210,
          h: 297,
          f: 1600,
          imageWidth: w,
          imageHeight: h,
          rx: e.value[0],
          ry: e.value[1],
          rz: e.value[2],
          dist: 700,
        );
        final ratio = trueAspectRatio(q, w, h)!;
        // Con el giro en Z las esquinas ya no son "arriba/abajo" puras, pero
        // la relación del rectángulo debe mantenerse.
        expect(ratio, closeTo(1 / a4, 0.02));
        final size = estimateOutputSize(q, w, h);
        expect(size.width / size.height, closeTo(1 / a4, 0.02));
      });
    }

    test('ticket estrecho (8 x 25 cm)', () {
      final q = projectRectangle(
        w: 80,
        h: 250,
        f: 1700,
        imageWidth: w,
        imageHeight: h,
        rx: -30,
        ry: 12,
        dist: 500,
      );
      expect(trueAspectRatio(q, w, h)!, closeTo(80 / 250, 0.02));
    });
  });

  test('estimateOutputSize respeta maxSide', () {
    final q = Quad.rect(4000, 3000);
    final s = estimateOutputSize(q, 4000, 3000, maxSide: 1000);
    expect(s.width, 1000);
    expect(s.height, 750);
  });

  test('warpPerspective extrae la región correcta', () {
    // Imagen 200x200: mitad izquierda roja, derecha azul.
    final src = RgbImage(200, 200);
    for (var y = 0; y < 200; y++) {
      for (var x = 0; x < 200; x++) {
        final o = (y * 200 + x) * 3;
        if (x < 100) {
          src.data[o] = 255;
        } else {
          src.data[o + 2] = 255;
        }
      }
    }
    // Recorta solo la mitad derecha → todo azul.
    final out = warpPerspective(
      src,
      const Quad(Pt(110, 10), Pt(190, 10), Pt(190, 190), Pt(110, 190)),
      40,
      90,
    );
    expect(out.width, 40);
    expect(out.height, 90);
    for (var i = 0; i < out.pixelCount; i++) {
      expect(out.data[i * 3], 0);
      expect(out.data[i * 3 + 2], 255);
    }
  });

  test('rotate90 en los cuatro sentidos', () {
    final img = RgbImage(3, 2);
    // Marca el píxel (0,0) en rojo.
    img.data[0] = 255;
    final r1 = rotate90(img, 1);
    expect([r1.width, r1.height], [2, 3]);
    expect(r1.data[(0 * 2 + 1) * 3], 255); // esquina superior derecha
    final r2 = rotate90(img, 2);
    expect(r2.data[(1 * 3 + 2) * 3], 255); // inferior derecha
    final r3 = rotate90(img, 3);
    expect(r3.data[(2 * 2 + 0) * 3], 255); // inferior izquierda
  });
}
