import 'dart:convert';
import 'dart:io';

import 'package:camera_scanner/processing/codec.dart';
import 'package:camera_scanner/processing/enhance.dart';
import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/pipeline.dart';
import 'package:camera_scanner/services/pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'helpers/synthetic.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('scanner_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pipeline completo: preparar → detectar → renderizar → PDF', () async {
    const truth = Quad(
      Pt(180, 200),
      Pt(820, 240),
      Pt(880, 1130),
      Pt(110, 1170),
    );
    final photo = syntheticPhoto(width: 1000, height: 1333, corners: truth);
    final input = '${tmp.path}/foto.jpg';
    File(input).writeAsBytesSync(encodeJpeg(photo, quality: 92));

    final info = prepareSourceFile(input, '${tmp.path}/src.jpg')!;
    expect(info.width, 1000);
    expect(info.height, 1333);
    expect(info.detected, isNotNull);
    final detectedPx = info.detected!.scale(1000, 1333);
    expect(maxCornerError(detectedPx, truth), lessThan(8));

    final pages = <PdfPageInput>[];
    for (final (i, f) in [
      ScanFilter.magicColor,
      ScanFilter.blackWhite,
    ].indexed) {
      final r = renderPage(
        RenderRequest(
          sourcePath: info.path,
          quad: info.detected!,
          filter: f,
          rotation: i, // la segunda página girada 90°
          outputPath: '${tmp.path}/page$i.jpg',
        ),
      );
      expect(File(r.path).existsSync(), isTrue);
      pages.add(PdfPageInput(r.path, r.width, r.height));
    }
    // La página girada intercambia ancho y alto.
    expect(pages[1].width, pages[0].height);

    for (final size in PdfPageSize.values) {
      final pdf = await buildPdf(pages, pageSize: size, title: 'Prueba');
      final text = latin1.decode(pdf, allowInvalid: true);
      expect(text.startsWith('%PDF-'), isTrue);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(text).length, 2);
    }
  });

  test('aplica la orientación EXIF al decodificar', () {
    // Imagen 40x20 con orientación 6 (girar 90° horario) → debe quedar 20x40.
    final im = img.Image(width: 40, height: 20);
    img.fill(im, color: img.ColorRgb8(200, 10, 10));
    im.exif.imageIfd.orientation = 6;
    final bytes = img.encodeJpg(im);
    final rgb = decodeToRgb(bytes)!;
    expect(rgb.width, 20);
    expect(rgb.height, 40);
  });

  test('limita el tamaño máximo al decodificar', () {
    final im = img.Image(width: 4000, height: 1000);
    final rgb = decodeToRgb(img.encodeJpg(im, quality: 50), maxSide: 1000)!;
    expect(rgb.width, 1000);
    expect(rgb.height, 250);
  });
}
