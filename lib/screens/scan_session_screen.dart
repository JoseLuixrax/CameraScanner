import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ocr_line.dart';
import '../models/scan_page.dart';
import '../processing/enhance.dart';
import '../processing/geometry.dart';
import '../processing/pipeline.dart';
import '../services/document_repository.dart';
import '../services/image_service.dart';
import '../services/ocr_service.dart';
import '../services/pdf_service.dart';
import '../widgets/dialogs.dart';
import 'crop_screen.dart';
import 'filter_screen.dart';
import 'pdf_viewer_screen.dart';

/// Documento en construcción: lista de páginas escaneadas.
class ScanSessionScreen extends StatefulWidget {
  const ScanSessionScreen({
    super.key,
    this.initialSource,
    @visibleForTesting this.debugPages,
  });

  /// Si se indica, abre directamente la cámara o la galería al entrar.
  final CaptureSource? initialSource;

  /// Páginas ya procesadas (sólo para tests y capturas de pantalla).
  final List<ScanPage>? debugPages;

  @override
  State<ScanSessionScreen> createState() => _ScanSessionScreenState();
}

class _ScanSessionScreenState extends State<ScanSessionScreen> {
  final List<ScanPage> _pages = [];
  Directory? _workDir;
  ScanFilter _defaultFilter = ScanFilter.magicColor;
  PdfPageSize _pageSize = PdfPageSize.a4;

  /// Cola de renderizado: una página cada vez (limita el uso de memoria).
  Future<void> _renderQueue = Future.value();

  /// Cola de OCR (ML Kit trabaja en nativo; se reconoce una página cada vez).
  Future<void> _ocrQueue = Future.value();
  bool _ocrEnabled = true;
  String? _busyMessage;
  bool _saving = false;
  int _uid = 0;

