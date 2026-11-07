// Uygulama klasöründeki mcp_config.json yalnızca şablondur; FerIDE (ve testler)
// içine makineye özgü yollar yazmamalı. Eskiden bir test çalıştırması bile şablona
// "/tmp/..." yollarını yazıyordu; yedek Windows/macOS'a taşınınca MCP bozuluyordu.
import 'dart:io';

import 'package:feride_v5_2/features/settings/settings_provider.dart';
import 'package:feride_v5_2/services/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('MCP yapılandırması kullanıcı klasöründe; uygulama şablonu değişmez', () async {
    final template = File(p.join(AppPaths.appRoot, 'mcp_config.json'));
    final before = template.existsSync() ? template.readAsStringSync() : null;
    final appRoot = AppPaths.appRoot;

    for (final saved in <String?>[null, template.path]) {
      SharedPreferences.setMockInitialValues({if (saved != null) 'mcpConfigPath': saved});
      final settings = SettingsNotifier(await SharedPreferences.getInstance());
      expect(settings.state.mcpConfigPath, p.join(AppPaths.ferideDataDir, 'mcp_config.json'));
      expect(p.isWithin(appRoot, settings.state.mcpConfigPath), isFalse);
      settings.dispose();
    }
    if (before != null) {
      expect(template.readAsStringSync(), before, reason: 'şablona yazılmamalı');
      expect(File(p.join(AppPaths.ferideDataDir, 'mcp_config.json')).existsSync(), isTrue,
          reason: 'şablon ilk açılışta kullanıcı klasörüne kopyalanmalı');
    }
  });
}
