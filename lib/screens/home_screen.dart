import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/document_repository.dart';
import '../widgets/dialogs.dart';
import 'pdf_viewer_screen.dart';
import 'scan_session_screen.dart';

/// Pantalla principal: documentos guardados + botón de escanear.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = DocumentRepository.instance;
  List<SavedDocument>? _docs;

  @override
  void initState() {
    super.initState();
    _repo.cleanupSessions();
    _reload();
  }

  Future<void> _reload() async {
    final docs = await _repo.list();
    if (mounted) setState(() => _docs = docs);
  }

  Future<void> _scan() async {
    final source = await showSourcePicker(context);
    if (source == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScanSessionScreen(initialSource: source),
      ),
    );
    await _reload();
  }

  Future<void> _open(SavedDocument doc) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PdfViewerScreen(document: doc)));
  }

  Future<void> _share(SavedDocument doc) async {
    final bytes = await File(doc.pdfPath).readAsBytes();
    await Printing.sharePdf(bytes: bytes, filename: doc.fileName);
  }

  Future<void> _rename(SavedDocument doc) async {
    final name = await showTextInputDialog(
      context,
      title: 'Renombrar',
      initial: doc.name,
    );
    if (name == null || name.isEmpty) return;
    await _repo.rename(doc, name);
    await _reload();
  }

  Future<void> _delete(SavedDocument doc) async {
    final ok = await showConfirmDialog(
      context,
      title: '¿Eliminar documento?',
      message: '«${doc.name}» se borrará definitivamente.',
      confirm: 'Eliminar',
    );
    if (!ok) return;
    await _repo.delete(doc);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return Scaffold(
      appBar: AppBar(title: const Text('Escáner PDF')),
      body: docs == null
          ? const Center(child: CircularProgressIndicator())
          : docs.isEmpty
          ? _EmptyHome(onScan: _scan)
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, i) => _DocumentTile(
                  doc: docs[i],
                  onTap: () => _open(docs[i]),
                  onShare: () => _share(docs[i]),
                  onRename: () => _rename(docs[i]),
                  onDelete: () => _delete(docs[i]),
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scan,
        icon: const Icon(Icons.document_scanner),
        label: const Text('Escanear'),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 88, color: scheme.primary),
            const SizedBox(height: 16),
            Text(
              'Aún no hay documentos',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Haz una foto o elige imágenes de la galería: se recortan, '
              'se enderezan y se mejora el texto automáticamente.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DocAction { share, rename, delete }

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.onTap,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
  });

  final SavedDocument doc;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = doc.thumbPath;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 56,
                  height: 76,
                  color: scheme.surfaceContainerHighest,
                  child: thumb == null
                      ? Icon(Icons.picture_as_pdf, color: scheme.primary)
                      : Image.file(
                          File(thumb),
                          fit: BoxFit.cover,
                          cacheWidth: 168,
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${doc.pages} pág. · ${formatBytes(doc.sizeBytes)} · '
                      '${formatDate(doc.createdAt)}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_DocAction>(
                onSelected: (a) => switch (a) {
                  _DocAction.share => onShare(),
                  _DocAction.rename => onRename(),
                  _DocAction.delete => onDelete(),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _DocAction.share,
                    child: ListTile(
                      leading: Icon(Icons.share),
                      title: Text('Compartir'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _DocAction.rename,
                    child: ListTile(
                      leading: Icon(Icons.edit),
                      title: Text('Renombrar'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _DocAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Eliminar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