  @override
  void initState() {
    super.initState();
    _pages.addAll(widget.debugPages ?? const []);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final src = widget.initialSource;
      if (src != null) _capture(src);
    });
  }

  @override
  void dispose() {
    final dir = _workDir;
    if (dir != null) {
      // Se espera a que terminen los trabajos pendientes antes de borrar.
      Future.wait([_renderQueue, _ocrQueue]).whenComplete(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
    }
    super.dispose();
  }

  Future<Directory> _dir() async =>
      _workDir ??= await DocumentRepository.instance.createSessionDir();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------------------------------
  // Captura
  // -------------------------------------------------------------------------

  Future<void> _capture(CaptureSource source) async {
    try {
      if (source == CaptureSource.camera) {
        final path = await ImageService.takePhoto();
        if (path == null) return;
        await _importSingle(path);
      } else {
        final paths = await ImageService.pickFromGallery();
        if (paths.isEmpty) return;
        if (paths.length == 1) {
          await _importSingle(paths.first);
        } else {
          await _importBatch(paths);
        }
      }
    } catch (e) {
      _snack('Error al importar: $e');
    } finally {
      if (mounted) setState(() => _busyMessage = null);
    }
  }

  /// Una imagen: se pasa por las pantallas de recorte y filtro.
  Future<void> _importSingle(String path) async {
    setState(() => _busyMessage = 'Detectando bordes…');
    final info = await ImageService.prepare(path, await _dir());
    if (!mounted) return;
    setState(() => _busyMessage = null);
    final page = _newPage(info);
    final edited = await _editFlow(page);
    if (!edited) {
      File(info.path).deleteSync();
      return;
    }
    setState(() => _pages.add(page));
    _enqueueRender(page);
  }

  /// Varias imágenes: se recortan automáticamente; luego se pueden retocar.
  Future<void> _importBatch(List<String> paths) async {
    final dir = await _dir();
    var undetected = 0;
    for (var i = 0; i < paths.length; i++) {
      if (!mounted) return;
      setState(() => _busyMessage = 'Procesando ${i + 1} de ${paths.length}…');
      try {
        final info = await ImageService.prepare(paths[i], dir);
        if (info.detected == null) undetected++;
        final page = _newPage(info);
        if (!mounted) return;
        setState(() => _pages.add(page));
        _enqueueRender(page);
      } catch (e) {
        _snack('No se pudo leer la imagen ${i + 1}: $e');
      }
    }
    if (undetected > 0) {
      _snack(
        undetected == 1
            ? 'En 1 imagen no se detectó el documento: revisa sus bordes.'
            : 'En $undetected imágenes no se detectó el documento: revisa sus bordes.',
      );
    }
  }

  ScanPage _newPage(SourceInfo info) => ScanPage(
    id: 'p${_uid++}',
    sourcePath: info.path,
    sourceWidth: info.width,
    sourceHeight: info.height,
    quad: info.detected ?? Quad.rect(1, 1),
    detectedQuad: info.detected,
    filter: _defaultFilter,
  );

  /// Recorte → filtro. Devuelve `true` si el usuario confirmó.
  Future<bool> _editFlow(ScanPage page) async {
    var quad = page.quad;
    while (true) {
      if (!mounted) return false;
      final q = await Navigator.of(context).push<Quad>(
        MaterialPageRoute(
          builder: (_) => CropScreen(
            imagePath: page.sourcePath,
            imageWidth: page.sourceWidth,
            imageHeight: page.sourceHeight,
            initialQuad: quad,
            detectedQuad: page.detectedQuad,
          ),
        ),
      );
      if (q == null || !mounted) return false;
      quad = q;
      final choice = await Navigator.of(context).push<FilterChoice>(
        MaterialPageRoute(
          builder: (_) => FilterScreen(
            sourcePath: page.sourcePath,
            quad: quad,
            initialFilter: page.filter,
            initialRotation: page.rotation,
          ),
        ),
      );
      if (choice == null) continue; // atrás → volver al recorte
      page
        ..quad = quad
        ..filter = choice.filter
        ..rotation = choice.rotation;
      _defaultFilter = choice.filter;
      return true;
    }
  }

  Future<void> _editPage(ScanPage page) async {
    final ok = await _editFlow(page);
    if (ok && mounted) {
      setState(() {});
      _enqueueRender(page);
    }
  }

  // -------------------------------------------------------------------------
  // Renderizado en segundo plano
  // -------------------------------------------------------------------------

  void _enqueueRender(ScanPage page) {
    final revision = ++page.revision;
    setState(() => page.status = PageStatus.processing);
    _renderQueue = _renderQueue.then((_) => _render(page, revision));
  }

  Future<void> _render(ScanPage page, int revision) async {
    if (!_pages.contains(page) || page.revision != revision) return;
    final dir = _workDir;
    if (dir == null) return;
    final out = '${dir.path}/page_${page.id}_r$revision.jpg';
    try {
      final r = await ImageService.render(
        sourcePath: page.sourcePath,
        quad: page.quad,
        filter: page.filter,
        rotation: page.rotation,
        outputPath: out,
      );
      if (page.revision != revision || !_pages.contains(page)) {
        _deleteQuietly(out);
        return;
      }
      final old = page.outputPath;
      page
        ..outputPath = r.path
        ..outputWidth = r.width
        ..outputHeight = r.height
        ..status = PageStatus.ready
        ..error = null;
      if (old != null && old != r.path) _deleteQuietly(old);
      _enqueueOcr(page, revision);
    } catch (e) {
      page
        ..status = PageStatus.error
        ..error = '$e';
    }
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------------------------
  // OCR en segundo plano (sobre la imagen final de cada página)
  // -------------------------------------------------------------------------

  void _enqueueOcr(ScanPage page, int revision) {
    page
      ..ocrLines = null
      ..ocrStatus = OcrStatus.running;
    _ocrQueue = _ocrQueue.then((_) => _runOcr(page, revision));
  }

  Future<void> _runOcr(ScanPage page, int revision) async {
    final path = page.outputPath;
    if (!_pages.contains(page) || page.revision != revision || path == null) {
      return;
    }
    List<OcrLine>? lines;
    var status = OcrStatus.done;
    try {
      lines = await OcrService.recognize(
        path,
        page.outputWidth,
        page.outputHeight,
      );
      if (lines == null) status = OcrStatus.unavailable;
    } catch (e) {
      status = OcrStatus.failed;
    }
    // La página se ha vuelto a editar mientras tanto: resultado obsoleto.
    if (page.revision != revision) return;
    page
      ..ocrLines = lines
      ..ocrStatus = status;
    if (mounted) setState(() {});
  }

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void _removePage(ScanPage page) {
    setState(() => _pages.remove(page));
    final out = page.outputPath;
    if (out != null) _deleteQuietly(out);
  }

  // -------------------------------------------------------------------------
  // Exportar
  // -------------------------------------------------------------------------

  Future<void> _savePdf() async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final options = await showExportDialog(
      context,
      defaultName:
          'Escaneo ${now.year}-${two(now.month)}-${two(now.day)} '
          '${two(now.hour)}.${two(now.minute)}',
      initialSize: _pageSize,
      initialOcr: _ocrEnabled,
    );
    if (options == null || !mounted) return;
    _pageSize = options.pageSize;
    _ocrEnabled = options.ocr;
    setState(() {
      _saving = true;
      _busyMessage = 'Terminando páginas…';
    });
    try {
      await _renderQueue;
      final failed = _pages.where((p) => p.status != PageStatus.ready).length;
      if (failed > 0) {
        throw StateError('$failed página(s) no se pudieron procesar');
      }
      if (options.ocr) {
        if (mounted) setState(() => _busyMessage = 'Reconociendo texto…');
        await _ocrQueue;
        if (_pages.any((p) => p.ocrStatus == OcrStatus.unavailable)) {
          _snack(
            'El reconocimiento de texto no está disponible en este '
            'dispositivo: el PDF se guardará sin texto seleccionable.',
          );
        } else if (_pages.any((p) => p.ocrStatus == OcrStatus.failed)) {
          _snack('No se pudo leer el texto de alguna página.');
        }
      }
      if (mounted) setState(() => _busyMessage = 'Generando PDF…');
      final inputs = [
        for (final p in _pages)
          PdfPageInput(
            p.outputPath!,
            p.outputWidth,
            p.outputHeight,
            lines: options.ocr ? (p.ocrLines ?? const []) : const [],
          ),
      ];
      final text = options.ocr
          ? _pages
                .map((p) => ocrPlainText(p.ocrLines ?? const []))
                .where((t) => t.isNotEmpty)
                .join('\n\n')
          : '';
      final bytes = await PdfService.build(
        inputs,
        pageSize: options.pageSize,
        title: options.name,
      );
      final thumb = await ImageService.thumbnail(_pages.first.outputPath!);
      final doc = await DocumentRepository.instance.save(
        name: options.name,
        pdfBytes: bytes,
        pages: _pages.length,
        thumbnail: thumb,
        text: text.isEmpty ? null : text,
      );
      if (!mounted) return;
      // Sustituye la sesión por el visor del PDF recién creado.
      _pages.clear();
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => PdfViewerScreen(document: doc)),
        ),
      );
    } catch (e) {
      _snack('No se pudo crear el PDF: $e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _confirmExit() async {
    final discard = await showConfirmDialog(
      context,
      title: '¿Descartar escaneo?',
      message: 'Se perderán las ${_pages.length} página(s) escaneadas.',
      confirm: 'Descartar',
    );
    if (discard && mounted) {
      _pages.clear();
      Navigator.of(context).pop();
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final busy = _busyMessage != null;
    final processing = _pages.any((p) => p.status == PageStatus.processing);
    return PopScope(
      canPop: _pages.isEmpty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _pages.isEmpty
                ? 'Nuevo documento'
                : '${_pages.length} página${_pages.length == 1 ? '' : 's'}',
          ),
          actions: [
            IconButton(
              tooltip: 'Cámara',
              onPressed: busy ? null : () => _capture(CaptureSource.camera),
              icon: const Icon(Icons.add_a_photo_outlined),
            ),
            IconButton(
              tooltip: 'Galería',
              onPressed: busy ? null : () => _capture(CaptureSource.gallery),
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
          ],
          bottom: busy
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: const LinearProgressIndicator(),
                )
              : null,
        ),
        body: Column(
          children: [
            if (busy)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_busyMessage!),
              ),
            Expanded(
              child: _pages.isEmpty
                  ? _EmptySession(
                      onCamera: busy
                          ? null
                          : () => _capture(CaptureSource.camera),
                      onGallery: busy
                          ? null
                          : () => _capture(CaptureSource.gallery),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      itemCount: _pages.length,
                      onReorderItem: (from, to) => setState(() {
                        _pages.insert(to, _pages.removeAt(from));
                      }),
                      itemBuilder: (context, i) {
                        final p = _pages[i];
                        return _PageCard(
                          key: ValueKey(p.id),
                          page: p,
                          index: i,
                          onEdit: busy ? null : () => _editPage(p),
                          onDelete: busy ? null : () => _removePage(p),
                        );
                      },
                    ),
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: _pages.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: busy ? null : _savePdf,
                icon: processing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.picture_as_pdf),
                label: const Text('Guardar PDF'),
              ),
      ),
    );
  }
}

