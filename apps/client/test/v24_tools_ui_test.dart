import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';

import 'persistence_ui_support.dart';

void main() => runDevToolsUiScenario(const Size(320, 640));

// Real persistence futures must not outlive a widget fake-clock isolate.
void runDevToolsUiScenario(Size size) {
  late Directory temp;
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('v24-tools-ui-');
    db = AppDatabase.file(File('${temp.path}/db.sqlite'));
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ownedFilesProvider.overrideWith((ref) async => OwnedFileStore(temp)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  testWidgets(
    'all real developer routes fit $size and formatter regex snippet actions persist',
    (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
      }

      try {
        debugPrint('mount isolated app');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const LinksToolboxApp(),
          ),
        );
        await settle();
        for (final id in [
          'api_studio',
          'data_formatter',
          'regex_lab',
          'hash_inspector',
          'snippets',
          'network_inspector',
          'log_viewer',
          'github_projects',
          'dependency_inspector',
          'environment_diff',
          'workflow',
        ]) {
          debugPrint('route $id');
          container.read(routerProvider).go('/modules/$id');
          await settle();
          expect(tester.takeException(), isNull, reason: id);
        }
        container.read(routerProvider).go('/modules/data_formatter');
        await settle();
        await tester.enterText(
          find.widgetWithText(TextField, '输入'),
          '{"中文":[1,2]}',
        );
        await tester.tap(find.widgetWithText(FilledButton, '处理'));
        await settle();
        await waitForPersisted(
          tester,
          () async => find.text('语法有效').evaluate().isNotEmpty,
          (v) => v,
        );
        expect(find.textContaining('"中文"'), findsWidgets);
        expect(tester.takeException(), isNull);
        container.read(routerProvider).go('/modules/regex_lab');
        await settle();
        await tester.enterText(find.widgetWithText(TextField, '表达式'), r'(\w+)');
        await tester.enterText(
          find.widgetWithText(TextField, '测试文本'),
          'abc def',
        );
        final run = find.widgetWithText(FilledButton, '匹配与替换');
        await tester.ensureVisible(run);
        await tester.tap(run);
        await settle();
        await waitForPersisted(
          tester,
          () async => find.textContaining('2项匹配').evaluate().isNotEmpty,
          (v) => v,
        );
        expect(tester.takeException(), isNull);
        container.read(routerProvider).go('/modules/snippets');
        await settle();
        await tester.tap(find.widgetWithText(FilledButton, '新增片段'));
        await settle();
        await tester.enterText(find.widgetWithText(TextField, '名称'), 'UI实际片段');
        await tester.enterText(
          find.widgetWithText(TextField, '代码（仅保存，不执行）'),
          'print("hello")',
        );
        final save = find.widgetWithText(FilledButton, '保存');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await settle();
        await waitForPersisted(
          tester,
          () => container.read(recordStoreProvider).list('dev_snippet'),
          (rows) => rows.any((r) => r.title == 'UI实际片段'),
        );
        await settle();
        expect(find.text('UI实际片段'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
      }
    },
  );
}
