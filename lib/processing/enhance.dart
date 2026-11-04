import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

/// Filtros de mejora disponibles.
enum ScanFilter {
  /// Imagen recortada sin tocar el color.
  original('Original'),

  /// Elimina sombras, blanquea el papel y realza texto conservando el color.
  magicColor('Mejorado'),

  /// Igual que "Mejorado" pero en escala de grises.
  grayscale('Grises'),

  /// Binarización adaptativa: máximo contraste para texto.
  blackWhite('B/N');

  const ScanFilter(this.label);

  final String label;

  static ScanFilter fromName(String? name) => ScanFilter.values.firstWhere(
    (f) => f.name == name,
    orElse: () => ScanFilter.magicColor,
  );
}

/// Aplica [filter] a [img]. Devuelve una imagen nueva (o la misma si es
/// [ScanFilter.original]).
RgbImage applyFilter(RgbImage img, ScanFilter filter) {
  switch (filter) {
    case ScanFilter.original:
      return img;
    case ScanFilter.magicColor:
      return _magicColor(img);
    case ScanFilter.grayscale:
      return _grayscale(img);
    case ScanFilter.blackWhite:
      return _blackWhite(img);
  }
}

// ---------------------------------------------------------------------------
// Estimación del fondo (iluminación del papel)
// ---------------------------------------------------------------------------

/// Mapa de baja resolución con el nivel de "papel" estimado en cada zona.
class _Background {
  _Background(this.data, this.bw, this.bh, this.w, this.h);

  final Float32List data;
  final int bw;
  final int bh;
  final int w;
  final int h;

  /// Interpolación bilineal por filas (precalcula índices de columna).
  late final Int32List _x0 = Int32List(w);
  late final Int32List _x1 = Int32List(w);
  late final Float32List _fx = Float32List(w);
  bool _prepared = false;

  void _prepare() {
    if (_prepared) return;
    for (var x = 0; x < w; x++) {
      final gxp = ((x + 0.5) * bw / w - 0.5).clamp(0.0, bw - 1.0);
      final x0 = gxp.floor();
      _x0[x] = x0;
      _x1[x] = math.min(bw - 1, x0 + 1);
      _fx[x] = gxp - x0;
    }
    _prepared = true;
  }

  /// Rellena [row] (longitud w) con el fondo interpolado de la fila [y].
  void fillRow(int y, Float32List row) {
    _prepare();
    final gyp = ((y + 0.5) * bh / h - 0.5).clamp(0.0, bh - 1.0);
    final y0 = gyp.floor();
    final y1 = math.min(bh - 1, y0 + 1);
    final fy = gyp - y0;
    final r0 = y0 * bw, r1 = y1 * bw;
    for (var x = 0; x < w; x++) {
      final fx = _fx[x];
      final a = data[r0 + _x0[x]] * (1 - fx) + data[r0 + _x1[x]] * fx;
      final b = data[r1 + _x0[x]] * (1 - fx) + data[r1 + _x1[x]] * fx;
      row[x] = a * (1 - fy) + b * fy;
    }
  }
}

