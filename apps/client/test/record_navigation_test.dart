import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  testWidgets(
    'record navigation opens exact clipboard, note, project and provider records',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = container.read(recordStoreProvider);
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final clip = await store.create(
        'clipboard',
        '搜索命中的文本',
        body: '实际正文',
        data: {'contentType': 'text'},
      );
      final project = await container
          .read(memoryRepositoryProvider)
          .project('选中的项目');
      final note = await container
          .read(memoryRepositoryProvider)
          .createNote('精确笔记', body: '真正正文', projectId: project.id);
      final provider = await store.create(
        'ai_provider',
        '精确服务',
        data: {'model': 'manual-model'},
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const LinksToolboxApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = container.read(routerProvider);
      router.go('/modules/clipboard?id=${clip.id}');
      await tester.pumpAndSettle();
      expect(find.text('搜索命中的文本'), findsOneWidget);
      router.go('/modules/memory?id=${note.id}');
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == '真正正文',
        ),
        findsOneWidget,
      );
      router.go('/modules/memory?id=${project.id}');
      await tester.pumpAndSettle();
      expect(find.text('导出上下文'), findsOneWidget);
      router.go('/modules/ai_desk?id=${provider.id}');
      await tester.pumpAndSettle();
      expect(find.text('精确服务 · manual-model'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
