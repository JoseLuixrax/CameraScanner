import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/ocr_line.dart';

/// Tamaño de página del PDF.
enum PdfPageSize {
  a4('A4'),
  letter('Carta'),

  /// La página toma la proporción de la imagen (ancho de A4).
  fit('Auto');

  const PdfPageSize(this.label);

  final String label;
}

/// Página a incluir en el PDF (JPEG ya procesado + texto reconocido).
class PdfPageInput {
  const PdfPageInput(
    this.path,
    this.width,
    this.height, {
    this.lines = const [],
  });

  final String path;
  final int width;
  final int height;

  /// Texto OCR. Si no está vacío se añade como capa de texto invisible, de
  /// modo que el PDF se puede buscar y el texto seleccionar y copiar.
  final List<OcrLine> lines;
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

PdfPageFormat _formatFor(PdfPageInput p, PdfPageSize size) {
  final landscape = p.width > p.height;
  switch (size) {
    case PdfPageSize.a4:
      return landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
    case PdfPageSize.letter:
      return landscape ? PdfPageFormat.letter.landscape : PdfPageFormat.letter;
    case PdfPageSize.fit:
      const base = 595.28; // ancho A4 en puntos
      return landscape
          ? PdfPageFormat(base * p.width / p.height, base)
          : PdfPageFormat(base, base * p.height / p.width);
  }
}

/// Versión isolate-friendly (también usada en los tests).
///
/// [debugVisibleText] dibuja la capa de texto en rojo en lugar de invisible,
/// para comprobar que queda alineada con el texto de la imagen.
Future<Uint8List> buildPdf(
  List<PdfPageInput> pages, {
  required PdfPageSize pageSize,
  required String title,
  bool compress = true,
  bool debugVisibleText = false,
}) {
  final doc = pw.Document(
    title: title,
    creator: 'Escáner PDF',
    producer: 'Escáner PDF',
    compress: compress,
  );
  // Helvetica es una fuente estándar de PDF: no se incrusta (0 bytes extra)
  // y, con WinAnsiEncoding, cubre español, francés, alemán, italiano, etc.
  final font = pw.Font.helvetica();
  final textStyle = pw.TextStyle(
    font: font,
    fontSize: 12,
    color: debugVisibleText ? PdfColors.red : PdfColors.black,
    renderingMode: debugVisibleText
        ? PdfTextRenderingMode.fill
        : PdfTextRenderingMode.invisible,
  );

  for (final p in pages) {
    final image = pw.MemoryImage(File(p.path).readAsBytesSync());
    final format = _formatFor(p, pageSize);
    // Imagen encajada (contain) y centrada en la página.
    final scale = math.min(format.width / p.width, format.height / p.height);
    final iw = p.width * scale, ih = p.height * scale;
    final ox = (format.width - iw) / 2, oy = (format.height - ih) / 2;

    final textLayer = <pw.Widget>[];
    for (final line in p.lines) {
      // Recorta antes de convertir: en WinAnsi «…» es 0x85, que Dart
      // considera espacio en blanco (U+0085) y trim() lo eliminaría.
      final text = toWinAnsi(line.text.trim());
      final w = line.width * iw, h = line.height * ih;
      if (text.isEmpty || w < 1 || h < 1) continue;
      // El texto se escala (independiente en X e Y) para ocupar exactamente
      // la caja de la línea: así la selección coincide con lo que se ve.
      textLayer.add(
        pw.Positioned(
          left: ox + line.left * iw,
          top: oy + line.top * ih,
          child: pw.SizedBox(
            width: w,
            height: h,
            child: pw.FittedBox(
              fit: pw.BoxFit.fill,
              child: pw.Text(text, style: textStyle, maxLines: 1),
            ),
          ),
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(
          children: [
            pw.Positioned(
              left: ox,
              top: oy,
              child: pw.Image(image, width: iw, height: ih),
            ),
            // La imagen va debajo; el texto invisible encima (como los PDF
            // "searchable" de los escáneres profesionales).
            ...textLayer,
          ],
        ),
      ),
    );
  }
  return doc.save();
}

/// Caracteres Unicode que en WinAnsiEncoding ocupan los códigos 0x80–0x9F.
const Map<int, int> _winAnsiExtras = {
  0x20AC: 0x80, // €
  0x201A: 0x82, // ‚
  0x0192: 0x83, // ƒ
  0x201E: 0x84, // „
  0x2026: 0x85, // …
  0x2020: 0x86, // †
  0x2021: 0x87, // ‡
  0x02C6: 0x88, // ˆ
  0x2030: 0x89, // ‰
  0x0160: 0x8A, // Š
  0x2039: 0x8B, // ‹
  0x0152: 0x8C, // Œ
  0x017D: 0x8E, // Ž
  0x2018: 0x91, // ‘
  0x2019: 0x92, // ’
  0x201C: 0x93, // “
  0x201D: 0x94, // ”
  0x2022: 0x95, // •
  0x2013: 0x96, // –
  0x2014: 0x97, // —
  0x02DC: 0x98, // ˜
  0x2122: 0x99, // ™
  0x0161: 0x9A, // š
  0x203A: 0x9B, // ›
  0x0153: 0x9C, // œ
  0x017E: 0x9E, // ž
  0x0178: 0x9F, // Ÿ
};

/// Letras de Latin Extended-A sin equivalente en WinAnsi → letra base.
const List<String> _latinExtA = [
  'A',
  'a',
  'A',
  'a',
  'A',
  'a',
  'C',
  'c',
  'C',
  'c',
  'C',
  'c',
  'C',
  'c',
  'D',
  'd',
  'D',
  'd',
  'E',
  'e',
  'E',
  'e',
  'E',
  'e',
  'E',
  'e',
  'E',
  'e',
  'G',
  'g',
  'G',
  'g',
  'G',
  'g',
  'G',
  'g',
  'H',
  'h',
  'H',
  'h',
  'I',
  'i',
  'I',
  'i',
  'I',
  'i',
  'I',
  'i',
  'I',
  'i',
  'IJ',
  'ij',
  'J',
  'j',
  'K',
  'k',
  'k',
  'L',
  'l',
  'L',
  'l',
  'L',
  'l',
  'L',
  'l',
  'L',
  'l',
  'N',
  'n',
  'N',
  'n',
  'N',
  'n',
  '\'n',
  'N',
  'n',
  'O',
  'o',
  'O',
  'o',
  'O',
  'o',
  'OE',
  'oe',
  'R',
  'r',
  'R',
  'r',
  'R',
  'r',
  'S',
  's',
  'S',
  's',
  'S',
  's',
  'S',
  's',
  'T',
  't',
  'T',
  't',
  'T',
  't',
  'U',
  'u',
  'U',
  'u',
  'U',
  'u',
  'U',
  'u',
  'U',
  'u',
  'U',
  'u',
  'W',
  'w',
  'Y',
  'y',
  'Y',
  'Z',
  'z',
  'Z',
  'z',
  'Z',
  'z',
  's',
];

/// Convierte [s] a caracteres representables con Helvetica/WinAnsiEncoding
/// (la librería `pdf` codifica el texto en Latin-1 y el PDF declara WinAnsi).
String toWinAnsi(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x09 || r == 0x0A || r == 0x0D) {
      out.writeCharCode(0x20);
    } else if ((r >= 0x20 && r <= 0x7E) || (r >= 0xA0 && r <= 0xFF)) {
      out.writeCharCode(r);
    } else if (_winAnsiExtras.containsKey(r)) {
      out.writeCharCode(_winAnsiExtras[r]!);
    } else if (r >= 0x0100 && r <= 0x017F) {
      out.write(_latinExtA[r - 0x0100]);
    } else if (r == 0x2032 || r == 0x2035) {
      out.write("'");
    } else if (r < 0x20 || (r >= 0x7F && r < 0xA0)) {
      // Caracteres de control: se descartan.
    } else {
      out.write('?');
    }
  }
  return out.toString();
}