/// Estima el nivel del papel (iluminación) de un plano de 8 bits:
///  1. Máximo por bloques de los promedios 2x2 → elimina el texto.
///  2. Las celdas mucho más oscuras que el papel cercano (recuadros de color,
///     fotos, titulares muy gruesos) se marcan como "no papel" y se rellenan
///     por difusión desde las vecinas (inpainting), para no blanquearlas.
///  3. Dilatación 3x3 + suavizado gaussiano.
_Background _estimateBackground(Uint8List plane, int w, int h) {
  final long = math.max(w, h);
  final bs = math.max(6, (long / 80).ceil());
  final bw = math.max(1, (w / bs).ceil());
  final bh = math.max(1, (h / bs).ceil());
  final grid = Float32List(bw * bh);
  for (var y = 0; y + 1 < h; y += 2) {
    final gyi = math.min(bh - 1, y ~/ bs) * bw;
    final r0 = y * w, r1 = (y + 1) * w;
    for (var x = 0; x + 1 < w; x += 2) {
      final v =
          (plane[r0 + x] +
              plane[r0 + x + 1] +
              plane[r1 + x] +
              plane[r1 + x + 1]) *
          0.25;
      final gi = gyi + math.min<int>(bw - 1, x ~/ bs);
      if (v > grid[gi]) grid[gi] = v;
    }
  }

  final known = _classifyPaperCells(grid, bw, bh);
  var unknown = 0;
  for (final k in known) {
    if (k == 0) unknown++;
  }
  // Inpainting por frentes de onda: cada celda desconocida toma la media de
  // sus vecinas ya conocidas.
  final next = Uint8List(bw * bh);
  while (unknown > 0) {
    var filled = 0;
    next.setAll(0, known);
    for (var y = 0; y < bh; y++) {
      for (var x = 0; x < bw; x++) {
        final i = y * bw + x;
        if (known[i] != 0) continue;
        var sum = 0.0;
        var cnt = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= bh) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= bw) continue;
            final j = yy * bw + xx;
            if (known[j] != 0) {
              sum += grid[j];
              cnt++;
            }
          }
        }
        if (cnt > 0) {
          grid[i] = sum / cnt;
          next[i] = 1;
          filled++;
        }
      }
    }
    if (filled == 0) break;
    known.setAll(0, next);
    unknown -= filled;
  }

  final smooth = gaussianBlur(_gridMaxFilter(grid, bw, bh, 1), bw, bh, 1.2);
  // Evita amplificar demasiado zonas muy oscuras.
  final paper = percentile(smooth, 0.95);
  final floor = math.max(24.0, paper * 0.35);
  for (var i = 0; i < smooth.length; i++) {
    if (smooth[i] < floor) smooth[i] = floor;
  }
  return _Background(smooth, bw, bh, w, h);
}

/// Marca con 1 las celdas que son papel (aunque estén en sombra) y con 0 las
/// que pertenecen a contenido oscuro grande: fotos, recuadros, logotipos.
///
/// Las sombras tienen bordes suaves (el brillo cambia poco entre celdas
/// vecinas), mientras que una foto impresa tiene un salto brusco. Por eso:
///  * semillas = celdas al menos un 30 % más oscuras que alguna celda a ≤ 2
///    celdas de distancia (borde duro);
///  * cada semilla crece hacia vecinas de brillo parecido (±12 % respecto a
///    la celda desde la que crece, así sigue degradados) que además sean
///    claramente más oscuras que el papel.
Uint8List _classifyPaperCells(Float32List grid, int bw, int bh) {
  final n = bw * bh;
  final known = Uint8List(n)..fillRange(0, n, 1);
  final near = _gridMaxFilter(grid, bw, bh, 2);
  final paper = percentile(grid, 0.9);
  final region = Uint8List(n);
  final queue = Int32List(n);
  var marked = 0;
  for (var s = 0; s < n; s++) {
    if (region[s] != 0 || grid[s] >= 0.7 * near[s]) continue;
    // Crecimiento de región desde la semilla.
    var head = 0, tail = 0;
    queue[tail++] = s;
    region[s] = 1;
    while (head < tail) {
      final i = queue[head++];
      final x = i % bw, y = i ~/ bw;
      final cur = grid[i];
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= bh) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= bw) continue;
          final j = yy * bw + xx;
          if (region[j] != 0) continue;
          final v = grid[j];
          final isSeed = v < 0.7 * near[j];
          final similar = (v - cur).abs() <= 0.12 * cur && v < 0.8 * paper;
          if (isSeed || similar) {
            region[j] = 1;
            queue[tail++] = j;
          }
        }
      }
    }
    for (var q = 0; q < tail; q++) {
      known[queue[q]] = 0;
    }
    marked += tail;
  }
  // Si casi todo es "no papel", la clasificación no es fiable: no se usa.
  if (marked > 0.6 * n) known.fillRange(0, n, 1);
  return known;
}

