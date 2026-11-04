import 'dart:typed_data';

import 'package:camera_scanner/processing/geometry.dart';
import 'package:camera_scanner/widgets/crop_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 100, height: 100)),
  );

  Future<List<Quad>> pumpEditor(WidgetTester tester, Quad initial) async {
    final changes = <Quad>[];
    var quad = initial;
    await tester.binding.setSurfaceSize(const Size(456, 456));
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 456,
            height: 456,
            child: CropEditor(
              image: MemoryImage(png),
              imageSize: const Size(100, 100),
              quad: quad,
              onChanged: (q) {
                changes.add(q);
                setState(() => quad = q);
              },
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('arrastrar una esquina la mueve', (tester) async {
    // Imagen 100x100 encajada en 456 - 2*28 = 400 px → escala 4, origen 28.
    final changes = await pumpEditor(tester, Quad.rect(1, 1));
    // TL está en (28, 28). Se arrastra 100 px a la derecha y abajo.
    await tester.dragFrom(const Offset(30, 30), const Offset(100, 100));
    await tester.pump();
    expect(changes, isNotEmpty);
    final tl = changes.last.tl;
    expect(tl.x, closeTo(0.25, 0.03));
    expect(tl.y, closeTo(0.25, 0.03));
    // El resto de esquinas no se mueve.
    expect(changes.last.br, const Pt(1, 1));
  });

  testWidgets('arrastrar el punto medio desplaza el lado', (tester) async {
    final changes = await pumpEditor(
      tester,
      const Quad(Pt(0.1, 0.1), Pt(0.9, 0.1), Pt(0.9, 0.9), Pt(0.1, 0.9)),
    );
    // Punto medio del lado superior: (28 + 200, 28 + 40).
    await tester.dragFrom(const Offset(228, 68), const Offset(0, 80));
    await tester.pump();
    final q = changes.last;
    expect(q.tl.y, closeTo(0.3, 0.03));
    expect(q.tr.y, closeTo(0.3, 0.03));
    expect(q.bl.y, closeTo(0.9, 1e-9));
  });

  testWidgets('las esquinas no salen de la imagen', (tester) async {
    final changes = await pumpEditor(tester, Quad.rect(1, 1));
    await tester.dragFrom(const Offset(30, 30), const Offset(-200, -200));
    await tester.pump();
    final tl = changes.isEmpty ? const Pt(0, 0) : changes.last.tl;
    expect(tl.x, greaterThanOrEqualTo(0));
    expect(tl.y, greaterThanOrEqualTo(0));
  });
}
