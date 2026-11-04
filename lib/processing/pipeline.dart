import 'dart:io';
import 'dart:typed_data';

import 'codec.dart';
import 'document_detector.dart';
import 'enhance.dart';
import 'geometry.dart';
import 'image_ops.dart';
import 'perspective.dart';

/// Funciones de alto nivel pensadas para ejecutarse dentro de un isolate
/// (`Isolate.run`). Sólo reciben/devuelven datos "enviables" entre isolates.

/// Lado mayor máximo con el que se trabaja internamente (≈ A4 a 300 ppp).
const int kMaxSourceSide = 3000;

/// Resultado de preparar una imagen importada.
class SourceInfo {
  const SourceInfo({
    required this.path,
    required this.width,
    required this.height,
    this.detected,
    this.confidence = 0,
  });

  /// JPEG normalizado (orientación aplicada, tamaño limitado, sin EXIF).
  final String path;
  final int width;
  final int height;

  /// Esquinas detectadas normalizadas a 0..1, o `null` si no hay documento.
  final Quad? detected;
  final double confidence;
}

/// Decodifica [inputPath], lo normaliza y lo guarda en [outputPath] como JPEG.
/// Devuelve `null` si el formato no se puede decodificar en Dart puro.
SourceInfo? prepareSourceFile(String inputPath, String outputPath) {
  final bytes = File(inputPath).readAsBytesSync();
  final rgb = decodeToRgb(bytes, maxSide: kMaxSourceSide);
  if (rgb == null) return null;
  return _prepare(rgb, outputPath);
}

/// Igual que [prepareSourceFile] pero partiendo de píxeles RGBA ya
/// decodificados (decodificador nativo de Flutter para HEIC, etc.).
SourceInfo prepareSourceRgba(
  Uint8List rgba,
  int width,
  int height,
  String outputPath,
) {
  final rgb = limitSize(rgbaToRgb(rgba, width, height), kMaxSourceSide);
  return _prepare(rgb, outputPath);
}

SourceInfo _prepare(RgbImage rgb, String outputPath) {
  File(outputPath).writeAsBytesSync(encodeJpeg(rgb, quality: 95));
  final det = const DocumentDetector().detect(rgb);
  return SourceInfo(
    path: outputPath,
    width: rgb.width,
    height: rgb.height,
    detected: det?.quad.scale(1 / rgb.width, 1 / rgb.height),
    confidence: det?.confidence ?? 0,
  );
}

/// Detecta el documento en un JPEG ya normalizado (esquinas 0..1).
Quad? detectInFile(String path) {
  final rgb = decodeToRgb(File(path).readAsBytesSync());
  if (rgb == null) return null;
  final det = const DocumentDetector().detect(rgb);
  return det?.quad.scale(1 / rgb.width, 1 / rgb.height);
}

/// Recorta y rectifica la imagen [sourcePath] según [quad] (normalizado 0..1).
RgbImage warpFile(
  String sourcePath,
  Quad quad, {
  int maxSide = kMaxSourceSide,
}) {
  final src = decodeToRgb(File(sourcePath).readAsBytesSync());
  if (src == null) {
    throw StateError('No se pudo leer la imagen $sourcePath');
  }
  return warpRgb(src, quad, maxSide: maxSide);
}

RgbImage warpRgb(RgbImage src, Quad quad, {int maxSide = kMaxSourceSide}) {
  final q = quad.scale(src.width.toDouble(), src.height.toDouble());
  final size = estimateOutputSize(q, src.width, src.height, maxSide: maxSide);
  return warpDocument(src, q, size.width, size.height);
}

/// Petición de renderizado final de una página.
class RenderRequest {
  const RenderRequest({
    required this.sourcePath,
    required this.quad,
    required this.filter,
    required this.rotation,
    required this.outputPath,
    this.quality = 88,
  });

  final String sourcePath;
  final Quad quad;
  final ScanFilter filter;
  final int rotation;
  final String outputPath;
  final int quality;
}

class RenderResult {
  const RenderResult(this.path, this.width, this.height);

  final String path;
  final int width;
  final int height;
}

/// Pipeline completo: recorte + perspectiva + filtro + rotación → JPEG.
RenderResult renderPage(RenderRequest r) {
  final warped = warpFile(r.sourcePath, r.quad);
  final filtered = applyFilter(warped, r.filter);
  final rotated = rotate90(filtered, r.rotation);
  File(r.outputPath).writeAsBytesSync(encodeJpeg(rotated, quality: r.quality));
  return RenderResult(r.outputPath, rotated.width, rotated.height);
}

/// Aplica [filter] y devuelve un BMP listo para `Image.memory`.
Uint8List filterPreviewBmp(RgbImage warped, ScanFilter filter) =>
    encodeBmp(applyFilter(warped, filter));

/// Miniaturas (BMP) de todos los filtros para el selector.
Map<ScanFilter, Uint8List> filterThumbnails(RgbImage warped, int maxSide) {
  final small = limitSize(warped, maxSide);
  return {
    for (final f in ScanFilter.values) f: encodeBmp(applyFilter(small, f)),
  };
}

/// Miniatura JPEG de una imagen (para la lista de documentos).
Uint8List thumbnailJpeg(String path, int maxSide) {
  final rgb = decodeToRgb(File(path).readAsBytesSync(), maxSide: maxSide);
  if (rgb == null) throw StateError('No se pudo leer $path');
  return encodeJpeg(rgb, quality: 80);
}
