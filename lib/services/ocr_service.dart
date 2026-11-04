import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/ocr_line.dart';

/// Motor de OCR intercambiable (en tests se sustituye por uno falso).
abstract class OcrEngine {
  /// Reconoce el texto de la imagen [imagePath] de `width x height` píxeles.
  Future<List<OcrLine>> recognize(String imagePath, int width, int height);

  Future<void> close();
}

/// OCR en el dispositivo con Google ML Kit (alfabeto latino).
///
/// El modelo va empaquetado dentro de la app: funciona sin conexión y sin
/// Google Play Services. Reconoce español, francés, alemán, italiano,
/// portugués, inglés y el resto de idiomas con alfabeto latino.
class MlKitOcrEngine implements OcrEngine {
  TextRecognizer? _recognizer;

  @override
  Future<List<OcrLine>> recognize(
    String imagePath,
    int width,
    int height,
  ) async {
    final recognizer = _recognizer ??= TextRecognizer(
      script: TextRecognitionScript.latin,
    );
    final result = await recognizer.processImage(
      InputImage.fromFilePath(imagePath),
    );
    final lines = <OcrLine>[];
    for (var b = 0; b < result.blocks.length; b++) {
      for (final line in result.blocks[b].lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        final box = line.boundingBox;
        lines.add(
          OcrLine(
            text: text,
            left: box.left / width,
            top: box.top / height,
            width: box.width / width,
            height: box.height / height,
            block: b,
          ),
        );
      }
    }
    return lines;
  }

  @override
  Future<void> close() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}

class OcrService {
  OcrService._();

  /// Motor activo. Se puede reemplazar (tests, otros motores).
  static OcrEngine engine = MlKitOcrEngine();

  /// Devuelve las líneas reconocidas, o `null` si el OCR no está disponible
  /// en esta plataforma (p. ej. escritorio o tests sin motor falso).
  static Future<List<OcrLine>?> recognize(
    String imagePath,
    int width,
    int height,
  ) async {
    try {
      return await engine.recognize(imagePath, width, height);
    } on MissingPluginException {
      return null;
    }
  }
}
