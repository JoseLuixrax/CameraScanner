// Genera capturas de pantalla de la app en docs/screenshots/.
//
//   flutter test --update-goldens tool/screenshots/screenshots_test.dart
//
// Renderiza las pantallas reales con fuentes Roboto/Material Icons del SDK y
// datos generados con el propio motor de escaneo a partir de docs/samples/.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:camera_scanner/main.dart';
import 'package:camera_scanner/models/ocr_line.dart';
import 'package:camera_scanner/models/scan_page.dart';
import 'package:camera_scanner/processing/enhance.dart';
import 'package:camera_scanner/processing/pipeline.dart';
import 'package:camera_scanner/screens/camera_screen.dart';
import 'package:camera_scanner/screens/crop_screen.dart';
import 'package:camera_scanner/screens/filter_screen.dart';
import 'package:camera_scanner/screens/scan_session_screen.dart';
import 'package:camera_scanner/services/document_repository.dart';
import 'package:camera_scanner/services/pdf_service.dart';
import 'package:camera_scanner/services/image_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _flutterRoot =
    Platform.environment['FLUTTER_ROOT'] ??
    File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('$_flutterRoot/bin/cache/artifacts/material_fonts/$f')
        .readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// Deja avanzar el trabajo asíncrono real (E/S, isolates) y precarga las
/// imágenes visibles para que aparezcan en la captura.
Future<void> _settle(
  WidgetTester tester, {
  int ms = 200,
  int cycles = 8,
}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  for (final el in find.byType(Image).evaluate().toList()) {
    final image = (el.widget as Image).image;
    await tester.runAsync(
      () => precacheImage(
        image,
        el,
      ).timeout(const Duration(seconds: 5), onTimeout: () {}),
    );
  }
  await tester.pump(const Duration(milliseconds: 50));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// [last]: restaura `debugDisableShadows` (flutter_test exige que cada test
/// termine con el valor por defecto).
Future<void> _shot(WidgetTester tester, String name, {bool last = true}) async {
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../docs/screenshots/$name.png'),
  );
  if (last) debugDisableShadows = true;
}

/// Líneas OCR de ejemplo (en la app las genera ML Kit en el dispositivo).
List<OcrLine> _fakeOcr(int n) => [
  for (var i = 0; i < n; i++)
    OcrLine(
      text: i == 0 ? 'FACTURA Nº 2026-1104' : 'Línea de texto $i',
      left: 0.08,
      top: 0.05 + i * 0.03,
      width: 0.6,
      height: 0.02,
    ),
];

