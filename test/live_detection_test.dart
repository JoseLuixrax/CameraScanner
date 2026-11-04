import 'dart:typed_data';

import 'package:camera_scanner/processing/document_detector.dart';
import 'package:camera_scanner/processing/document_tracker.dart';
import 'package:camera_scanner/processing/frame_converter.dart';
import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/processing/image_ops.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/synthetic.dart';

/// Frame de sensor: la foto "vertical" girada 90° a la izquierda (así es como
/// la entrega el sensor trasero de casi todos los móviles en retrato).
RgbImage _sensorFrame(RgbImage portrait) => rotate90(portrait, 3);

({List<FramePlane> planes}) _toYuv420ThreePlanes(RgbImage img) {
  // Como CameraX: filas con padding y U/V "semi-planares" (pixelStride 2).
  final w = img.width, h = img.height;
  final yRow = w + 16;
  final y = Uint8List(yRow * h);
  final cw = (w + 1) ~/ 2, ch = (h + 1) ~/ 2;
  final cRow = cw * 2 + 8;
  final uv = Uint8List(cRow * ch + 1);
  for (var py = 0; py < h; py++) {
    for (var px = 0; px < w; px++) {
      final i = (py * w + px) * 3;
      final r = img.data[i], g = img.data[i + 1], b = img.data[i + 2];
      y[py * yRow + px] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(
        0,
        255,
      );
      if (py.isEven && px.isEven) {
        final u = (-0.168736 * r - 0.331264 * g + 0.5 * b + 128).round().clamp(
          0,
          255,
        );
        final v = (0.5 * r - 0.418688 * g - 0.081312 * b + 128).round().clamp(
          0,
          255,
        );
        final ci = (py ~/ 2) * cRow + (px ~/ 2) * 2;
        uv[ci] = u;
        uv[ci + 1] = v;
      }
    }
  }
  // Plano U empieza en uv[0], plano V en uv[1] (mismo buffer intercalado).
  final uPlane = uv;
  final vPlane = Uint8List.sublistView(uv, 1);
  return (
    planes: [
      FramePlane(y, yRow),
      FramePlane(uPlane, cRow, 2),
      FramePlane(vPlane, cRow, 2),
    ],
  );
}

List<FramePlane> _toNv(RgbImage img, {required bool nv21}) {
  final w = img.width, h = img.height;
  final out = Uint8List(w * h + w * ((h + 1) ~/ 2) + 2);
  for (var py = 0; py < h; py++) {
    for (var px = 0; px < w; px++) {
      final i = (py * w + px) * 3;
      final r = img.data[i], g = img.data[i + 1], b = img.data[i + 2];
      out[py * w + px] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(
        0,
        255,
      );
      if (py.isEven && px.isEven) {
        final u = (-0.168736 * r - 0.331264 * g + 0.5 * b + 128).round().clamp(
          0,
          255,
        );
        final v = (0.5 * r - 0.418688 * g - 0.081312 * b + 128).round().clamp(
          0,
          255,
        );
        final ci = w * h + (py ~/ 2) * w + px;
        out[ci] = nv21 ? v : u;
        out[ci + 1] = nv21 ? u : v;
      }
    }
  }
  if (nv21) return [FramePlane(out, w)];
  // NV12 (iOS yuv420 biplanar): plano Y + plano CbCr.
  return [
    FramePlane(Uint8List.sublistView(out, 0, w * h), w),
    FramePlane(Uint8List.sublistView(out, w * h), w, 2),
  ];
}

List<FramePlane> _toBgra(RgbImage img) {
  final row = img.width * 4 + 64;
  final out = Uint8List(row * img.height);
  for (var py = 0; py < img.height; py++) {
    for (var px = 0; px < img.width; px++) {
      final i = (py * img.width + px) * 3;
      final o = py * row + px * 4;
      out[o] = img.data[i + 2];
      out[o + 1] = img.data[i + 1];
      out[o + 2] = img.data[i];
      out[o + 3] = 255;
    }
  }
  return [FramePlane(out, row, 4)];
}

