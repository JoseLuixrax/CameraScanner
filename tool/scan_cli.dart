// Herramienta de línea de comandos para probar el motor de escaneo sin móvil.
//
//   dart run tool/scan_cli.dart <entrada.jpg> [carpeta_salida]
//
// Genera en la carpeta de salida:
//   <nombre>_detect.jpg   foto con el cuadrilátero detectado dibujado
//   <nombre>_<filtro>.jpg resultado recortado con cada filtro
import 'dart:io';

import 'package:camera_scanner/processing/codec.dart';
import 'package:camera_scanner/processing/document_detector.dart';
import 'package:camera_scanner/processing/enhance.dart';
import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:camera_scanner/processing/pipeline.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Uso: dart run tool/scan_cli.dart <imagen> [salida]');
    exit(64);
  }
  final input = File(args[0]);
  final outDir = Directory(args.length > 1 ? args[1] : 'scan_out')
    ..createSync(recursive: true);
  final name = input.uri.pathSegments.last.split('.').first;

  final sw = Stopwatch()..start();
  final rgb = decodeToRgb(input.readAsBytesSync());
  if (rgb == null) {
    stderr.writeln('Formato no soportado');
    exit(1);
  }
  final tDecode = sw.elapsedMilliseconds;
  final det = const DocumentDetector().detect(rgb);
  final tDetect = sw.elapsedMilliseconds - tDecode;
  stdout.writeln(
    '$name ${rgb.width}x${rgb.height} '
    'decode=${tDecode}ms detect=${tDetect}ms -> $det',
  );

  final quad =
      det?.quad ?? Quad.rect(rgb.width.toDouble(), rgb.height.toDouble());
  File('${outDir.path}/${name}_detect.jpg')
      .writeAsBytesSync(encodeJpeg(_drawQuad(rgb, quad), quality: 80));

  final norm = quad.scale(1 / rgb.width, 1 / rgb.height);
  sw.reset();
  final warped = warpRgb(rgb, norm);
  stdout.writeln(
    '  warp ${warped.width}x${warped.height} '
    '${sw.elapsedMilliseconds}ms',
  );
  for (final f in ScanFilter.values) {
    sw.reset();
    final out = applyFilter(warped, f);
    final t = sw.elapsedMilliseconds;
    File('${outDir.path}/${name}_${f.name}.jpg')
        .writeAsBytesSync(encodeJpeg(out, quality: 85));
    stdout.writeln('  ${f.name}: ${t}ms');
  }
}

RgbImage _drawQuad(RgbImage src, Quad q) {
  final img = src.clone();
  final pts = q.points;
  for (var i = 0; i < 4; i++) {
    final a = pts[i], b = pts[(i + 1) % 4];
    final steps = (a.distanceTo(b)).ceil();
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final x = (a.x + (b.x - a.x) * t).round();
      final y = (a.y + (b.y - a.y) * t).round();
      for (var dy = -3; dy <= 3; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= img.width || yy >= img.height) {
            continue;
          }
          final o = (yy * img.width + xx) * 3;
          img.data[o] = 0;
          img.data[o + 1] = 230;
          img.data[o + 2] = 60;
        }
      }
    }
  }
  return img;
}
