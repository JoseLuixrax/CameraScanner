import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const ScannerApp());
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key, this.home});

  /// Pantalla inicial (por defecto, la lista de documentos).
  final Widget? home;

  static const Color _seed = Color(0xFF00796B);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Escáner PDF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: home ?? const HomeScreen(),
    );
  }
}
