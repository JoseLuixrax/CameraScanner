import 'dart:io';

import 'package:flutter/material.dart';

import '../processing/geometry.dart';
import '../widgets/crop_editor.dart';

/// Pantalla para ajustar los bordes del documento.
/// Devuelve el [Quad] normalizado elegido o `null` si se cancela.
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.imagePath,
    required this.imageWidth,
    required this.imageHeight,
    required this.initialQuad,
    required this.detectedQuad,
  });

  final String imagePath;
  final int imageWidth;
  final int imageHeight;
  final Quad initialQuad;
  final Quad? detectedQuad;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late Quad _quad = widget.initialQuad;
  late final ImageProvider _image = ResizeImage(
    FileImage(File(widget.imagePath)),
    width: 1600,
    allowUpscaling: false,
    policy: ResizeImagePolicy.fit,
  );

  static final Quad _full = Quad.rect(1, 1);

  @override
  Widget build(BuildContext context) {
    final valid = _quad.isConvex;
    final detected = widget.detectedQuad;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Ajustar bordes'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: CropEditor(
                image: _image,
                imageSize: Size(
                  widget.imageWidth.toDouble(),
                  widget.imageHeight.toDouble(),
                ),
                quad: _quad,
                onChanged: (q) => setState(() => _quad = q),
              ),
            ),
            if (!valid)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Las esquinas no forman un cuadrilátero válido',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Row(
                children: [
                  _ToolButton(
                    icon: Icons.auto_fix_high,
                    label: 'Auto',
                    onPressed: detected == null
                        ? null
                        : () => setState(() => _quad = detected),
                  ),
                  _ToolButton(
                    icon: Icons.fullscreen,
                    label: 'Toda',
                    onPressed: () => setState(() => _quad = _full),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: valid
                        ? () => Navigator.pop(context, _quad)
                        : null,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Siguiente'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white38,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon), const SizedBox(height: 2), Text(label)],
      ),
    );
  }
}
