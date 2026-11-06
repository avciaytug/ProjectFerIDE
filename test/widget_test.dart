// FerIDE v5.2 — smoke test.
//
// Ruling (progress.md): widget_test.dart en aza indirilecek — MaterialApp
// bulunur, uygulama ayağa kalkar. Eski counter şablonu kaldırıldı.
// Not: IdeShell geniş pencere tasarımıdır; dar test viewport'unda
// (800x600) header/sidebar Row'ları taşma verir → gerçek pencere boyutu kullan.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:feride_v5_2/main.dart';
import 'package:feride_v5_2/features/chat/ide_shell.dart';

void main() {
  testWidgets('FerIDEApp ayağa kalkar (MaterialApp bulunur)', (WidgetTester tester) async {
    // Gerçek pencere boyutuna yaklaştır (dar viewport'ta layout overflow'u)
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: FerIDEApp()));
    await tester.pump();

    // Uygulama bir MaterialApp ile kuruldu
    expect(find.byType(MaterialApp), findsOneWidget);
    // Ana kabuk (IdeShell) render edildi
    expect(find.byType(IdeShell), findsOneWidget);
  });
}
