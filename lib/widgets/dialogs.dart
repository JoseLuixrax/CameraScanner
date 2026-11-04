import 'package:flutter/material.dart';

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
  const ExportOptions(this.name, this.pageSize);

  final String name;
  final PdfPageSize pageSize;
}

/// Diálogo con nombre del PDF y tamaño de página.
Future<ExportOptions?> showExportDialog(
  BuildContext context, {
  required String defaultName,
  PdfPageSize initialSize = PdfPageSize.a4,
}) {
  final controller = TextEditingController(text: defaultName);
  var size = initialSize;
  return showDialog<ExportOptions>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Guardar PDF'),
        content: Column(
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
              const SizedBox(height: 8),
              Text(
                'Cada página toma la forma del documento escaneado.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
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
                ExportOptions(name.isEmpty ? defaultName : name, size),
              );
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
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
