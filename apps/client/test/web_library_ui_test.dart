import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/ui/app_theme.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:links_toolbox/features/web_library/web_library_page.dart';
import 'package:links_toolbox/features/web_library/web_providers.dart';
import 'package:links_toolbox/features/web_library/web_repository.dart';

import 'persistence_ui_support.dart';
import 'web_library_test.dart' show fixtureCatalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [const Size(320, 640), const Size(1280, 900)]) {
    late Directory temp;
    late AppDatabase db;
    late ProviderContainer container;
    late WebLibraryRepository repo;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('kado-web-ui-');
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      repo = WebLibraryRepository(
        RecordStore(db),
        catalog: () async => fixtureCatalog(),
      );
      await repo.initialize();
      container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
          webRepositoryProvider.overrideWithValue(repo),
        ],
      );
    });
    tearDown(() async {
      await container.read(utilityJobsProvider).dispose();
      container.dispose();
      await db.close();
      await temp.delete(recursive: true);
    });
    testWidgets('real web CRUD search category menu and keyboard fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
      }

      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f);
        await tester.runAsync(() => tester.tap(f));
        await settle();
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: appTheme(Brightness.dark),
            home: const Scaffold(body: WebLibraryPage()),
          ),
        ),
      );
      await settle();
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final search = find.widgetWithText(TextField, '搜索网站、网址、标签或分类');
      expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
      await tester.enterText(search, 'TRAE');
      await settle();
      expect(find.byWidgetPredicate((w)=>w is Text&&w.data=='TRAE'), findsOneWidget);
      expect(find.text('ChatGPT'), findsNothing);
      await tester.enterText(search, '');
      await settle();
      await tap(find.text('添加网站'));
      await tester.enterText(find.widgetWithText(TextField, '网站名称'), 'UI 持久网站');
      await tester.enterText(
        find.widgetWithText(TextField, '网址'),
        'example.org/ui',
      );
      await tap(find.widgetWithText(FilledButton, '保存'));
      final stored = await waitForPersisted(
        tester,
        repo.sites,
        (rows) => rows.any((s) => s.title == 'UI 持久网站'),
      );
      final site = stored.firstWhere((s) => s.title == 'UI 持久网站');
      expect(site.url, 'https://example.org/ui');
      await tester.enterText(search, 'UI 持久网站');
      await settle();
      await tap(find.byTooltip('网站操作').first);
      await tap(find.text('加入收藏'));
      await waitForPersisted(
        tester,
        () => repo.store.get(site.id),
        (row) => row?.flag('favorite') == true,
      );
      await tap(find.byTooltip('网站操作').first);
      await tap(find.widgetWithText(PopupMenuItem<String>,'固定首页')); 
      await waitForPersisted(
        tester,
        () => repo.store.get(site.id),
        (row) => row?.flag('pinned') == true,
      );
      await tap(find.byTooltip('导航管理'));
      await tap(find.text('分类管理'));
      await tap(find.text('新建分类'));
      await tester.enterText(find.widgetWithText(TextField, '分类名称'), 'UI 新分类');
      await tap(find.widgetWithText(FilledButton, '保存'));
      await waitForPersisted(
        tester,
        repo.categories,
        (rows) => rows.any((c) => c.name == 'UI 新分类'),
      );
      await tap(find.text('完成'));
      await tap(find.byTooltip('导航管理'));
      await tap(find.text('导入 / 导出'));
      expect(find.text('网站导入 / 导出'), findsOneWidget);
      await tap(find.text('关闭').last);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
    });
  }
}