class _EmptySession extends StatelessWidget {
  const _EmptySession({required this.onCamera, required this.onGallery});

  final VoidCallback? onCamera;
  final VoidCallback? onGallery;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text('Añade la primera página', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCamera,
              icon: const Icon(Icons.photo_camera),
              label: const Text('Hacer foto'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onGallery,
              icon: const Icon(Icons.photo_library),
              label: const Text('Elegir de la galería'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    super.key,
    required this.page,
    required this.index,
    required this.onEdit,
    required this.onDelete,
  });

  final ScanPage page;
  final int index;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final out = page.outputPath;
    Widget thumb;
    if (out != null) {
      thumb = Image.file(
        File(out),
        key: ValueKey(out),
        fit: BoxFit.contain,
        cacheWidth: 240,
        gaplessPlayback: true,
      );
    } else {
      thumb = const SizedBox.shrink();
    }
    final status = switch (page.status) {
      PageStatus.processing => 'Procesando…',
      PageStatus.ready => switch (page.ocrStatus) {
        OcrStatus.running ||
        OcrStatus.pending => '${page.filter.label} · leyendo texto…',
        OcrStatus.done when (page.ocrLines?.isNotEmpty ?? false) =>
          '${page.filter.label} · ${page.ocrLines!.length} líneas de texto',
        OcrStatus.done => '${page.filter.label} · sin texto',
        OcrStatus.unavailable || OcrStatus.failed => page.filter.label,
      },
      PageStatus.error => 'Error: ${page.error}',
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 84,
                height: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: thumb,
                    ),
                    if (page.status == PageStatus.processing)
                      const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Página ${index + 1}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: page.status == PageStatus.error
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Editar',
                onPressed: onEdit,
                icon: const Icon(Icons.crop_rotate),
              ),
              IconButton(
                tooltip: 'Eliminar',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
