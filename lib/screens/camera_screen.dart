import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../processing/codec.dart';
import '../processing/document_detector.dart';
import '../processing/document_tracker.dart';
import '../processing/frame_converter.dart';
import '../processing/geometry.dart';
import '../processing/image_ops.dart';
import '../services/app_prefs.dart';

/// Lo que devuelve la cámara a la sesión de escaneo.
class CameraResult {
  const CameraResult({
    this.shots = const [],
    this.batch = false,
    this.openGallery = false,
    this.useSystemCamera = false,
  });

  /// Fotos tomadas (rutas JPEG a resolución completa).
  final List<String> shots;

  /// Modo lote: las fotos se procesan automáticamente sin pasar por recorte.
  final bool batch;

  /// El usuario pulsó "Galería" desde la cámara.
  final bool openGallery;

  /// La cámara integrada no está disponible: usar la app de cámara del
  /// sistema (sin detección en vivo).
  final bool useSystemCamera;
}

/// Detección en un isolate sobre el frame reducido (modo rápido).
({List<double> quad, double confidence})? _detectFrame(RgbImage img) {
  final r = const DocumentDetector(
    workSize: 320,
    minConfidence: 0.5,
    fast: true,
  ).detect(img);
  if (r == null) return null;
  return (
    quad: r.quad.scale(1 / img.width, 1 / img.height).toList(),
    confidence: r.confidence,
  );
}

// Los closures de Isolate.run se crean en funciones de nivel superior: dentro
// de un método del State capturarían `this` (y todo el árbol de widgets), que
// no se puede enviar a otro isolate.
Future<({List<double> quad, double confidence})?> _runDetection(
  RgbImage frame,
) => Isolate.run(() => _detectFrame(frame));

Future<RgbImage> _loadPreviewFrame(String path) => Isolate.run(
  () => limitSize(decodeToRgb(File(path).readAsBytesSync())!, 360),
);

