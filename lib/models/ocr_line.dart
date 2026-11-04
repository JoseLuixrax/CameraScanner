/// Línea de texto reconocida (OCR) en una página.
///
/// La caja está normalizada (0..1) respecto a la imagen final de la página,
/// así sirve igual para cualquier tamaño de página del PDF. Es una clase de
/// datos simple para poder enviarla a los isolates que generan el PDF.
class OcrLine {
  const OcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.block = 0,
  });

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  /// Índice del bloque (párrafo) al que pertenece, para reconstruir el texto.
  final int block;

  @override
  String toString() =>
      'OcrLine("$text", ${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${width.toStringAsFixed(3)}x${height.toStringAsFixed(3)})';
}

/// Texto plano de una página: líneas del mismo bloque separadas por salto de
/// línea y bloques separados por una línea en blanco.
String ocrPlainText(List<OcrLine> lines) {
  final sb = StringBuffer();
  int? lastBlock;
  for (final l in lines) {
    if (lastBlock != null) sb.write(l.block == lastBlock ? '\n' : '\n\n');
    sb.write(l.text);
    lastBlock = l.block;
  }
  return sb.toString();
}
