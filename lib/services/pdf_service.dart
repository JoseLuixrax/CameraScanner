import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Tamaño de página del PDF.
enum PdfPageSize {
  a4('A4'),
  letter('Carta'),

  /// La página toma la proporción de la imagen (ancho de A4).
  fit('Auto');

  const PdfPageSize(this.label);

  final String label;
}

/// Página a incluir en el PDF (JPEG ya procesado).
class PdfPageInput {
  const PdfPageInput(this.path, this.width, this.height);

  final String path;
  final int width;
  final int height;
}

class PdfService {
  PdfService._();

  /// Genera el PDF en un isolate. Los JPEG se incrustan tal cual (sin
  /// recomprimir), así que el tamaño final ≈ suma de las imágenes.
  static Future<Uint8List> build(
    List<PdfPageInput> pages, {
    required PdfPageSize pageSize,
    required String title,
  }) => Isolate.run(() => buildPdf(pages, pageSize: pageSize, title: title));
}

/// Versión síncrona/isolate-friendly (también usada en los tests).
Future<Uint8List> buildPdf(
  List<PdfPageInput> pages, {
  required PdfPageSize pageSize,
  required String title,
}) {
  final doc = pw.Document(
    title: title,
    creator: 'Escáner PDF',
    producer: 'Escáner PDF',
    compress: true,
  );
  for (final p in pages) {
    final image = pw.MemoryImage(File(p.path).readAsBytesSync());
    final landscape = p.width > p.height;
    final PdfPageFormat format;
    switch (pageSize) {
      case PdfPageSize.a4:
        format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
        break;
      case PdfPageSize.letter:
        format = landscape
            ? PdfPageFormat.letter.landscape
            : PdfPageFormat.letter;
        break;
      case PdfPageSize.fit:
        const base = 595.28; // ancho A4 en puntos
        format = landscape
            ? PdfPageFormat(base * p.width / p.height, base)
            : PdfPageFormat(base, base * p.height / p.width);
        break;
    }
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
  }
  return doc.save();
}
