import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/ui/app_theme.dart';
import 'package:links_toolbox/features/studio/studio_page.dart';
import 'package:links_toolbox/features/studio/studio_providers.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String firstId;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    await container.read(agentRuntimeProvider).initialize();
    final repo = container.read(studioRepositoryProvider);
    firstId = (await repo.createTask(
      title: '资料检索',
      type: 'memory.search',
      agentId: 'nova',
      input: {'query': '资料'},
      submissionId: 'ui-one',
    )).id;
    await repo.createTask(
      title: '历史检查',
      type: 'studio.history',
      agentId: 'patch',
      input: {},
      submissionId: 'ui-two',
    );
  });
  tearDown(() async {
    await container.read(agentRuntimeProvider).dispose();
    container.dispose();
    await db.close();
  });
  testWidgets(
    'mobile task board filters real rows and persists priority edits',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: appTheme(Brightness.dark),
            home: const Scaffold(body: TaskCenter()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('资料检索'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byTooltip('调整排队优先级').last));
      await tester.pumpAndSettle();
      // SQLite's real transaction must run in the same real-async zone as
      // its reads. Pausing a virtual clock while awaiting a transaction that
      // still needs that clock would deadlock the test, not the application.
      await tester.runAsync(() async {
        await tester.tap(find.text('P3 · 最高'));
        await container.read(studioRepositoryProvider).requireTask(firstId);
      });
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(
          () => container.read(studioRepositoryProvider).requireTask(firstId),
        ))!.number('priority'),
        3,
      );
      await tester.enterText(find.byType(TextField), 'nova');
      await tester.pumpAndSettle();
      expect(find.text('资料检索'), findsOneWidget);
      expect(find.text('历史检查'), findsNothing);
      await tester.tap(find.text('看板'));
      await tester.pumpAndSettle();
      expect(find.text('待处理 · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final exported = await tester.runAsync(
        () => container.read(studioRepositoryProvider).exportHistory(),
      );
      expect(exported, contains('资料检索'));
      expect(exported, contains('priority'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
