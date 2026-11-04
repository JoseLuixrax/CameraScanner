import 'dart:convert';
import 'dart:io';

import 'package:camera_scanner/models/ocr_line.dart';
import 'package:camera_scanner/processing/codec.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:camera_scanner/services/ocr_service.dart';
import 'package:camera_scanner/services/pdf_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Respuesta con el formato que devuelve el plugin nativo de ML Kit.
Map<String, Object?> _mlKitLine(String text, int l, int t, int r, int b) => {
  'text': text,
  'rect': {'left': l, 'top': t, 'right': r, 'bottom': b},
  'points': [
    {'x': l, 'y': t},
    {'x': r, 'y': t},
    {'x': r, 'y': b},
    {'x': l, 'y': b},
  ],
  'recognizedLanguages': ['es'],
  'confidence': 0.9,
  'angle': 0.0,
  'elements': <Object>[],
};

Map<String, Object?> _mlKitBlock(List<Map<String, Object?>> lines) => {
  'text': lines.map((l) => l['text']).join('\n'),
  'rect': lines.first['rect'],
  'points': lines.first['points'],
  'recognizedLanguages': ['es'],
  'lines': lines,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('toWinAnsi', () {
    test('conserva el español, francés, alemán e italiano', () {
      const s = 'Año, niño, ¿qué? ¡olé! ç àèìòù ÄÖÜß äöü éêë Nº 1ª';
      expect(toWinAnsi(s), s);
    });

    test('mapea los símbolos de WinAnsi (0x80–0x9F)', () {
      expect(toWinAnsi('€'), '\u0080');
      expect(
        toWinAnsi('“hola” – adiós…'),
        '\u0093hola\u0094 \u0096 adiós\u0085',
      );
      expect(toWinAnsi('Œuvre œ • ™'), '\u008Cuvre \u009C \u0095 \u0099');
      // Al codificar en Latin-1 quedan los bytes WinAnsi correctos.
      expect(latin1.encode(toWinAnsi('5 €')), [0x35, 0x20, 0x80]);
    });

    test('translitera letras sin equivalente y descarta controles', () {
      expect(toWinAnsi('Łódź Kraków Ştefan'), 'Lódz Kraków Stefan');
      expect(toWinAnsi('a\tb\nc'), 'a b c');
      expect(toWinAnsi('x\u0007y'), 'xy');
      expect(toWinAnsi('漢字'), '??');
    });
  });

  test('ocrPlainText separa líneas y bloques', () {
    const lines = [
      OcrLine(text: 'FACTURA', left: 0, top: 0, width: 1, height: 1),
      OcrLine(
        text: 'Cliente: Ana',
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        block: 1,
      ),
      OcrLine(
        text: 'Pozoblanco',
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        block: 1,
      ),
    ];
    expect(ocrPlainText(lines), 'FACTURA\n\nCliente: Ana\nPozoblanco');
    expect(ocrPlainText(const []), '');
  });

  group('MlKitOcrEngine', () {
    const channel = MethodChannel('google_mlkit_text_recognizer');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'vision#startTextRecognizer') {
          return {
            'text': 'FACTURA Nº 12\nTotal: 45,90 €',
            'blocks': [
              _mlKitBlock([_mlKitLine('FACTURA Nº 12', 100, 50, 700, 110)]),
              _mlKitBlock([
                _mlKitLine('Total: 45,90 €', 120, 900, 520, 940),
                _mlKitLine('   ', 0, 0, 10, 10), // vacía → se descarta
              ]),
            ],
          };
        }
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('convierte el resultado a líneas normalizadas', () async {
      final engine = MlKitOcrEngine();
      final lines = await engine.recognize('/tmp/pagina.jpg', 1000, 1400);
      await engine.close();

      expect(lines.length, 2);
      final first = lines.first;
      expect(first.text, 'FACTURA Nº 12');
      expect(first.left, closeTo(0.1, 1e-9));
      expect(first.top, closeTo(50 / 1400, 1e-9));
      expect(first.width, closeTo(0.6, 1e-9));
      expect(first.height, closeTo(60 / 1400, 1e-9));
      expect(first.block, 0);
      expect(lines[1].block, 1);

      final start = calls.firstWhere(
        (c) => c.method == 'vision#startTextRecognizer',
      );
      final args = start.arguments as Map;
      expect((args['imageData'] as Map)['path'], '/tmp/pagina.jpg');
      expect(args['script'], 0); // latino
      expect(
        calls.any((c) => c.method == 'vision#closeTextRecognizer'),
        isTrue,
      );
    });
  });

  test(
    'OcrService devuelve null si no hay plugin (escritorio/tests)',
    () async {
      final previous = OcrService.engine;
      OcrService.engine = MlKitOcrEngine(); // sin mock → MissingPluginException
      addTearDown(() => OcrService.engine = previous);
      expect(await OcrService.recognize('/no/existe.jpg', 10, 10), isNull);
    },
  );

  group('PDF con capa de texto', () {
    late Directory tmp;
    late String imagePath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ocr_pdf');
      imagePath = '${tmp.path}/page.jpg';
      final img = RgbImage(800, 1100);
      img.data.fillRange(0, img.data.length, 255);
      File(imagePath).writeAsBytesSync(encodeJpeg(img));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    const lines = [
      OcrLine(
        text: 'FACTURA Nº 2026',
        left: 0.1,
        top: 0.05,
        width: 0.6,
        height: 0.04,
      ),
      OcrLine(
        text: 'Total: 45,90 €',
        left: 0.1,
        top: 0.8,
        width: 0.4,
        height: 0.03,
      ),
    ];

    test('añade texto invisible (modo 3 Tr) con el contenido OCR', () async {
      final pdf = await buildPdf(
        [PdfPageInput(imagePath, 800, 1100, lines: lines)],
        pageSize: PdfPageSize.a4,
        title: 'OCR',
        compress: false,
      );
      final s = latin1.decode(pdf);
      expect(s, contains('3 Tr'));
      // pw.Text escribe cada palabra como un objeto de texto (TJ).
      for (final word in ['FACTURA', 'N\u00BA', '2026', 'Total:', '45,90']) {
        expect(s, contains('[($word)]TJ'));
      }
      // "€" se escribe como el byte WinAnsi 0x80.
      expect(s, contains('[(\u0080)]TJ'));
      expect(s, contains('/Helvetica'));
      expect(s, contains('/WinAnsiEncoding'));
    });

    test('sin OCR no hay ningún texto en la página', () async {
      final pdf = await buildPdf(
        [PdfPageInput(imagePath, 800, 1100)],
        pageSize: PdfPageSize.a4,
        title: 'Sin OCR',
        compress: false,
      );
      final s = latin1.decode(pdf);
      expect(s, isNot(contains('TJ')));
      expect(s, isNot(contains('/Helvetica')));
    });

    test('la capa de texto funciona en todos los tamaños de página', () async {
      for (final size in PdfPageSize.values) {
        final pdf = await buildPdf(
          [PdfPageInput(imagePath, 800, 1100, lines: lines)],
          pageSize: size,
          title: 'OCR',
          compress: false,
        );
        expect(latin1.decode(pdf), contains('[(45,90)]TJ'));
      }
    });
  });
}
