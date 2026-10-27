import 'persistence_ui_support.dart';

import 'package:links_toolbox/features/web_library/web_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/modules/module_registry.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

void main() {
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
    final engine = container.read(utilityJobsProvider);
    await engine.initialize();
    await engine.submit(
      'converter',
      'real_error',
      '无效输入测试',
      {},
      confirmed: true,
      run: (_, _) async {
        throw StateError('owned test');
      },
    );
    await engine.waitIdle();
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  testWidgets(
    'catalog searches independent tools and all available utility pages fit phone and desktop',
    (tester) async {
      Future<void> settle() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }

        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
      }

      try {
        for (final size in [const Size(320, 640), const Size(1440, 1000)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const LinksToolboxApp(),
            ),
          );
          await settle();
          container.read(routerProvider).go('/modules/utilities');
          await settle();
          expect(find.text('查看工具任务'), findsOneWidget);
          await tester.enterText(find.byType(TextField).first, '重命名');
          await settle();
          expect(find.text('08 批量重命名'), findsOneWidget);
          expect(find.text('07 格式转换'), findsNothing);
          for (final id in [
            'renamer',
            'image_studio',
            'converter',
            'bookmarks',
            'utility_jobs',
            'transcribe',
            'media_library',
            'software_library',
            'environment_snapshot',
          ]) {
            expect(moduleById(id), isNotNull);
            container.read(routerProvider).go('/modules/$id');
            if (id == 'bookmarks') {
              await withPersistenceFrames(
                tester,
                () => container.read(webRepositoryProvider).initialize(),
              );
            }
            await settle();
            expect(tester.takeException(), isNull, reason: '$size/$id');
          }
          container.read(routerProvider).go('/modules/converter');
          await settle();
          for (final tab in ['音频与视频', '文本文档']) {
            await tester.tap(find.text(tab));
            await settle();
            expect(tester.takeException(), isNull);
          }
        }
        container.read(routerProvider).go('/modules/utility_jobs');
        await settle();
        expect(find.text('无效输入测试'), findsOneWidget);
        expect(find.textContaining('失败 ·'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
