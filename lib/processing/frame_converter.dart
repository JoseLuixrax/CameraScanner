import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

/// Formato de los frames que entrega el stream de la cámara.
enum FrameFormat {
  /// YUV 4:2:0 en planos: 3 planos (Android, Y/U/V con cualquier stride) o
  /// 2 planos (iOS, Y + CbCr intercalado).
  yuv420,

  /// Un solo plano: Y seguido de VU intercalado (Android).
  nv21,

  /// Un solo plano BGRA de 8 bits (iOS).
  bgra8888,
}

/// Plano de un frame (independiente del plugin `camera`, para poder testear).
class FramePlane {
  const FramePlane(this.bytes, this.bytesPerRow, [this.bytesPerPixel = 1]);

  final Uint8List bytes;
  final int bytesPerRow;
  final int bytesPerPixel;
}

/// Convierte un frame de cámara en una [RgbImage] pequeña para la detección
/// en vivo: muestrea un píxel de cada `step` (lado mayor ≈ [targetLongSide])
/// y gira [quarterTurns] cuartos de vuelta en sentido horario para que quede
/// con la misma orientación que la vista previa.
///
/// Muestrear (en vez de leer el frame entero) hace que convertir un frame de
/// 12 MP cueste lo mismo que uno de 0,1 MP: unos milisegundos.
RgbImage frameToRgb({
  required FrameFormat format,
  required int width,
  required int height,
  required List<FramePlane> planes,
  int targetLongSide = 400,
  int quarterTurns = 0,
}) {
  final step = math.max(1, (math.max(width, height) / targetLongSide).ceil());
  final ow = math.max(1, width ~/ step);
  final oh = math.max(1, height ~/ step);
  final out = RgbImage(ow, oh);
  final o = out.data;
  final half = step ~/ 2;

  int clampByte(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.toInt());

  void putYuv(int oi, int y, int u, int v) {
    final d = u - 128, e = v - 128;
    o[oi] = clampByte(y + 1.402 * e);
    o[oi + 1] = clampByte(y - 0.344136 * d - 0.714136 * e);
    o[oi + 2] = clampByte(y + 1.772 * d);
  }

  var oi = 0;
  switch (format) {
    case FrameFormat.yuv420:
      final yp = planes[0];
      final yb = yp.bytes, yRow = yp.bytesPerRow, yPix = yp.bytesPerPixel;
      final biplanar = planes.length == 2;
      final up = planes[1];
      final vp = biplanar ? planes[1] : planes[2];
      final uRow = up.bytesPerRow, vRow = vp.bytesPerRow;
      final uPix = biplanar ? 2 : up.bytesPerPixel;
      final vPix = biplanar ? 2 : vp.bytesPerPixel;
      final vOff = biplanar ? 1 : 0;
      for (var oy = 0; oy < oh; oy++) {
        final sy = math.min(height - 1, oy * step + half);
        final cy = sy >> 1;
        for (var ox = 0; ox < ow; ox++) {
          final sx = math.min(width - 1, ox * step + half);
          final cx = sx >> 1;
          final yi = sy * yRow + sx * yPix;
          final ui = cy * uRow + cx * uPix;
          final vi = cy * vRow + cx * vPix + vOff;
          putYuv(
            oi,
            yi < yb.length ? yb[yi] : 0,
            ui < up.bytes.length ? up.bytes[ui] : 128,
            vi < vp.bytes.length ? vp.bytes[vi] : 128,
          );
          oi += 3;
        }
      }
      break;
    case FrameFormat.nv21:
      final p = planes[0];
      final b = p.bytes, row = p.bytesPerRow;
      final uvOff = row * height;
      for (var oy = 0; oy < oh; oy++) {
        final sy = math.min(height - 1, oy * step + half);
        final uvRow = uvOff + (sy >> 1) * row;
        for (var ox = 0; ox < ow; ox++) {
          final sx = math.min(width - 1, ox * step + half);
          final yi = sy * row + sx;
          final vi = uvRow + (sx >> 1) * 2;
          putYuv(
            oi,
            yi < b.length ? b[yi] : 0,
            vi + 1 < b.length ? b[vi + 1] : 128,
            vi < b.length ? b[vi] : 128,
          );
          oi += 3;
        }
      }
      break;
    case FrameFormat.bgra8888:
      final p = planes[0];
      final b = p.bytes, row = p.bytesPerRow;
      for (var oy = 0; oy < oh; oy++) {
        final sy = math.min(height - 1, oy * step + half);
        for (var ox = 0; ox < ow; ox++) {
          final sx = math.min(width - 1, ox * step + half);
          final i = sy * row + sx * 4;
          if (i + 2 < b.length) {
            o[oi] = b[i + 2];
            o[oi + 1] = b[i + 1];
            o[oi + 2] = b[i];
          }
          oi += 3;
        }
      }
      break;
  }
  return rotate90(out, quarterTurns);
}
