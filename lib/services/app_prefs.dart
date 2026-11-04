import 'package:shared_preferences/shared_preferences.dart';

import '../processing/enhance.dart';
import 'pdf_service.dart';

/// Preferencias persistentes de la app. Si el almacenamiento no está
/// disponible (tests) funciona en memoria con los valores por defecto.
class AppPrefs {
  AppPrefs._();

  static SharedPreferences? _prefs;
  static final Map<String, Object> _memory = {};

  static Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      _prefs = null;
    }
  }

  static T _get<T>(String key, T fallback) {
    final mem = _memory[key];
    if (mem is T) return mem;
    final v = _prefs?.get(key);
    return v is T ? v : fallback;
  }

  static void _set(String key, Object value) {
    _memory[key] = value;
    final p = _prefs;
    if (p == null) return;
    switch (value) {
      case final bool b:
        p.setBool(key, b);
      case final int i:
        p.setInt(key, i);
      case final String s:
        p.setString(key, s);
    }
  }

  // --- Cámara ---------------------------------------------------------------

  /// Disparo automático cuando el documento está quieto.
  static bool get autoCapture => _get('camera.auto', true);
  static set autoCapture(bool v) => _set('camera.auto', v);

  /// Modo lote: varias páginas seguidas sin salir de la cámara.
  static bool get batchMode => _get('camera.batch', false);
  static set batchMode(bool v) => _set('camera.batch', v);

  /// off | auto | torch
  static String get flash => _get('camera.flash', 'off');
  static set flash(String v) => _set('camera.flash', v);

  // --- Escaneo y PDF --------------------------------------------------------

  static ScanFilter get defaultFilter =>
      ScanFilter.fromName(_get<String?>('scan.filter', null));
  static set defaultFilter(ScanFilter f) => _set('scan.filter', f.name);

  static PdfPageSize get pageSize => PdfPageSize.values.firstWhere(
    (s) => s.name == _get('pdf.pageSize', PdfPageSize.a4.name),
    orElse: () => PdfPageSize.a4,
  );
  static set pageSize(PdfPageSize s) => _set('pdf.pageSize', s.name);

  static bool get ocr => _get('pdf.ocr', true);
  static set ocr(bool v) => _set('pdf.ocr', v);

  static PdfQuality get quality =>
      PdfQuality.fromName(_get<String?>('pdf.quality', null));
  static set quality(PdfQuality q) => _set('pdf.quality', q.name);

  /// Al crear un PDF, abrir también "Guardar en…" para elegir carpeta.
  static bool get saveToDevice => _get('pdf.saveToDevice', false);
  static set saveToDevice(bool v) => _set('pdf.saveToDevice', v);
}
