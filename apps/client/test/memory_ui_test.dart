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
  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LinksToolboxApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  testWidgets(
    'editor autosaves before navigation and blocks navigation on conflict',
    (tester) async {
      final note = await container
          .read(memoryRepositoryProvider)
          .createNote('标题', body: '初始');
      await mount(tester, const Size(1300, 1000));
      final router = container.read(routerProvider);
      router.go('/modules/memory?id=${note.id}');
      await tester.pumpAndSettle();
      await tester.enterText(field('Markdown正文'), '刚输入后立刻切换的内容');
      router.go('/');
      await tester.pumpAndSettle();
      expect(
        (await container.read(recordStoreProvider).get(note.id))!.body,
        '刚输入后立刻切换的内容',
      );
      router.go('/modules/memory?id=${note.id}');
      await tester.pumpAndSettle();
      final external = (await container
          .read(recordStoreProvider)
          .get(note.id))!;
      await container
          .read(recordStoreProvider)
          .save(external.copyWith(body: '其他窗口更新'));
      await tester.enterText(field('Markdown正文'), '我的未保存草稿');
      router.go('/');
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/modules/memory');
      expect(find.textContaining('记录已在另一个操作中更新'), findsOneWidget);
      expect(
        (tester.widget<TextField>(field('Markdown正文')).controller!).text,
        '我的未保存草稿',
      );
      expect(
        (await container.read(recordStoreProvider).get(note.id))!.body,
        '其他窗口更新',
      );
    },
  );
  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets('real module pages fit $size', (tester) async {
      await mount(tester, size);
      final router = container.read(routerProvider);
      for (final id in [
        'clipboard',
        'archive',
        'memory',
        'ai_desk',
        'server',
      ]) {
        router.go('/modules/$id');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
