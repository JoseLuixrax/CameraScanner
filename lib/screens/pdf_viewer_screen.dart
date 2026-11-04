import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/document_repository.dart';

/// Visor del PDF con acciones de compartir e imprimir.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({super.key, required this.document});

  final SavedDocument document;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late final Future<Uint8List> _bytes = File(widget.document.pdfPath)
      .readAsBytes();

  Future<void> _share() async {
    final bytes = await _bytes;
    await Printing.sharePdf(bytes: bytes, filename: widget.document.fileName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.document.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Compartir',
            onPressed: _share,
            icon: const Icon(Icons.share),
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) => _bytes,
        pdfFileName: widget.document.fileName,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        allowPrinting: true,
        allowSharing: true,
      ),
    );
  }
}
