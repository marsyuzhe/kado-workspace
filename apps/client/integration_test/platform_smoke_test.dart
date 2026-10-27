import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real platform SQLite, application directory and secure credentials',
    (tester) async {
      final directory = await getTemporaryDirectory();
      final testFile = File(
        p.join(
          directory.path,
          'links-smoke-${DateTime.now().microsecondsSinceEpoch}.sqlite',
        ),
      );
      final db = AppDatabase.file(testFile);
      try {
        await db.initialize();
        expect(await db.verifyIntegrity(), isTrue);
        await verifyCredentialStore(const SystemCredentialStore());
        final repository = SettingsRepository(db);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(repository),
            ],
            child: const LinksToolboxApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(await db.verifyIntegrity(), isTrue);
        expect(find.text('快捷启动'), findsOneWidget);
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        final verify = find.text('验证本机安全存储');
        await tester.ensureVisible(verify);
        await tester.tap(verify);
        await tester.pumpAndSettle();
        expect(find.text('本机验证通过 · 已读回测试值并删除测试键'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        await db.close();
        if (await testFile.exists()) await testFile.delete();
      }
    },
  );
}