Float32List _gridMaxFilter(Float32List g, int bw, int bh, int r) {
  final tmp = Float32List(bw * bh);
  final out = Float32List(bw * bh);
  for (var y = 0; y < bh; y++) {
    for (var x = 0; x < bw; x++) {
      var m = 0.0;
      for (var xx = math.max(0, x - r); xx <= math.min(bw - 1, x + r); xx++) {
        final v = g[y * bw + xx];
        if (v > m) m = v;
      }
      tmp[y * bw + x] = m;
    }
  }
  for (var y = 0; y < bh; y++) {
    for (var x = 0; x < bw; x++) {
      var m = 0.0;
      for (var yy = math.max(0, y - r); yy <= math.min(bh - 1, y + r); yy++) {
        final v = tmp[yy * bw + x];
        if (v > m) m = v;
      }
      out[y * bw + x] = m;
    }
  }
  return out;
}

/// Divide la luminancia por su fondo → papel blanco uniforme, sin sombras.
Uint8List _normalizeGray(Uint8List lum, int w, int h) {
  final bg = _estimateBackground(lum, w, h);
  final out = Uint8List(lum.length);
  final row = Float32List(w);
  for (var y = 0; y < h; y++) {
    bg.fillRow(y, row);
    final r = y * w;
    for (var x = 0; x < w; x++) {
      final v = lum[r + x] * 255.0 / row[x];
      out[r + x] = v >= 255 ? 255 : v.toInt();
    }
  }
  return out;
}