/// Cámara con detección del documento en tiempo real:
///  * dibuja el contorno del documento sobre la vista previa,
///  * dispara sola cuando el documento está quieto (opcional),
///  * modo lote para escanear varias páginas seguidas,
///  * flash / linterna y enfoque tocando la pantalla.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, @visibleForTesting this.debugPreviewImage});

  /// Sólo para tests/capturas: usa esta foto como "vista previa" en lugar de
  /// la cámara, pasando por el mismo detector y la misma interfaz.
  final String? debugPreviewImage;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  CameraDescription? _camera;
  String? _error;
  bool _initializing = true;

  final DocumentTracker _tracker = DocumentTracker();
  bool _streaming = false;
  bool _detecting = false;
  bool _capturing = false;
  bool _flashOverlay = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  bool _auto = AppPrefs.autoCapture;
  bool _batch = AppPrefs.batchMode;
  String _flash = AppPrefs.flash;
  final List<String> _shots = [];
  Offset? _focusPoint;

  /// En iOS el stream va a la resolución máxima del sensor: se piden los
  /// frames de uno en uno (parar/reanudar es barato allí). En Android se
  /// mantiene el stream continuo y se descartan frames mientras se procesa,
  /// porque parar el stream reconfigura la cámara.
  bool get _throttled => Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(const []);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (state == AppLifecycleState.inactive) {
      if (c == null) return;
      _controller = null;
      _streaming = false;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed &&
        _controller == null &&
        !_initializing) {
      // (El diálogo de permiso de iOS provoca inactive→resumed durante la
      // inicialización: no se lanza una segunda en paralelo.)
      _init();
    }
  }

  Future<void> _init() async {
    if (!_initializing || _error != null) {
      setState(() {
        _initializing = true;
        _error = null;
      });
    }
    final debugImage = widget.debugPreviewImage;
    if (debugImage != null) {
      await _initDebugPreview(debugImage);
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('noCamera', 'No se encontró ninguna cámara');
      }
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        _camera!,
        // Foto a la máxima resolución del sensor (calidad del documento).
        // En Android CameraX limita sola la resolución del stream de análisis.
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await _ignoreErrors(
        () => controller.lockCaptureOrientation(DeviceOrientation.portraitUp),
      );
      await _ignoreErrors(() => controller.setFocusMode(FocusMode.auto));
      await _ignoreErrors(() => controller.setFlashMode(_flashMode(_flash)));
      _controller = controller;
      _tracker.reset();
      setState(() => _initializing = false);
      await _startStream();
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = _describe(e);
        });
      }
    }
  }

  RgbImage? _debugFrame;

  Future<void> _initDebugPreview(String path) async {
    final frame = await _loadPreviewFrame(path);
    _debugFrame = frame;
    final r = await _runDetection(frame);
    for (var i = 0; i < 3; i++) {
      _tracker.update(
        r == null ? null : Quad.fromList(r.quad),
        confidence: r?.confidence ?? 0,
      );
    }
    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _ignoreErrors(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  String _describe(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
      case 'cameraPermission':
        return 'Sin permiso para usar la cámara.\n'
            'Actívalo en Ajustes → Aplicaciones → Escáner PDF → Permisos.';
      case 'noCamera':
        return 'Este dispositivo no tiene cámara.';
      default:
        return 'No se pudo abrir la cámara (${e.description ?? e.code}).';
    }
  }

  FlashMode _flashMode(String f) => switch (f) {
    'auto' => FlashMode.auto,
    'torch' => FlashMode.torch,
    _ => FlashMode.off,
  };

  // -------------------------------------------------------------------------
  // Stream y detección
  // -------------------------------------------------------------------------

  Future<void> _startStream() async {
    final c = _controller;
    if (c == null || _streaming || !c.value.isInitialized) return;
    _streaming = true;
    try {
      await c.startImageStream(_onFrame);
    } catch (_) {
      _streaming = false;
    }
  }

  Future<void> _stopStream() async {
    final c = _controller;
    if (c == null || !_streaming) return;
    _streaming = false;
    await _ignoreErrors(c.stopImageStream);
  }

  void _onFrame(CameraImage image) {
    if (_detecting || _capturing || !mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < const Duration(milliseconds: 100)) return;
    _lastFrame = now;

    final format = switch (image.format.group) {
      ImageFormatGroup.yuv420 => FrameFormat.yuv420,
      ImageFormatGroup.nv21 => FrameFormat.nv21,
      ImageFormatGroup.bgra8888 => FrameFormat.bgra8888,
      _ => null,
    };
    if (format == null || image.planes.isEmpty) return;
    // Los frames llegan en la orientación del sensor (apaisados): se giran
    // para que coincidan con la vista previa en vertical.
    final rawLandscape = image.width > image.height;
    final turns = rawLandscape
        ? ((_camera?.sensorOrientation ?? 90) == 270 ? 3 : 1)
        : 0;

    _detecting = true;
    final RgbImage small;
    try {
      small = frameToRgb(
        format: format,
        width: image.width,
        height: image.height,
        planes: [
          for (final p in image.planes)
            FramePlane(p.bytes, p.bytesPerRow, p.bytesPerPixel ?? 1),
        ],
        targetLongSide: 360,
        quarterTurns: turns,
      );
    } catch (_) {
      _detecting = false;
      return;
    }
    if (_throttled) unawaited(_stopStream());
    unawaited(_detect(small));
  }

  Future<void> _detect(RgbImage small) async {
    try {
      final r = await _runDetection(small);
      if (!mounted) return;
      final c = _controller;
      Quad? quad;
      if (r != null && c != null && c.value.isInitialized) {
        final previewAspect = 1 / c.value.aspectRatio; // vertical: ancho/alto
        quad = mapFrameToPreview(
          Quad.fromList(r.quad),
          small.width / small.height,
          previewAspect,
        );
      }
      _tracker.update(quad, confidence: r?.confidence ?? 0);
      setState(() {});
      if (_auto && _tracker.shouldCapture && !_capturing) {
        unawaited(_capture());
      }
    } catch (_) {
      // Un frame fallido no importa: llegará otro.
    } finally {
      _detecting = false;
      if (_throttled && mounted && !_capturing) unawaited(_startStream());
    }
  }

  // -------------------------------------------------------------------------
  // Captura
  // -------------------------------------------------------------------------

  Future<void> _capture() async {
    final c = _controller;
    if (c == null ||
        _capturing ||
        !c.value.isInitialized ||
        c.value.isTakingPicture) {
      return;
    }
    setState(() => _capturing = true);
    try {
      if (_throttled) await _stopStream();
      unawaited(HapticFeedback.mediumImpact());
      final file = await c.takePicture();
      _tracker.markCaptured();
      _shots.add(file.path);
      if (!_batch) {
        _finish();
        return;
      }
      setState(() => _flashOverlay = true);
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (mounted) setState(() => _flashOverlay = false);
    } on CameraException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo hacer la foto: ${e.description}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _capturing = false);
        if (_throttled) unawaited(_startStream());
      }
    }
  }

  void _finish({bool openGallery = false}) {
    Navigator.of(context).pop(
      CameraResult(
        shots: List.of(_shots),
        batch: _batch,
        openGallery: openGallery,
      ),
    );
  }

  Future<void> _toggleFlash() async {
    const order = ['off', 'auto', 'torch'];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    setState(() => _flash = next);
    AppPrefs.flash = next;
    final c = _controller;
    if (c != null) await _ignoreErrors(() => c.setFlashMode(_flashMode(next)));
  }

  Future<void> _focusAt(Offset local, Size size) async {
    final c = _controller;
    if (c == null) return;
    final p = Offset(local.dx / size.width, local.dy / size.height);
    setState(() => _focusPoint = local);
    await _ignoreErrors(() => c.setFocusPoint(p));
    await _ignoreErrors(() => c.setExposurePoint(p));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (mounted) setState(() => _focusPoint = null);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  String get _hint {
    if (_capturing) return 'Capturando…';
    switch (_tracker.state) {
      case TrackingState.searching:
        return 'Apunta al documento';
      case TrackingState.tooSmall:
        return 'Acércate más';
      case TrackingState.moving:
        return _auto ? 'No te muevas…' : 'Documento detectado';
      case TrackingState.stable:
        if (_auto && !_tracker.shouldCapture) return 'Cambia de página';
        return _auto ? 'Capturando…' : 'Listo: pulsa el botón';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _shots.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(); // con fotos en lote, "atrás" las conserva
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(child: Center(child: _buildPreview(scheme))),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error == null ? _hint : '',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
              _buildBottomBar(scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final flashIcon = switch (_flash) {
      'auto' => Icons.flash_auto,
      'torch' => Icons.flashlight_on,
      _ => Icons.flash_off,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cerrar',
            color: Colors.white,
            onPressed: () =>
                _shots.isEmpty ? Navigator.of(context).pop() : _finish(),
            icon: const Icon(Icons.close),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Flash',
            color: Colors.white,
            onPressed: _controller == null ? null : _toggleFlash,
            icon: Icon(flashIcon),
          ),
          _ToggleChip(
            label: 'Auto',
            selected: _auto,
            onTap: () {
              setState(() => _auto = !_auto);
              AppPrefs.autoCapture = _auto;
            },
          ),
          const SizedBox(width: 6),
          _ToggleChip(
            label: _batch ? 'Lote' : '1 pág.',
            selected: _batch,
            onTap: () {
              setState(() => _batch = !_batch);
              AppPrefs.batchMode = _batch;
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildPreview(ColorScheme scheme) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .pop(const CameraResult(useSystemCamera: true)),
              child: const Text('Usar la cámara del sistema'),
            ),
          ],
        ),
      );
    }
    final debugImage = widget.debugPreviewImage;
    final debugFrame = _debugFrame;
    if (debugImage != null && debugFrame != null) {
      return AspectRatio(
        aspectRatio: debugFrame.width / debugFrame.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(File(debugImage), fit: BoxFit.fill),
            _buildOverlay(scheme),
          ],
        ),
      );
    }
    final c = _controller;
    if (_initializing || c == null || !c.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return CameraPreview(c, child: _buildOverlay(scheme));
  }

  Widget _buildOverlay(ColorScheme scheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _focusAt(d.localPosition, size),
          child: Stack(
            fit: StackFit.expand,
            children: [
              TweenAnimationBuilder<Quad?>(
                tween: _QuadTween(end: _tracker.quad),
                duration: const Duration(milliseconds: 160),
                builder: (context, quad, _) => CustomPaint(
                  painter: _LiveOverlayPainter(
                    quad: quad,
                    state: _tracker.state,
                    progress: _auto ? _tracker.progress : 0,
                    color: scheme.primary,
                  ),
                ),
              ),
              if (_focusPoint != null)
                Positioned(
                  left: _focusPoint!.dx - 32,
                  top: _focusPoint!.dy - 32,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.amber, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _flashOverlay ? 0.7 : 0,
                  duration: const Duration(milliseconds: 90),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(ColorScheme scheme) {
    final ready = _controller != null || _debugFrame != null;
    final canShoot = ready && !_capturing && _error == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: IconButton(
              tooltip: 'Galería',
              color: Colors.white,
              iconSize: 30,
              onPressed: () => _finish(openGallery: true),
              icon: const Icon(Icons.photo_library_outlined),
            ),
          ),
          const Spacer(),
          _ShutterButton(
            enabled: canShoot,
            busy: _capturing,
            progress: _auto ? _tracker.progress : 0,
            color: scheme.primary,
            onTap: _capture,
          ),
          const Spacer(),
          SizedBox(
            width: 72,
            child: _shots.isEmpty
                ? null
                : _BatchThumb(
                    path: _shots.last,
                    count: _shots.length,
                    onTap: _finish,
                  ),
          ),
        ],
      ),
    );
  }
}

