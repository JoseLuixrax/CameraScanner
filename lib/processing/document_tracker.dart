import 'dart:math' as math;

import 'geometry.dart';

/// Estado del seguimiento del documento en la vista de cámara.
enum TrackingState {
  /// No se ve ningún documento.
  searching,

  /// Se ve un documento pero es pequeño (hay que acercarse).
  tooSmall,

  /// Documento detectado pero la imagen aún se mueve.
  moving,

  /// Documento estable: listo para disparar.
  stable,
}

/// Suaviza las detecciones sucesivas (que tiemblan unos píxeles) y decide
/// cuándo el documento está lo bastante quieto para el disparo automático.
///
/// Trabaja con cuadriláteros normalizados (0..1) en la orientación de la
/// vista previa.
class DocumentTracker {
  DocumentTracker({
    this.framesToStable = 4,
    this.stableThreshold = 0.025,
    this.minArea = 0.15,
    this.minConfidence = 0.55,
    this.lostFrames = 3,
    this.smoothing = 0.55,
  });

  /// Detecciones consecutivas sin moverse necesarias para disparar.
  final int framesToStable;

  /// Movimiento máximo de una esquina (fracción del encuadre) para
  /// considerar que la imagen está quieta.
  final double stableThreshold;

  /// Área mínima del documento (fracción del encuadre).
  final double minArea;
  final double minConfidence;

  /// Frames sin detección antes de dar el documento por perdido.
  final int lostFrames;

  /// Peso de la nueva detección en el suavizado (0..1).
  final double smoothing;

  Quad? _quad;
  int _stableCount = 0;
  int _missing = 0;
  bool _armed = true;

  /// Cuadrilátero suavizado para dibujar (o `null`).
  Quad? get quad => _quad;

  /// Progreso del disparo automático (0..1).
  double get progress => (_stableCount / framesToStable).clamp(0.0, 1.0);

  TrackingState _state = TrackingState.searching;
  TrackingState get state => _state;

  /// `true` cuando conviene disparar: documento estable y el disparador
  /// "armado" (tras cada disparo hay que mover o cambiar la hoja).
  bool get shouldCapture => _armed && _state == TrackingState.stable;

  /// Registra una nueva detección ([detected] = null si no se encontró).
  TrackingState update(Quad? detected, {double confidence = 1}) {
    if (detected == null || confidence < minConfidence) {
      _missing++;
      _stableCount = 0;
      if (_missing >= lostFrames) {
        _quad = null;
        _armed =
            true; // la hoja ha salido de cuadro: se puede volver a disparar
        _state = TrackingState.searching;
      } else if (_quad != null) {
        _state = TrackingState.moving;
      }
      return _state;
    }
    _missing = 0;
    final prev = _quad;
    if (prev == null) {
      _quad = detected;
      _stableCount = 1;
    } else {
      final move = _maxCornerDistance(prev, detected);
      if (move > 0.15) {
        // Salto grande: otra hoja u otro encuadre.
        _quad = detected;
        _stableCount = 1;
        _armed = true;
      } else {
        _quad = _lerp(prev, detected, smoothing);
        if (move <= stableThreshold) {
          _stableCount++;
        } else if (move <= stableThreshold * 2) {
          // Pequeño temblor: no reinicia del todo.
          _stableCount = math.max(0, _stableCount - 1);
        } else {
          _stableCount = 0;
        }
      }
    }
    if (_quad!.area < minArea) {
      _stableCount = 0;
      _state = TrackingState.tooSmall;
    } else if (_stableCount >= framesToStable) {
      _state = TrackingState.stable;
    } else {
      _state = TrackingState.moving;
    }
    return _state;
  }

  /// Llamar tras un disparo: no se vuelve a disparar automáticamente hasta
  /// que la hoja se mueva o salga del encuadre (útil en modo lote).
  void markCaptured() {
    _armed = false;
    _stableCount = 0;
  }

  void reset() {
    _quad = null;
    _stableCount = 0;
    _missing = 0;
    _armed = true;
    _state = TrackingState.searching;
  }

  static double _maxCornerDistance(Quad a, Quad b) {
    var m = 0.0;
    for (var i = 0; i < 4; i++) {
      m = math.max(m, a.points[i].distanceTo(b.points[i]));
    }
    return m;
  }

  static Quad _lerp(Quad a, Quad b, double t) {
    final pa = a.points, pb = b.points;
    return Quad.fromPoints([
      for (var i = 0; i < 4; i++)
        Pt(
          pa[i].x + (pb[i].x - pa[i].x) * t,
          pa[i].y + (pb[i].y - pa[i].y) * t,
        ),
    ]);
  }
}

/// Traslada un cuadrilátero normalizado del encuadre del frame de análisis
/// al de la vista previa, cuando ambos tienen distinta relación de aspecto.
///
/// Los dos streams son recortes centrados del mismo sensor que conservan el
/// lado largo (vertical en retrato); sólo difiere el ancho visible.
/// [frameAspect] y [previewAspect] son ancho/alto en retrato.
Quad mapFrameToPreview(Quad q, double frameAspect, double previewAspect) {
  if ((frameAspect - previewAspect).abs() < 1e-3) return q;
  final k = frameAspect / previewAspect;
  return q.map((p) => Pt((p.x - 0.5) * k + 0.5, p.y));
}
