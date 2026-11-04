import '../processing/enhance.dart';
import '../processing/geometry.dart';

enum PageStatus { processing, ready, error }

/// Una página del documento que se está escaneando.
///
/// Las esquinas ([quad]) se guardan normalizadas (0..1) respecto a la imagen
/// fuente, así son independientes de la resolución con la que se muestre.
class ScanPage {
  ScanPage({
    required this.id,
    required this.sourcePath,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.quad,
    required this.detectedQuad,
    required this.filter,
    this.rotation = 0,
  });

  final String id;

  /// JPEG normalizado (orientación aplicada) del que parte el procesado.
  final String sourcePath;
  final int sourceWidth;
  final int sourceHeight;

  Quad quad;

  /// Esquinas que encontró el detector automático (o `null`).
  final Quad? detectedQuad;

  ScanFilter filter;

  /// Cuartos de vuelta en sentido horario.
  int rotation;

  /// Resultado final (JPEG recortado + filtro + rotación).
  String? outputPath;
  int outputWidth = 0;
  int outputHeight = 0;

  PageStatus status = PageStatus.processing;
  String? error;

  /// Se incrementa en cada edición para descartar procesados obsoletos.
  int revision = 0;
}
