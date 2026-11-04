import 'dart:convert';
import 'dart:io';

import 'package:camera_scanner/models/ocr_line.dart';
import 'package:camera_scanner/processing/codec.dart';
import 'package:camera_scanner/processing/enhance.dart';
import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/pipeline.dart';
import 'package:camera_scanner/services/app_prefs.dart';
import 'package:camera_scanner/services/device_saver.dart';
import 'package:camera_scanner/services/pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/synthetic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceSaver.describeLocation', () {
    test('documento SAF en el almacenamiento interno', () {
      final uri = Uri.parse(
        'content://com.android.externalstorage.documents/document/'
        'primary%3ADownload%2FEscaneos%2FFactura.pdf',
      );
      expect(
        DeviceSaver.describeLocation(uri),
        'Download/Escaneos/Factura.pdf',
      );
    });

    test('tarjeta SD', () {
      final uri = Uri.parse(
        'content://com.android.externalstorage.documents/document/'
        '1A2B-3C4D%3ADocumentos%2Fa.pdf',
      );
      expect(DeviceSaver.describeLocation(uri), '1A2B-3C4D/Documentos/a.pdf');
    });

    test('proveedor sin ruta (Drive, Descargas)', () {
      final uri = Uri.parse(
        'content://com.android.providers.downloads.documents/document/msf%3A1234',
      );
      // "msf:1234" sí tiene ":" → se muestra tal cual el identificador.
      expect(DeviceSaver.describeLocation(uri), 'msf/1234');
      final drive = Uri.parse(
        'content://com.google.android.apps.docs.storage/document/acc%3D1%3Bdoc%3D9',
      );
      expect(
        DeviceSaver.describeLocation(drive, fallbackName: 'Factura.pdf'),
        'Factura.pdf',
      );
    });

    test('ruta de archivo (iOS)', () {
      final uri = Uri.file(
        '/private/var/mobile/Documents/Escaneos/Factura.pdf',
      );
      expect(DeviceSaver.describeLocation(uri), 'Escaneos/Factura.pdf');
    });
  });

  group('calidad del PDF', () {
    late Directory tmp;
    late PdfPageInput page;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('pdf_quality');
      const truth = Quad(
        Pt(180, 200),
        Pt(820, 240),
        Pt(880, 1130),
        Pt(110, 1170),
      );
      // Foto grande (2400 px) para que la reducción tenga efecto.
      final photo = syntheticPhoto(
        width: 1800,
        height: 2400,
        corners: truth.scale(1.8, 1.8),
      );
      final input = '${tmp.path}/foto.jpg';
      File(input).writeAsBytesSync(encodeJpeg(photo, quality: 92));
      final info = prepareSourceFile(input, '${tmp.path}/src.jpg')!;
      final r = renderPage(
        RenderRequest(
          sourcePath: info.path,
          quad: info.detected!,
          filter: ScanFilter.original,
          rotation: 0,
          outputPath: '${tmp.path}/page.jpg',
        ),
      );
      page = PdfPageInput(
        r.path,
        r.width,
        r.height,
        lines: const [
          OcrLine(text: 'Total', left: 0.1, top: 0.1, width: 0.2, height: 0.03),
        ],
      );
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    test(
      'media y baja generan archivos más pequeños y conservan el texto',
      () async {
        final sizes = <PdfQuality, int>{};
        for (final q in PdfQuality.values) {
          final pdf = await buildPdf(
            [page],
            pageSize: PdfPageSize.a4,
            title: 'Q',
            quality: q,
            compress: false,
          );
          sizes[q] = pdf.length;
          expect(latin1.decode(pdf), contains('[(Total)]TJ'));
        }
        expect(sizes[PdfQuality.medium]!, lessThan(sizes[PdfQuality.high]!));
        expect(sizes[PdfQuality.low]!, lessThan(sizes[PdfQuality.medium]!));
      },
    );
  });

  group('AppPrefs', () {
    test('valores por defecto y persistencia', () async {
      SharedPreferences.setMockInitialValues({});
      await AppPrefs.init();
      expect(AppPrefs.autoCapture, isTrue);
      expect(AppPrefs.batchMode, isFalse);
      expect(AppPrefs.ocr, isTrue);
      expect(AppPrefs.quality, PdfQuality.high);
      expect(AppPrefs.pageSize, PdfPageSize.a4);
      expect(AppPrefs.defaultFilter, ScanFilter.magicColor);

      AppPrefs.quality = PdfQuality.low;
      AppPrefs.pageSize = PdfPageSize.fit;
      AppPrefs.saveToDevice = true;
      AppPrefs.defaultFilter = ScanFilter.blackWhite;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pdf.quality'), 'low');
      expect(prefs.getString('pdf.pageSize'), 'fit');
      expect(prefs.getBool('pdf.saveToDevice'), isTrue);
      expect(prefs.getString('scan.filter'), 'blackWhite');
      expect(AppPrefs.quality, PdfQuality.low);
    });
  });
}