void main() {
  // Foto vertical 1080x1440 (4:3) con el documento.
  const truth = Quad(Pt(190, 230), Pt(880, 270), Pt(940, 1250), Pt(120, 1290));
  final portrait = syntheticPhoto(width: 1080, height: 1440, corners: truth);
  final sensor = _sensorFrame(portrait); // 1440x1080, apaisado
  final truthNorm = truth.scale(1 / 1080, 1 / 1440);
  const detector = DocumentDetector(workSize: 320, minConfidence: 0.5);

  void expectDetects(RgbImage small) {
    // El frame convertido debe volver a estar en vertical.
    expect(small.height, greaterThan(small.width));
    final r = detector.detect(small)!;
    final norm = r.quad.scale(1 / small.width, 1 / small.height);
    expect(maxCornerError(norm, truthNorm), lessThan(0.02));
  }

  test('YUV420 de 3 planos (Android/CameraX) con padding y rotación', () {
    final yuv = _toYuv420ThreePlanes(sensor);
    final sw = Stopwatch()..start();
    final small = frameToRgb(
      format: FrameFormat.yuv420,
      width: sensor.width,
      height: sensor.height,
      planes: yuv.planes,
      quarterTurns: 1,
    );
    final tConvert = sw.elapsedMicroseconds;
    sw.reset();
    expectDetects(small);
    // ignore: avoid_print
    print(
      'frame ${small.width}x${small.height}: conversión '
      '${(tConvert / 1000).toStringAsFixed(1)} ms, detección '
      '${sw.elapsedMilliseconds} ms',
    );
  });

  test('NV21 (Android) y NV12 (iOS yuv420)', () {
    for (final nv21 in [true, false]) {
      final small = frameToRgb(
        format: nv21 ? FrameFormat.nv21 : FrameFormat.yuv420,
        width: sensor.width,
        height: sensor.height,
        planes: _toNv(sensor, nv21: nv21),
        quarterTurns: 1,
      );
      expectDetects(small);
    }
  });

  test('BGRA8888 (iOS) con bytesPerRow > ancho', () {
    final small = frameToRgb(
      format: FrameFormat.bgra8888,
      width: sensor.width,
      height: sensor.height,
      planes: _toBgra(sensor),
      quarterTurns: 1,
    );
    expectDetects(small);
  });

  test('los colores se conservan en la conversión YUV', () {
    final img = RgbImage(64, 64);
    for (var i = 0; i < img.pixelCount; i++) {
      img.data.setAll(i * 3, [30, 80, 170]); // azul
    }
    final small = frameToRgb(
      format: FrameFormat.yuv420,
      width: 64,
      height: 64,
      planes: _toYuv420ThreePlanes(img).planes,
      targetLongSide: 16,
    );
    expect(small.width, 16);
    expect(small.data[0], closeTo(30, 4));
    expect(small.data[1], closeTo(80, 4));
    expect(small.data[2], closeTo(170, 4));
  });

  group('DocumentTracker', () {
    const q = Quad(Pt(0.1, 0.1), Pt(0.9, 0.12), Pt(0.88, 0.9), Pt(0.12, 0.88));
    Quad jitter(double d) => q.map((p) => Pt(p.x + d, p.y - d));

    test('se estabiliza tras varias detecciones quietas', () {
      final t = DocumentTracker(framesToStable: 4);
      expect(t.update(q), TrackingState.moving);
      t.update(jitter(0.004));
      t.update(jitter(-0.003));
      expect(t.shouldCapture, isFalse);
      expect(t.update(jitter(0.002)), TrackingState.stable);
      expect(t.shouldCapture, isTrue);
      expect(t.progress, 1);
    });

    test('el movimiento reinicia la cuenta', () {
      final t = DocumentTracker(framesToStable: 3);
      t.update(q);
      t.update(q);
      t.update(jitter(0.08)); // se ha movido
      expect(t.state, TrackingState.moving);
      expect(t.progress, lessThan(0.5));
    });

    test('documento pequeño → hay que acercarse', () {
      final t = DocumentTracker();
      const small = Quad(
        Pt(0.4, 0.4),
        Pt(0.6, 0.4),
        Pt(0.6, 0.6),
        Pt(0.4, 0.6),
      );
      expect(t.update(small), TrackingState.tooSmall);
    });

    test('tras disparar no repite hasta que cambia la hoja', () {
      final t = DocumentTracker(framesToStable: 2, lostFrames: 2);
      t.update(q);
      t.update(q);
      expect(t.shouldCapture, isTrue);
      t.markCaptured();
      t.update(q);
      t.update(q);
      expect(t.state, TrackingState.stable);
      expect(t.shouldCapture, isFalse); // misma hoja
      // La hoja sale del encuadre y entra otra.
      t.update(null);
      expect(t.update(null), TrackingState.searching);
      t.update(q);
      t.update(q);
      expect(t.shouldCapture, isTrue);
    });

    test('baja confianza cuenta como no detectado', () {
      final t = DocumentTracker(lostFrames: 1);
      t.update(q);
      expect(t.update(q, confidence: 0.2), TrackingState.searching);
      expect(t.quad, isNull);
    });
  });

  test('mapFrameToPreview ajusta el ancho visible', () {
    // Frame 3:4 y vista previa 9:16 (más estrecha): los bordes del frame
    // quedan fuera de la vista previa.
    final m = mapFrameToPreview(Quad.rect(1, 1), 3 / 4, 9 / 16);
    expect(m.tl.x, closeTo(0.5 - 0.5 * (0.75 / 0.5625), 1e-9));
    expect(m.tl.y, 0);
    expect(m.br.y, 1);
    expect(
      mapFrameToPreview(Quad.rect(1, 1), 0.75, 0.75).points,
      Quad.rect(1, 1).points,
    );
  });
}