/// Normaliza la iluminación en color: misma ganancia local para los tres
/// canales (conserva el tono de sellos, firmas y logotipos) más un balance de
/// blancos global calculado sobre los píxeles de papel.
Uint8List _normalizeColor(RgbImage img) {
  final w = img.width, h = img.height;
  final src = img.data;
  final lum = luminance(img);
  final bg = _estimateBackground(lum, w, h);
  final row = Float32List(w);

  // Balance de blancos: color medio de los píxeles que son papel.
  var sr = 0.0, sg = 0.0, sb = 0.0, sl = 0.0;
  for (var y = 0; y < h; y += 4) {
    bg.fillRow(y, row);
    for (var x = 0; x < w; x += 4) {
      final i = y * w + x;
      if (lum[i] < 0.9 * row[x]) continue;
      sr += src[i * 3];
      sg += src[i * 3 + 1];
      sb += src[i * 3 + 2];
      sl += lum[i];
    }
  }
  double gain(double s) => s <= 0 ? 1.0 : (sl / s).clamp(0.7, 1.4).toDouble();
  final gr = gain(sr), gg = gain(sg), gb = gain(sb);

  final out = Uint8List(src.length);
  for (var y = 0; y < h; y++) {
    bg.fillRow(y, row);
    var i = y * w * 3;
    for (var x = 0; x < w; x++) {
      final k = 255.0 / row[x];
      final r = src[i] * gr * k,
          g = src[i + 1] * gg * k,
          b = src[i + 2] * gb * k;
      out[i] = r >= 255 ? 255 : r.toInt();
      out[i + 1] = g >= 255 ? 255 : g.toInt();
      out[i + 2] = b >= 255 ? 255 : b.toInt();
      i += 3;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

/// Curva tonal: punto negro [black], punto blanco [white] (0..1) y gamma.
Uint8List _toneCurve(double black, double white, double gamma) {
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    var v = (i / 255 - black) / (white - black);
    v = v.clamp(0.0, 1.0);
    v = math.pow(v, gamma).toDouble();
    lut[i] = (v * 255).round();
  }
  return lut;
}

/// Máscara de enfoque (unsharp mask 3x3) in situ seguida de una LUT.
void _sharpenAndMap(
  Uint8List data,
  int w,
  int h,
  int channels,
  double amount,
  Uint8List lut,
) {
  final stride = w * channels;
  // Sumas horizontales de 3 píxeles para las filas y-1, y, y+1.
  Int32List hsum(int y) {
    final out = Int32List(stride);
    final r = y * stride;
    for (var x = 0; x < w; x++) {
      final xl = x > 0 ? x - 1 : 0;
      final xr = x < w - 1 ? x + 1 : w - 1;
      for (var c = 0; c < channels; c++) {
        out[x * channels + c] =
            data[r + xl * channels + c] +
            data[r + x * channels + c] +
            data[r + xr * channels + c];
      }
    }
    return out;
  }

  var prev = hsum(0);
  var cur = prev;
  var next = h > 1 ? hsum(1) : prev;
  for (var y = 0; y < h; y++) {
    final r = y * stride;
    for (var i = 0; i < stride; i++) {
      final v = data[r + i];
      final blur = (prev[i] + cur[i] + next[i]) / 9.0;
      var s = v + amount * (v - blur);
      final si = s <= 0 ? 0 : (s >= 255 ? 255 : s.round());
      data[r + i] = lut[si];
    }
    prev = cur;
    cur = next;
    next = y + 2 < h ? hsum(y + 2) : cur;
  }
}

// ---------------------------------------------------------------------------
// Filtros
// ---------------------------------------------------------------------------

RgbImage _magicColor(RgbImage img) {
  final w = img.width, h = img.height;
  final norm = _normalizeColor(img);
  _sharpenAndMap(norm, w, h, 3, 0.6, _toneCurve(0.06, 0.90, 1.3));
  return RgbImage(w, h, norm);
}

RgbImage _grayscale(RgbImage img) {
  final w = img.width, h = img.height;
  final norm = _normalizeGray(luminance(img), w, h);
  _sharpenAndMap(norm, w, h, 1, 0.7, _toneCurve(0.08, 0.90, 1.5));
  return _grayToRgb(norm, w, h);
}

RgbImage _blackWhite(RgbImage img) {
  final w = img.width, h = img.height;
  final norm = _normalizeGray(luminance(img), w, h);
  // Media local en una rejilla gruesa (umbral adaptativo tipo Bradley).
  final bs = math.max(8, (math.max(w, h) / 60).ceil());
  final bw = math.max(1, (w / bs).ceil());
  final bh = math.max(1, (h / bs).ceil());
  final sums = Float32List(bw * bh);
  final counts = Int32List(bw * bh);
  for (var y = 0; y < h; y++) {
    final gy = (y ~/ bs) * bw;
    final r = y * w;
    for (var x = 0; x < w; x++) {
      final gi = gy + x ~/ bs;
      sums[gi] += norm[r + x];
      counts[gi]++;
    }
  }
  for (var i = 0; i < sums.length; i++) {
    sums[i] = counts[i] > 0 ? sums[i] / counts[i] : 255;
  }
  final mean = _Background(gaussianBlur(sums, bw, bh, 1.0), bw, bh, w, h);
  final row = Float32List(w);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    mean.fillRow(y, row);
    final r = y * w;
    for (var x = 0; x < w; x++) {
      final v = norm[r + x];
      final bool black;
      if (v < 110) {
        black = true; // zonas oscuras grandes (rellenos, fotos)
      } else if (v > 235) {
        black = false;
      } else {
        black = v < row[x] * 0.82;
      }
      out[r + x] = black ? 0 : 255;
    }
  }
  return _grayToRgb(out, w, h);
}

RgbImage _grayToRgb(Uint8List gray, int w, int h) {
  final out = RgbImage(w, h);
  final o = out.data;
  for (var i = 0, j = 0; i < gray.length; i++, j += 3) {
    final v = gray[i];
    o[j] = v;
    o[j + 1] = v;
    o[j + 2] = v;
  }
  return out;
}
