# google_mlkit_text_recognition compila contra los modelos de chino, devanagari,
# japonés y coreano (compileOnly) pero la app sólo empaqueta el alfabeto latino.
# Sin estas reglas R8 falla en la build de release con "Missing classes".
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
