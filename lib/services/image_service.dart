import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

import '../processing/enhance.dart';
import '../processing/geometry.dart';
import '../processing/image_ops.dart';
import '../processing/pipeline.dart';

/// Captura de imágenes y acceso al motor de procesado.
///
/// Todo el procesado pesado se ejecuta en isolates (`Isolate.run`) para no
/// bloquear la interfaz. Los closures que se envían al isolate se crean en
/// funciones estáticas que sólo capturan datos simples (rutas, listas...).
class ImageService {
  ImageService._();

  static final ImagePicker _picker = ImagePicker();

  /// Saca una foto con la cámara. Devuelve la ruta o `null` si se cancela.
  static Future<String?> takePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: kMaxSourceSide.toDouble(),
      maxHeight: kMaxSourceSide.toDouble(),
      imageQuality: 95,
      requestFullMetadata: false,
    );
    return file?.path;
  }

  /// Elige una o varias imágenes de la galería.
  static Future<List<String>> pickFromGallery() async {
    final files = await _picker.pickMultiImage(
      maxWidth: kMaxSourceSide.toDouble(),
      maxHeight: kMaxSourceSide.toDouble(),
      imageQuality: 95,
      requestFullMetadata: false,
    );
    return files.map((f) => f.path).toList();
  }

  /// Normaliza la imagen (EXIF, tamaño) en [workDir] y detecta el documento.
  static Future<SourceInfo> prepare(String inputPath, Directory workDir) async {
    final out =
        '${workDir.path}/src_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final info = await _runPrepareFile(inputPath, out);
    if (info != null) return info;

    // Formato no soportado en Dart puro (HEIC/HEIF...): usamos el
    // decodificador nativo de la plataforma a través de dart:ui.
    final rgba = await _decodeNative(inputPath);
    return _runPrepareRgba(rgba.bytes, rgba.width, rgba.height, out);
  }

  static Future<SourceInfo?> _runPrepareFile(String input, String output) =>
      Isolate.run(() => prepareSourceFile(input, output));

  static Future<SourceInfo> _runPrepareRgba(
    Uint8List rgba,
    int w,
    int h,
    String output,
  ) => Isolate.run(() => prepareSourceRgba(rgba, w, h, output));

  static Future<({Uint8List bytes, int width, int height})> _decodeNative(
    String path,
  ) async {
    final data = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(data);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        final long = math.max(w, h);
        if (long <= kMaxSourceSide) {
          return ui.TargetImageSize(width: w, height: h);
        }
        final s = kMaxSourceSide / long;
        return ui.TargetImageSize(
          width: (w * s).round(),
          height: (h * s).round(),
        );
      },
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = (
      bytes: bd!.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
    image.dispose();
    codec.dispose();
    return result;
  }

  /// Renderizado final de una página a JPEG.
  static Future<RenderResult> render({
    required String sourcePath,
    required Quad quad,
    required ScanFilter filter,
    required int rotation,
    required String outputPath,
  }) {
    final req = RenderRequest(
      sourcePath: sourcePath,
      quad: quad,
      filter: filter,
      rotation: rotation,
      outputPath: outputPath,
    );
    return Isolate.run(() => renderPage(req));
  }

  /// Recorte rectificado a resolución de previsualización.
  static Future<RgbImage> warpPreview(
    String sourcePath,
    Quad quad, {
    int maxSide = 1600,
  }) => Isolate.run(() => warpFile(sourcePath, quad, maxSide: maxSide));

  /// Previsualización (BMP) de un filtro sobre la imagen ya recortada.
  static Future<Uint8List> filterPreview(RgbImage warped, ScanFilter filter) =>
      Isolate.run(() => filterPreviewBmp(warped, filter));

  /// Miniaturas de todos los filtros.
  static Future<Map<ScanFilter, Uint8List>> thumbnails(
    RgbImage warped, {
    int maxSide = 200,
  }) => Isolate.run(() => filterThumbnails(warped, maxSide));

  /// Miniatura JPEG para la lista de documentos guardados.
  static Future<Uint8List> thumbnail(String path, {int maxSide = 360}) =>
      Isolate.run(() => thumbnailJpeg(path, maxSide));
}
