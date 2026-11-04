import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_saver.dart';
import '../services/document_repository.dart';
import '../services/pdf_service.dart';

enum CaptureSource { camera, gallery }

/// Hoja inferior para elegir cámara o galería.
Future<CaptureSource?> showSourcePicker(BuildContext context) {
  return showModalBottomSheet<CaptureSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: _SourceCard(
                icon: Icons.photo_camera_outlined,
                label: 'Cámara',
                onTap: () => Navigator.pop(context, CaptureSource.camera),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SourceCard(
                icon: Icons.photo_library_outlined,
                label: 'Galería',
                onTap: () => Navigator.pop(context, CaptureSource.gallery),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: scheme.onPrimaryContainer),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExportOptions {
  const ExportOptions(
    this.name,
    this.pageSize, {
    this.ocr = true,
    this.quality = PdfQuality.high,
    this.saveToDevice = false,
  });

  final String name;
  final PdfPageSize pageSize;

  /// Añadir capa de texto (OCR) para poder buscar y copiar el texto.
  final bool ocr;

  /// Calidad de las imágenes (tamaño del archivo).
  final PdfQuality quality;

  /// Abrir además el selector del sistema para guardar una copia en una
  /// carpeta del dispositivo.
  final bool saveToDevice;
}

/// Diálogo de guardado: nombre, tamaño de página, calidad, OCR y copia en
/// una carpeta del dispositivo.
Future<ExportOptions?> showExportDialog(
  BuildContext context, {
  required String defaultName,
  PdfPageSize initialSize = PdfPageSize.a4,
  bool initialOcr = true,
  PdfQuality initialQuality = PdfQuality.high,
  bool initialSaveToDevice = false,
}) {
  final controller = TextEditingController(text: defaultName);
  var size = initialSize;
  var ocr = initialOcr;
  var quality = initialQuality;
  var saveToDevice = initialSaveToDevice;
  return showDialog<ExportOptions>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final small = Theme.of(context).textTheme.bodySmall;
        return AlertDialog(
          title: const Text('Guardar PDF'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Nombre',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Tamaño de página'),
                const SizedBox(height: 8),
                SegmentedButton<PdfPageSize>(
                  segments: [
                    for (final s in PdfPageSize.values)
                      ButtonSegment(value: s, label: Text(s.label)),
                  ],
                  selected: {size},
                  onSelectionChanged: (v) => setState(() => size = v.first),
                  showSelectedIcon: false,
                ),
                if (size == PdfPageSize.fit) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Cada página toma la forma del documento escaneado.',
                    style: small,
                  ),
                ],
                const SizedBox(height: 16),
                const Text('Calidad'),
                const SizedBox(height: 8),
                SegmentedButton<PdfQuality>(
                  segments: [
                    for (final q in PdfQuality.values)
                      ButtonSegment(value: q, label: Text(q.label)),
                  ],
                  selected: {quality},
                  onSelectionChanged: (v) => setState(() => quality = v.first),
                  showSelectedIcon: false,
                ),
                const SizedBox(height: 6),
                Text(switch (quality) {
                  PdfQuality.high => 'Máxima nitidez.',
                  PdfQuality.medium =>
                    'Más ligero: ideal para correo y WhatsApp.',
                  PdfQuality.low =>
                    'Archivo mínimo; el texto pequeño pierde detalle.',
                }, style: small),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: ocr,
                  onChanged: (v) => setState(() => ocr = v),
                  title: const Text('Texto seleccionable (OCR)'),
                  subtitle: const Text('Permite buscar y copiar el texto'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: saveToDevice,
                  onChanged: (v) => setState(() => saveToDevice = v),
                  title: const Text('Guardar también en el dispositivo'),
                  subtitle: const Text(
                    'Elige carpeta y nombre (Descargas, Drive…)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                Navigator.pop(
                  context,
                  ExportOptions(
                    name.isEmpty ? defaultName : name,
                    size,
                    ocr: ocr,
                    quality: quality,
                    saveToDevice: saveToDevice,
                  ),
                );
              },
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    ),
  );
}

/// Diálogo de texto genérico (renombrar).
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String initial,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Aceptar'),
        ),
      ],
    ),
  );
}

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Aceptar',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

String formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Copia al portapapeles el texto reconocido (OCR) de [doc].
Future<void> copyDocumentText(BuildContext context, SavedDocument doc) async {
  final text = await DocumentRepository.instance.readText(doc);
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  if (text.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Este documento no tiene texto reconocido')),
    );
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(
    SnackBar(content: Text('Texto copiado (${text.length} caracteres)')),
  );
}

/// Guarda [doc] en una carpeta del dispositivo con el selector del sistema.
Future<void> saveDocumentToDevice(
  BuildContext context,
  SavedDocument doc,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await File(doc.pdfPath).readAsBytes();
    final where = await DeviceSaver.savePdf(bytes, doc.fileName);
    if (where == null) return; // cancelado
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Guardado en $where')));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('No se pudo guardar: $e')));
  }
}
