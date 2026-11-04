import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// PDF guardado en el almacenamiento interno de la app.
class SavedDocument {
  SavedDocument({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.pages,
    required this.pdfPath,
    required this.thumbPath,
    required this.sizeBytes,
  });

  final String id;
  String name;
  final DateTime createdAt;
  final int pages;
  final String pdfPath;
  final String? thumbPath;
  final int sizeBytes;

  /// Nombre de archivo seguro para compartir.
  String get fileName {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return '${safe.isEmpty ? 'escaneo' : safe}.pdf';
  }
}

/// Guarda los PDF en `<documentos de la app>/scans/` con una ficha JSON y una
/// miniatura por documento: `scans/<id>.pdf`, `scans/<id>.json` y
/// `scans/<id>.jpg`.
class DocumentRepository {
  DocumentRepository._();

  static final DocumentRepository instance = DocumentRepository._();

  /// Permite sustituir las carpetas del sistema en tests.
  @visibleForTesting
  static Directory? debugDocumentsDir;
  @visibleForTesting
  static Directory? debugTempDir;

  Future<Directory> _documents() async =>
      debugDocumentsDir ?? await getApplicationDocumentsDirectory();

  Future<Directory> _temp() async =>
      debugTempDir ?? await getTemporaryDirectory();

  Future<Directory> _dir() async {
    final base = await _documents();
    final dir = Directory('${base.path}/scans');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<SavedDocument>> list() async {
    final dir = await _dir();
    final docs = <SavedDocument>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final meta = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final id = meta['id'] as String;
        final pdf = File('${dir.path}/$id.pdf');
        if (!pdf.existsSync()) continue;
        final thumb = File('${dir.path}/$id.jpg');
        docs.add(
          SavedDocument(
            id: id,
            name: meta['name'] as String,
            createdAt: DateTime.parse(meta['createdAt'] as String),
            pages: meta['pages'] as int,
            pdfPath: pdf.path,
            thumbPath: thumb.existsSync() ? thumb.path : null,
            sizeBytes: pdf.lengthSync(),
          ),
        );
      } catch (_) {
        // Ficha corrupta: se ignora.
      }
    }
    docs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return docs;
  }

  Future<SavedDocument> save({
    required String name,
    required Uint8List pdfBytes,
    required int pages,
    Uint8List? thumbnail,
  }) async {
    final dir = await _dir();
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final pdf = File('${dir.path}/$id.pdf');
    await pdf.writeAsBytes(pdfBytes, flush: true);
    String? thumbPath;
    if (thumbnail != null) {
      thumbPath = '${dir.path}/$id.jpg';
      await File(thumbPath).writeAsBytes(thumbnail);
    }
    await File('${dir.path}/$id.json').writeAsString(
      jsonEncode({
        'id': id,
        'name': name,
        'createdAt': now.toIso8601String(),
        'pages': pages,
      }),
    );
    return SavedDocument(
      id: id,
      name: name,
      createdAt: now,
      pages: pages,
      pdfPath: pdf.path,
      thumbPath: thumbPath,
      sizeBytes: pdfBytes.length,
    );
  }

  Future<void> rename(SavedDocument doc, String newName) async {
    final dir = await _dir();
    final f = File('${dir.path}/${doc.id}.json');
    final meta = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    meta['name'] = newName;
    await f.writeAsString(jsonEncode(meta));
    doc.name = newName;
  }

  Future<void> delete(SavedDocument doc) async {
    final dir = await _dir();
    for (final ext in const ['pdf', 'json', 'jpg']) {
      final f = File('${dir.path}/${doc.id}.$ext');
      if (f.existsSync()) await f.delete();
    }
  }

  /// Carpeta temporal para una sesión de escaneo.
  Future<Directory> createSessionDir() async {
    final tmp = await _temp();
    final dir = Directory(
      '${tmp.path}/sessions/${DateTime.now().microsecondsSinceEpoch}',
    );
    return dir.create(recursive: true);
  }

  /// Borra sesiones temporales huérfanas (p. ej. tras un cierre forzado).
  Future<void> cleanupSessions({
    Duration olderThan = const Duration(hours: 6),
  }) async {
    try {
      final tmp = await _temp();
      final root = Directory('${tmp.path}/sessions');
      if (!root.existsSync()) return;
      final limit = DateTime.now().subtract(olderThan);
      for (final d in root.listSync().whereType<Directory>()) {
        if (d.statSync().modified.isBefore(limit)) {
          await d.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}
