import 'persistence_ui_support.dart';

import 'package:links_toolbox/features/web_library/web_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() => runUtilitiesScenario(const Size(320, 640));

// Each virtual-clock scenario has its own test isolate, like a separate app
// process. Shared production completion signals must not outlive that clock.
void runUtilitiesScenario(Size scenario) {
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  for (final size in [scenario]) {
    testWidgets(
      'utilities actual bookmark and personal todo workflows fit $size',
      (tester) async {
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
          await tester.pump(const Duration(milliseconds: 250));
        }

        Finder field(String label) => find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        );
        Future<void> waitForWrite(String kind) async {
          for (var i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            final rows = await tester.runAsync(
              () => container.read(recordStoreProvider).list(kind),
            );
            if (rows!.any(
              (r) => r.title == (kind == 'favorite' ? '真实书签' : '今天的个人事项'),
            )) {
              await settle();
              return;
            }
          }
          fail('The UI did not persist $kind');
        }

        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const LinksToolboxApp(),
            ),
          );
          await settle();
          container.read(routerProvider).go('/modules/utilities?view=legacy');
          await settle();
          await withPersistenceFrames(
            tester,
            () => container.read(webRepositoryProvider).initialize(),
          );
          await tester.pump(const Duration(milliseconds: 200));
          await tester.tap(find.text('添加网站'));
          await settle();
          await tester.enterText(field('网站名称'), '真实书签');
          await tester.enterText(field('网址'), 'https://example.invalid');
          await tester.ensureVisible(find.text('保存'));
          await tester.tap(find.text('保存'));
          await settle();
          await waitForWrite('favorite');
          expect(
            (await container.read(recordStoreProvider).list('favorite'))
                .where((r) => r.title == '真实书签')
                .single
                .title,
            '真实书签',
          );
          for (final tab in ['图片处理', '格式转换', '个人时间轴']) {
            await tester.ensureVisible(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text(tab),
              ),
            );
            await tester.tap(
              find.descendant(
                of: find.byType(TabBar),
                matching: find.text(tab),
              ),
            );
            await settle();
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.text('新建个人待办'));
          await settle();
          await tester.enterText(field('标题'), '今天的个人事项');
          await tester.ensureVisible(find.text('保存'));
          await tester.tap(find.text('保存'));
          await settle();
          await waitForWrite('personal_todo');
          expect(
            (await container.read(recordStoreProvider).list('personal_todo'))
                .single
                .title,
            '今天的个人事项',
          );
          expect(
            await container.read(recordStoreProvider).list('studio_task'),
            isEmpty,
          );
          await tester.tap(find.text('日历视图'));
          await settle();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle();
        }
      },
    );
  }
}
