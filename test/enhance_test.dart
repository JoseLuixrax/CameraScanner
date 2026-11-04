import 'dart:math' as math;

import 'package:camera_scanner/processing/enhance.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:flutter_test/flutter_test.dart';

/// Papel con una sombra fuerte (izquierda oscura → derecha clara), un tinte
/// amarillento y líneas de texto negras.
RgbImage _shadowedPage() {
  const w = 600, h = 800;
  final img = RgbImage(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final light = 0.45 + 0.55 * x / w;
      final isText = (y % 40) < 10 && (x % 70) < 55 && y > 60 && y < 740;
      final base = isText ? [35.0, 35.0, 35.0] : [245.0, 235.0, 205.0];
      final o = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        img.data[o + c] = (base[c] * light).round();
      }
    }
  }
  return img;
}

({double mean, double std}) _paperStats(RgbImage img) {
  var sum = 0.0, sq = 0.0, n = 0;
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final isText = (y % 40) < 14 && y > 50 && y < 750;
      if (isText) continue;
      final o = (y * img.width + x) * 3;
      final v = (img.data[o] + img.data[o + 1] + img.data[o + 2]) / 3;
      sum += v;
      sq += v * v;
      n++;
    }
  }
  final mean = sum / n;
  return (mean: mean, std: math.sqrt(sq / n - mean * mean));
}

double _textMean(RgbImage img) {
  var sum = 0.0, n = 0;
  for (var y = 100; y < 700; y++) {
    if (y % 40 < 2 || y % 40 > 8) continue;
    for (var x = 0; x < img.width; x++) {
      if (x % 70 < 3 || x % 70 > 52) continue;
      final o = (y * img.width + x) * 3;
      sum += (img.data[o] + img.data[o + 1] + img.data[o + 2]) / 3;
      n++;
    }
  }
  return sum / n;
}

void main() {
  final page = _shadowedPage();
  final before = _paperStats(page);

  for (final f in [
    ScanFilter.magicColor,
    ScanFilter.grayscale,
    ScanFilter.blackWhite,
  ]) {
    test('${f.name}: elimina la sombra y blanquea el papel', () {
      final out = applyFilter(page, f);
      final after = _paperStats(out);
      expect(before.std, greaterThan(30)); // la sombra es fuerte
      expect(after.mean, greaterThan(245));
      expect(after.std, lessThan(8));
      expect(_textMean(out), lessThan(70)); // el texto sigue siendo oscuro
    });
  }

  test('magicColor neutraliza el tinte amarillo del papel', () {
    final out = applyFilter(page, ScanFilter.magicColor);
    final o = (400 * out.width + 590) * 3; // zona de papel
    final r = out.data[o], g = out.data[o + 1], b = out.data[o + 2];
    expect((r - b).abs(), lessThan(12));
    expect((r - g).abs(), lessThan(12));
  });

  test('blackWhite produce sólo blanco o negro', () {
    final out = applyFilter(page, ScanFilter.blackWhite);
    for (final v in out.data) {
      expect(v == 0 || v == 255, isTrue);
    }
  });

  test('magicColor conserva un recuadro de color grande', () {
    const w = 600, h = 800;
    final img = RgbImage(w, h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final box = x > 150 && x < 450 && y > 200 && y < 450;
        final c = box ? [30, 80, 170] : [240, 240, 236];
        final o = (y * w + x) * 3;
        img.data.setAll(o, c);
      }
    }
    final out = applyFilter(img, ScanFilter.magicColor);
    final o = (325 * w + 300) * 3; // centro del recuadro
    // Sigue siendo azul (no se ha "lavado" a blanco/cian).
    expect(out.data[o + 2], greaterThan(out.data[o] + 80));
    expect(out.data[o], lessThan(90));
  });

  test('original no modifica la imagen', () {
    expect(identical(applyFilter(page, ScanFilter.original), page), isTrue);
  });
}
