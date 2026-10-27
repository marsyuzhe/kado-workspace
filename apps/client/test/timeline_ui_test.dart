import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/utilities/timeline_providers.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

import 'persistence_ui_support.dart';

void main() => runTimelineUi(const Size(320, 640));
void runTimelineUi(Size size) {
  late Directory temp;
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-timeline-ui-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    await container.read(utilityJobsReadyProvider.future);
  });
  tearDown(() async {
    await container.read(timelineReminderControllerProvider.notifier).stop();
    await container.read(utilityJobsProvider).dispose();
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  testWidgets(
    'timeline editing recurrence, opt-in notice, banner navigation and acknowledgement fit $size',
    (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await tester.pumpAndSettle();
      }

      Future<void> reveal(Finder f) async {
        if (f.evaluate().isEmpty) {
          final vertical = find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .hitTestable()
              .first;
          await tester.scrollUntilVisible(f, 240, scrollable: vertical);
          await settle();
        }
        await Scrollable.of(
          tester.element(f),
          axis: Axis.vertical,
        ).position.ensureVisible(tester.renderObject(f), alignment: .5);
        await settle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const LinksToolboxApp(),
          ),
        );
        await settle();
        container.read(routerProvider).go('/modules/timeline');
        await settle();
        await tester.runAsync(() => tester.tap(find.text('添加个人待办')));
        await settle();
        await tester.enterText(field('待办标题'), 'UI月末计划');
        await reveal(field('截止时间 YYYY-MM-DD HH:MM'));
        await tester.enterText(
          field('截止时间 YYYY-MM-DD HH:MM'),
          '2100-01-31 09:00',
        );
        await reveal(field('应用内提醒时间 YYYY-MM-DD HH:MM'));
        await tester.enterText(
          field('应用内提醒时间 YYYY-MM-DD HH:MM'),
          '2000-01-01 08:00',
        );
        final rule = find.widgetWithText(
          DropdownButtonFormField<String>,
          '不重复',
        );
        await reveal(rule);
        await tester.runAsync(() => tester.tap(rule));
        await settle();
        await tester.runAsync(() => tester.tap(find.text('每月').last));
        await settle();
        await reveal(field('标签（逗号分隔）'));
        await tester.enterText(field('标签（逗号分隔）'), 'QA,月底');
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        final row = (await waitForPersisted(
          tester,
          () => container.read(timelineServiceProvider).all(),
          (rows) => rows.length == 1,
        )).single;
        expect(row.text('recurrenceRule'), 'monthly');
        expect(row.strings('tags'), ['QA', '月底']);
        await reveal(find.text('开启应用内提醒'));
        await tester.runAsync(() => tester.tap(find.text('开启应用内提醒')));
        await settle();
        await waitForPersisted(
          tester,
          () async =>
              container.read(timelineReminderControllerProvider).enabled,
          (enabled) => enabled,
        );
        await withPersistenceFrames(
          tester,
          () => container
              .read(timelineReminderControllerProvider.notifier)
              .poll(),
        );
        await settle();
        expect(find.text('个人日程：1条应用内提醒'), findsOneWidget);
        container.read(routerProvider).go('/');
        await settle();
        await tester.tap(find.text('个人日程：1条应用内提醒'));
        await settle();
        expect(find.text('个人待办与时间线'), findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('查看提醒收件箱')));
        await settle();
        await tester.runAsync(() => tester.tap(find.text('知道了')));
        await waitForPersisted(
          tester,
          () => container
              .read(timelineReminderServiceProvider)
              .watchPending()
              .first,
          (rows) => rows.isEmpty,
        );
        await settle();
        expect(find.text('当前没有待确认提醒'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await settle();
        expect(find.text('个人日程：1条应用内提醒'), findsNothing);
        final complete = find.widgetWithText(TextButton, '已完成');
        await reveal(complete);
        await tester.runAsync(() => tester.tap(complete.hitTestable()));
        await settle();
        final rows = await waitForPersisted(
          tester,
          () => container.read(timelineServiceProvider).all(),
          (rows) => rows.length == 2,
        );
        expect(rows.length, 2);
        expect(rows.where((r) => r.text('status') == 'done').length, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await withPersistenceFrames(
          tester,
          () => container
              .read(timelineReminderControllerProvider.notifier)
              .stop(),
        );
        await tester.pumpWidget(const SizedBox());
        await settle();
      }
    },
  );
}
