import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  testWidgets('MarkdownBody renders markdown table with GitHub Flavored syntax', (tester) async {
    const tableMarkdown = '''
## Başlık

Aşağıdaki tablo projenin mimarisini göstermektedir:

| Katman | Ne yapmalı? | Karmaşıklık |
|---|---|---|
| **1. Plaka Tanıma** | OpenCV + OCR | 🔴 Yüksek |
| **2. Veritabanı** | PostgreSQL | 🟡 Orta |
| **3. Bariyer** | GPIO / IoT | 🔴 Yüksek |
''';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: tableMarkdown,
              selectable: true,
              extensionSet: md.ExtensionSet.gitHubFlavored,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 14),
                h2: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                tableHead: const TextStyle(fontWeight: FontWeight.bold),
                tableBody: const TextStyle(fontSize: 13),
                tableBorder: TableBorder.all(color: Colors.grey),
                tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Table widget is rendered!
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Katman'), findsOneWidget);
    expect(find.text('Ne yapmalı?'), findsOneWidget);
    expect(find.text('Karmaşıklık'), findsOneWidget);
  });
}
