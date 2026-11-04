import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// Guarda archivos fuera de la app eligiendo carpeta y nombre con el
/// selector del sistema:
///  * Android: "Crear documento" del sistema (Storage Access Framework):
///    Descargas, Documentos, tarjeta SD, Google Drive… sin pedir permisos.
///  * iOS: "Guardar en Archivos" (iCloud Drive, En mi iPhone, Drive…).
class DeviceSaver {
  DeviceSaver._();

  /// Devuelve una descripción legible de dónde se guardó, o `null` si el
  /// usuario canceló. Lanza [DeviceSaveException] si falla.
  static Future<String?> savePdf(Uint8List bytes, String fileName) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: 'Guardar PDF',
      );
      if (uri == null) return null;
      return describeLocation(uri, fallbackName: fileName);
    } on PlatformException catch (e) {
      throw DeviceSaveException(e.message ?? e.code);
    }
  }

  /// Convierte la URI devuelta por el sistema en algo legible, p. ej.
  /// `content://…/document/primary%3ADownload%2FFactura.pdf` → `Download/Factura.pdf`.
  static String describeLocation(Uri uri, {String fallbackName = ''}) {
    if (uri.scheme == 'file') {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2) return '${segs[segs.length - 2]}/${segs.last}';
      return segs.isEmpty ? fallbackName : segs.last;
    }
    if (uri.scheme == 'content') {
      // Documentos SAF: el último segmento es "<volumen>:<ruta relativa>".
      final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final decoded = Uri.decodeComponent(last);
      final colon = decoded.indexOf(':');
      if (colon >= 0 && colon < decoded.length - 1) {
        final volume = decoded.substring(0, colon);
        final path = decoded.substring(colon + 1);
        return volume == 'primary' ? path : '$volume/$path';
      }
      // Proveedores sin ruta (Drive, msf:123…): sólo se conoce el nombre.
      return fallbackName.isNotEmpty ? fallbackName : decoded;
    }
    return fallbackName.isNotEmpty ? fallbackName : uri.toString();
  }
}

class DeviceSaveException implements Exception {
  DeviceSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}