void main() {
  late Directory tmp;
  final pages = <ScanPage>[];
  final sources = <SourceInfo>[];

  setUpAll(() async {
    await _loadFont('Roboto', [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
    ]);
    await _loadFont('MaterialIcons', ['MaterialIcons-Regular.otf']);
    tmp = Directory.systemTemp.createTempSync('scanner_shots');
    DocumentRepository.debugDocumentsDir = Directory('${tmp.path}/docs')
      ..createSync();
    DocumentRepository.debugTempDir = Directory('${tmp.path}/tmp')
      ..createSync();

    // Procesa las fotos de ejemplo con el motor real.
    final samples = ['factura_sombra', 'ticket', 'apaisado'];
    final filters = [
      ScanFilter.magicColor,
      ScanFilter.magicColor,
      ScanFilter.blackWhite,
    ];
    for (var i = 0; i < samples.length; i++) {
      final info = prepareSourceFile(
        'docs/samples/${samples[i]}.jpg',
        '${tmp.path}/src_$i.jpg',
      )!;
      sources.add(info);
      final r = renderPage(
        RenderRequest(
          sourcePath: info.path,
          quad: info.detected!,
          filter: filters[i],
          rotation: 0,
          outputPath: '${tmp.path}/page_$i.jpg',
        ),
      );
      pages.add(
        ScanPage(
            id: 'p$i',
            sourcePath: info.path,
            sourceWidth: info.width,
            sourceHeight: info.height,
            quad: info.detected!,
            detectedQuad: info.detected,
            filter: filters[i],
          )
          ..outputPath = r.path
          ..outputWidth = r.width
          ..outputHeight = r.height
          ..status = PageStatus.ready
          ..ocrStatus = OcrStatus.done
          ..ocrLines = _fakeOcr(18 + i * 7),
      );
    }
  });

  tearDownAll(() {
    DocumentRepository.debugDocumentsDir = null;
    DocumentRepository.debugTempDir = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // flutter_test dibuja las sombras como un borde negro: se reactivan.
    debugDisableShadows = false;
  }

  testWidgets('01 inicio vacío', (tester) async {
    await phone(tester);
    await tester.pumpWidget(const ScannerApp());
    await _settle(tester);
    await _shot(tester, '01_inicio_vacio');
  });

  testWidgets('02 elegir origen', (tester) async {
    await phone(tester);
    await tester.pumpWidget(const ScannerApp());
    await _settle(tester);
    await tester.tap(find.text('Escanear'));
    await tester.pumpAndSettle();
    await _shot(tester, '02_elegir_origen');
  });

  testWidgets('03 cámara con detección en vivo', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      const ScannerApp(
        home: CameraScreen(
          debugPreviewImage: 'docs/samples/factura_sombra.jpg',
        ),
      ),
    );
    await _settle(tester, ms: 400);
    await _shot(tester, '03_camara');
  });

  testWidgets('03 recorte', (tester) async {
    await phone(tester);
    final s = sources[0];
    await tester.pumpWidget(
      ScannerApp(
        home: CropScreen(
          imagePath: s.path,
          imageWidth: s.width,
          imageHeight: s.height,
          initialQuad: s.detected!,
          detectedQuad: s.detected,
        ),
      ),
    );
    await _settle(tester);
    // Arrastrando la esquina inferior derecha → aparece la lupa.
    final editor = tester.getRect(find.byType(Scaffold));
    final box = Rect.fromLTRB(
      editor.left,
      56 + 24,
      editor.right,
      editor.bottom - 80,
    );
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(s.width.toDouble(), s.height.toDouble()),
      box.deflate(28).size,
    ).destination;
    final img = Rect.fromCenter(
      center: box.center,
      width: fitted.width,
      height: fitted.height,
    );
    final br = Offset(
      img.left + s.detected!.br.x * img.width,
      img.top + s.detected!.br.y * img.height,
    );
    final g = await tester.startGesture(br);
    await g.moveBy(const Offset(-2, -3));
    await tester.pump();
    await _shot(tester, '04_recorte');
    await g.up();
  });

  testWidgets('04 filtros', (tester) async {
    await phone(tester);
    final s = sources[0];
    await tester.pumpWidget(
      ScannerApp(
        home: FilterScreen(
          sourcePath: s.path,
          quad: s.detected!,
          initialFilter: ScanFilter.magicColor,
          initialRotation: 0,
        ),
      ),
    );
    await _settle(tester, ms: 1500);
    await _shot(tester, '05_filtros');
  });

  testWidgets('05 documento con páginas', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      ScannerApp(home: ScanSessionScreen(debugPages: pages)),
    );
    await _settle(tester);
    await _shot(tester, '06_paginas', last: false);
    await tester.tap(find.text('Guardar PDF'));
    await tester.pumpAndSettle();
    await _shot(tester, '07_guardar_pdf');
  });

  testWidgets('07 inicio con documentos', (tester) async {
    await phone(tester);
    await tester.runAsync(() async {
      final names = [
        'Factura proveedor noviembre',
        'Ticket gasolina',
        'Albarán Medina Azahara',
      ];
      for (var i = 0; i < 3; i++) {
        final p = pages[i];
        final pdf = await buildPdf(
          [PdfPageInput(p.outputPath!, p.outputWidth, p.outputHeight)],
          pageSize: PdfPageSize.a4,
          title: names[i],
        );
        final thumb = await ImageService.thumbnail(p.outputPath!);
        await DocumentRepository.instance.save(
          name: names[i],
          pdfBytes: pdf,
          pages: i + 1,
          thumbnail: Uint8List.fromList(thumb),
          text: i == 1 ? null : ocrPlainText(p.ocrLines!),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpWidget(const ScannerApp());
    await _settle(tester, cycles: 16);
    await _shot(tester, '08_inicio_documentos');
  });
}