class _QuadTween extends Tween<Quad?> {
  _QuadTween({super.end});

  @override
  Quad? lerp(double t) {
    final a = begin, b = end;
    if (a == null || b == null) return b;
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

class _LiveOverlayPainter extends CustomPainter {
  _LiveOverlayPainter({
    required this.quad,
    required this.state,
    required this.progress,
    required this.color,
  });

  final Quad? quad;
  final TrackingState state;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final q = quad;
    if (q == null) return;
    final pts = [
      for (final p in q.points) Offset(p.x * size.width, p.y * size.height),
    ];
    final path = Path()..addPolygon(pts, true);
    final c = switch (state) {
      TrackingState.stable => color,
      TrackingState.tooSmall => Colors.amber,
      _ => Colors.white,
    };
    canvas.drawPath(path, Paint()..color = c.withValues(alpha: 0.22));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = c,
    );
    for (final p in pts) {
      canvas.drawCircle(p, 7, Paint()..color = c);
      canvas.drawCircle(
        p,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveOverlayPainter old) =>
      old.quad != quad ||
      old.state != state ||
      old.progress != progress ||
      old.color != color;
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.enabled,
    required this.busy,
    required this.progress,
    required this.color,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final double progress;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Hacer foto',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  value: busy ? null : progress,
                  strokeWidth: 4,
                  color: color,
                  backgroundColor: Colors.white24,
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: busy ? 52 : 62,
                height: busy ? 52 : 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled ? Colors.white : Colors.white38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : Colors.white12,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? scheme.onPrimary : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchThumb extends StatelessWidget {
  const _BatchThumb({
    required this.path,
    required this.count,
    required this.onTap,
  });

  final String path;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Badge(
            label: Text('$count'),
            backgroundColor: scheme.primary,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(path),
                width: 48,
                height: 64,
                fit: BoxFit.cover,
                cacheWidth: 144,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Listo',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
