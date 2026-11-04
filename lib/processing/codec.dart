import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_ops.dart';

/// Decodifica JPEG/PNG/WebP/BMP/GIF/TIFF aplicando la orientación EXIF y
/// limitando el lado mayor a [maxSide]. Devuelve `null` si el formato no está
/// soportado en Dart puro (p. ej. HEIC): en ese caso se usa el decodificador
/// nativo de Flutter (ver `ImageService`).
RgbImage? decodeToRgb(Uint8List bytes, {int maxSide = 3000}) {
  img.Image? image;
  final jpeg = img.JpegDecoder();
  if (jpeg.isValidFile(bytes)) {
    // Para fotos enormes, decodifica ya reducida (mucho más rápido).
    final info = jpeg.startDecode(bytes);
    var scale = 1;
    if (info != null) {
      final long = math.max(info.width, info.height);
      while (scale < 8 && long / (scale * 2) >= maxSide) {
        scale *= 2;
      }
    }
    image = img.decodeJpg(bytes, scale: scale);
  } else {
    image = img.decodeImage(bytes);
  }
  if (image == null) return null;
  image = img.bakeOrientation(image);
  return limitSize(imageToRgb(image), maxSide);
}

/// Convierte un `img.Image` (cualquier formato) a [RgbImage].
RgbImage imageToRgb(img.Image image) {
  var src = image;
  if (src.format != img.Format.uint8 || src.hasPalette) {
    src = src.convert(format: img.Format.uint8, numChannels: 3);
  }
  final bytes = src.getBytes(order: img.ChannelOrder.rgb);
  return RgbImage(src.width, src.height, Uint8List.fromList(bytes));
}

/// Construye un [RgbImage] desde un buffer RGBA (p. ej. el de `dart:ui`).
RgbImage rgbaToRgb(Uint8List rgba, int width, int height) {
  final out = RgbImage(width, height);
  final o = out.data;
  for (var i = 0, j = 0; j < o.length; i += 4, j += 3) {
    o[j] = rgba[i];
    o[j + 1] = rgba[i + 1];
    o[j + 2] = rgba[i + 2];
  }
  return out;
}

img.Image _toImage(RgbImage rgb) => img.Image.fromBytes(
  width: rgb.width,
  height: rgb.height,
  bytes: rgb.data.buffer,
  bytesOffset: rgb.data.offsetInBytes,
  numChannels: 3,
);

Uint8List encodeJpeg(RgbImage rgb, {int quality = 90}) =>
    img.encodeJpg(_toImage(rgb), quality: quality);

/// BMP sin compresión: codificación instantánea, ideal para previsualizar.
Uint8List encodeBmp(RgbImage rgb) => img.encodeBmp(_toImage(rgb));
