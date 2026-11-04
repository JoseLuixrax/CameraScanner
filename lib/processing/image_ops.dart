import 'dart:math' as math;
import 'dart:typed_data';

/// Imagen RGB de 8 bits, entrelazada (r, g, b, r, g, b, ...).
///
/// Es la representación interna de todo el motor de procesado: no depende de
/// Flutter ni de ningún paquete, así que se puede usar en isolates y en tests.
class RgbImage {
  RgbImage(this.width, this.height, [Uint8List? data])
    : data = data ?? Uint8List(width * height * 3) {
    assert(this.data.length == width * height * 3);
  }

  final int width;
  final int height;
  final Uint8List data;

  int get pixelCount => width * height;

  RgbImage clone() => RgbImage(width, height, Uint8List.fromList(data));
}

/// Redimensiona promediando áreas (buena calidad al reducir).
RgbImage resizeArea(RgbImage src, int dw, int dh) {
  if (dw == src.width && dh == src.height) return src.clone();
  final out = RgbImage(dw, dh);
  final sw = src.width;
  final sh = src.height;
  final sx = sw / dw;
  final sy = sh / dh;
  final s = src.data;
  final o = out.data;
  // Precalcula rangos de columnas.
  final x0s = Int32List(dw);
  final x1s = Int32List(dw);
  for (var x = 0; x < dw; x++) {
    x0s[x] = (x * sx).floor();
    x1s[x] = math.max(x0s[x] + 1, math.min(sw, ((x + 1) * sx).ceil()));
  }
  var oi = 0;
  for (var y = 0; y < dh; y++) {
    final y0 = (y * sy).floor();
    final y1 = math.max(y0 + 1, math.min(sh, ((y + 1) * sy).ceil()));
    for (var x = 0; x < dw; x++) {
      final x0 = x0s[x];
      final x1 = x1s[x];
      var r = 0, g = 0, b = 0;
      for (var yy = y0; yy < y1; yy++) {
        var i = (yy * sw + x0) * 3;
        for (var xx = x0; xx < x1; xx++) {
          r += s[i];
          g += s[i + 1];
          b += s[i + 2];
          i += 3;
        }
      }
      final cnt = (y1 - y0) * (x1 - x0);
      o[oi++] = r ~/ cnt;
      o[oi++] = g ~/ cnt;
      o[oi++] = b ~/ cnt;
    }
  }
  return out;
}

/// Reduce la imagen para que su lado mayor no supere [maxSide].
RgbImage limitSize(RgbImage src, int maxSide) {
  final long = math.max(src.width, src.height);
  if (long <= maxSide) return src;
  final s = maxSide / long;
  return resizeArea(
    src,
    math.max(1, (src.width * s).round()),
    math.max(1, (src.height * s).round()),
  );
}

/// Gira la imagen [quarterTurns] cuartos de vuelta en sentido horario.
RgbImage rotate90(RgbImage src, int quarterTurns) {
  final t = quarterTurns % 4;
  if (t == 0) return src;
  final w = src.width;
  final h = src.height;
  final ow = t == 2 ? w : h;
  final oh = t == 2 ? h : w;
  final out = RgbImage(ow, oh);
  final s = src.data;
  final o = out.data;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int nx, ny;
      switch (t) {
        case 1:
          nx = h - 1 - y;
          ny = x;
          break;
        case 2:
          nx = w - 1 - x;
          ny = h - 1 - y;
          break;
        default:
          nx = y;
          ny = w - 1 - x;
      }
      final si = (y * w + x) * 3;
      final oi = (ny * ow + nx) * 3;
      o[oi] = s[si];
      o[oi + 1] = s[si + 1];
      o[oi + 2] = s[si + 2];
    }
  }
  return out;
}

/// Extrae un canal (0 = R, 1 = G, 2 = B) como plano float.
Float32List channelPlane(RgbImage img, int c) {
  final n = img.pixelCount;
  final out = Float32List(n);
  final d = img.data;
  for (var i = 0, j = c; i < n; i++, j += 3) {
    out[i] = d[j].toDouble();
  }
  return out;
}

/// Luminancia (BT.601) como plano de 8 bits.
Uint8List luminance(RgbImage img) {
  final n = img.pixelCount;
  final out = Uint8List(n);
  final d = img.data;
  for (var i = 0, j = 0; i < n; i++, j += 3) {
    out[i] = (d[j] * 77 + d[j + 1] * 150 + d[j + 2] * 29 + 128) >> 8;
  }
  return out;
}

