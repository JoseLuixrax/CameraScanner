import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../processing/enhance.dart';
import '../processing/geometry.dart';
import '../processing/image_ops.dart';
import '../services/image_service.dart';

/// Resultado de la pantalla de filtros.
class FilterChoice {
  const FilterChoice(this.filter, this.rotation);

  final ScanFilter filter;
  final int rotation;
}

/// Previsualiza el documento recortado y permite elegir filtro y rotación.
class FilterScreen extends StatefulWidget {
  const FilterScreen({
    super.key,
    required this.sourcePath,
    required this.quad,
    required this.initialFilter,
    required this.initialRotation,
  });

  final String sourcePath;
  final Quad quad;
  final ScanFilter initialFilter;
  final int initialRotation;

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  late ScanFilter _filter = widget.initialFilter;
  late int _rotation = widget.initialRotation;
  RgbImage? _warped;
  Map<ScanFilter, Uint8List>? _thumbs;
  final Map<ScanFilter, Uint8List> _previews = {};
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final warped = await ImageService.warpPreview(
        widget.sourcePath,
        widget.quad,
      );
      _warped = warped;
      final results = await Future.wait([
        ImageService.thumbnails(warped),
        _ensurePreview(_filter),
      ]);
      if (!mounted) return;
      setState(() {
        _thumbs = results[0] as Map<ScanFilter, Uint8List>;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<Uint8List> _ensurePreview(ScanFilter f) async {
    final cached = _previews[f];
    if (cached != null) return cached;
    final bmp = await ImageService.filterPreview(_warped!, f);
    _previews[f] = bmp;
    return bmp;
  }

  Future<void> _select(ScanFilter f) async {
    if (_warped == null) return;
    setState(() {
      _filter = f;
      _busy = !_previews.containsKey(f);
    });
    await _ensurePreview(f);
    if (mounted && _filter == f) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _previews[_filter];
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1F),
        foregroundColor: Colors.white,
        title: const Text('Mejorar'),
        actions: [
          IconButton(
            tooltip: 'Girar a la izquierda',
            onPressed: () => setState(() => _rotation = (_rotation + 3) % 4),
            icon: const Icon(Icons.rotate_left),
          ),
          IconButton(
            tooltip: 'Girar a la derecha',
            onPressed: () => setState(() => _rotation = (_rotation + 1) % 4),
            icon: const Icon(Icons.rotate_right),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (preview != null)
                    InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: RotatedBox(
                            quarterTurns: _rotation,
                            child: Image.memory(
                              preview,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No se pudo procesar la imagen:\n$_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (_busy) const CircularProgressIndicator(),
                ],
              ),
            ),
            SizedBox(
              height: 118,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final f in ScanFilter.values)
                    _FilterTile(
                      label: f.label,
                      thumb: _thumbs?[f],
                      rotation: _rotation,
                      selected: f == _filter,
                      onTap: () => _select(f),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _warped == null
                      ? null
                      : () => Navigator.pop(
                          context,
                          FilterChoice(_filter, _rotation),
                        ),
                  icon: const Icon(Icons.check),
                  label: const Text('Listo'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterTile extends StatelessWidget {
  const _FilterTile({
    required this.label,
    required this.thumb,
    required this.rotation,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Uint8List? thumb;
  final int rotation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 3,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: thumb == null
                  ? const SizedBox.shrink()
                  : RotatedBox(
                      quarterTurns: rotation,
                      child: Image.memory(
                        thumb!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? scheme.primary : Colors.white70,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