/// Desenfoque gaussiano separable sobre un plano float.
///
/// El bucle interior no comprueba bordes (sólo las [r] columnas/filas de
/// cada extremo replican el borde), lo que lo hace ~3x más rápido.
Float32List gaussianBlur(Float32List src, int w, int h, double sigma) {
  if (sigma <= 0) return Float32List.fromList(src);
  final r = math.max(1, (sigma * 3).ceil());
  final k = Float32List(2 * r + 1);
  var sum = 0.0;
  for (var i = -r; i <= r; i++) {
    final v = math.exp(-(i * i) / (2 * sigma * sigma));
    k[i + r] = v;
    sum += v;
  }
  for (var i = 0; i < k.length; i++) {
    k[i] /= sum;
  }
  final n = k.length;
  final tmp = Float32List(w * h);
  final out = Float32List(w * h);

  // Horizontal.
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      if (x >= r && x < w - r) {
        final base = row + x - r;
        for (var i = 0; i < n; i++) {
          acc += src[base + i] * k[i];
        }
      } else {
        for (var i = -r; i <= r; i++) {
          final xx = (x + i).clamp(0, w - 1);
          acc += src[row + xx] * k[i + r];
        }
      }
      tmp[row + x] = acc;
    }
  }
  // Vertical: se acumula fila a fila (acceso secuencial a memoria).
  for (var y = 0; y < h; y++) {
    final orow = y * w;
    for (var i = -r; i <= r; i++) {
      final yy = (y + i).clamp(0, h - 1);
      final srow = yy * w;
      final kv = k[i + r];
      for (var x = 0; x < w; x++) {
        out[orow + x] += tmp[srow + x] * kv;
      }
    }
  }
  return out;
}

/// Dilatación (máximo) de una máscara binaria con un cuadrado de radio [r].
Uint8List dilateMask(Uint8List src, int w, int h, int r) {
  if (r <= 0) return Uint8List.fromList(src);
  final tmp = Uint8List(w * h);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - r);
      final x1 = math.min(w - 1, x + r);
      var v = 0;
      for (var xx = x0; xx <= x1; xx++) {
        if (src[row + xx] != 0) {
          v = 1;
          break;
        }
      }
      tmp[row + x] = v;
    }
  }
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - r);
    final y1 = math.min(h - 1, y + r);
    for (var x = 0; x < w; x++) {
      var v = 0;
      for (var yy = y0; yy <= y1; yy++) {
        if (tmp[yy * w + x] != 0) {
          v = 1;
          break;
        }
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

/// Erosión (mínimo) de una máscara binaria con un cuadrado de radio [r].
Uint8List erodeMask(Uint8List src, int w, int h, int r) {
  final inv = Uint8List(w * h);
  for (var i = 0; i < inv.length; i++) {
    inv[i] = src[i] == 0 ? 1 : 0;
  }
  final d = dilateMask(inv, w, h, r);
  for (var i = 0; i < d.length; i++) {
    d[i] = d[i] == 0 ? 1 : 0;
  }
  return d;
}

/// Percentil aproximado (por histograma) de los valores de [values].
/// Si [skipZeros] es true se ignoran los ceros.
double percentile(Float32List values, double p, {bool skipZeros = false}) {
  var maxV = 0.0;
  for (final v in values) {
    if (v > maxV) maxV = v;
  }
  if (maxV <= 0) return 0;
  const bins = 4096;
  final hist = Int32List(bins);
  var count = 0;
  final scale = (bins - 1) / maxV;
  for (final v in values) {
    if (skipZeros && v <= 0) continue;
    hist[(v * scale).toInt()]++;
    count++;
  }
  if (count == 0) return 0;
  final target = (p.clamp(0.0, 1.0) * (count - 1)).round();
  var acc = 0;
  for (var i = 0; i < bins; i++) {
    acc += hist[i];
    if (acc > target) return i / scale;
  }
  return maxV;
}

/// Umbral de Otsu para un plano de 8 bits.
int otsuThreshold(Uint8List plane) {
  final hist = Int32List(256);
  for (final v in plane) {
    hist[v]++;
  }
  final total = plane.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0;
  var wB = 0;
  var best = 0.0;
  var thr = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      thr = t;
    }
  }
  return thr;
}
