import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/utilities/finance_service.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

import 'persistence_ui_support.dart';

void main() => runFinanceUiScenario(const Size(320, 640));
void runFinanceUiScenario(Size size) {
  late Directory temp;
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-finance-ui-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    final service = container.read(financeProvider),
        jobs = container.read(utilityJobsProvider);
    final table = await service.read(
      Uint8List.fromList(
        utf8.encode(
          '日期,收/支,金额,商户,交易ID\n2026-10-01 12:00,支出,12.34,UI合成消费,ui-001\n',
        ),
      ),
      'ui.csv',
    );
    // Column mapping is explicit here; no fake transaction or network result.
    final mapping = FinanceMapping({
      'date': 0,
      'type': 1,
      'amount': 2,
      'merchant': 3,
      'transactionId': 4,
    }, source: 'csv');
    final job = await jobs.submit(
      'finance',
      'preview',
      'UI实际账单预览',
      {},
      confirmed: true,
      run: (ctx, _) async =>
          (await service.preview(table, mapping, 'ui.csv', ctx)).id,
    );
    await jobs.waitFor(job.id);
    await container.read(utilityJobsReadyProvider.future);
  });
  tearDown(() async {
    await container.read(utilityJobsProvider).dispose();
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  testWidgets(
    'finance actual preview confirmation, persisted editing, statistics and budgets fit $size',
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
        // An active import has an indeterminate progress animation. Advance
        // transition frames here; persistence has its own real-IO barrier below.
        await tester.pump(const Duration(milliseconds: 250));
      }

      Future<void> reveal(Finder finder) async {
        if (finder.evaluate().isEmpty) {
          final vertical = find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .hitTestable()
              .first;
          await tester.scrollUntilVisible(finder, 240, scrollable: vertical);
          await settle();
        }
        final element = tester.element(finder);
        await Scrollable.of(
          element,
          axis: Axis.vertical,
        ).position.ensureVisible(tester.renderObject(finder), alignment: .5);
        await settle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> tab(String name) async {
        await tester.ensureVisible(find.text(name));
        await tester.tap(find.text(name));
        await settle();
      }

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const LinksToolboxApp(),
          ),
        );
        await settle();
        container.read(routerProvider).go('/modules/finance');
        await settle();
        await tab('导入预览');
        final confirmImport = find.text('确认导入这些交易');
        await reveal(confirmImport);
        await tester.runAsync(() => tester.tap(confirmImport.hitTestable()));
        await settle();
        expect(find.text('确认将这些交易写入本地账本？'), findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('确认')));
        await settle();
        await withPersistenceFrames(
          tester,
          () => container.read(utilityJobsProvider).waitIdle(),
        );
        await settle();
        final rows = await waitForPersisted(
          tester,
          () => container.read(financeProvider).all(),
          (rows) => rows.length == 1,
        );
        expect(rows.single.number('amountMinor'), 1234);
        await tab('交易明细');
        expect(find.text('本地交易明细'), findsOneWidget);
        final edit = find.text('编辑交易');
        await reveal(edit);
        await tester.runAsync(() => tester.tap(edit.hitTestable()));
        await settle();
        await tester.ensureVisible(field('分类（可自定义）'));
        await tester.enterText(field('分类（可自定义）'), '学习');
        await tester.ensureVisible(field('说明/备注'));
        await tester.enterText(field('说明/备注'), 'UI实际保存备注');
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        final changed = (await waitForPersisted(
          tester,
          () => container.read(financeProvider).all(),
          (rows) =>
              rows.length == 1 &&
              rows.single.text('category') == '学习' &&
              rows.single.body == 'UI实际保存备注',
        )).single;
        expect(changed.text('category'), '学习');
        expect(changed.body, 'UI实际保存备注');
        await tab('收支统计');
        expect(find.text('收支统计'), findsWidgets);
        expect(find.text('CNY 12.34'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tab('月度预算');
        await tester.runAsync(() => tester.tap(find.text('设置月度预算')));
        await settle();
        await tester.enterText(field('月份 YYYY-MM'), '2026-10');
        await tester.enterText(field('分类（留空为总预算）'), '学习');
        await tester.enterText(field('预算金额'), '50.00');
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        final budgets = await waitForPersisted(
          tester,
          () => container.read(recordStoreProvider).list('finance_budget'),
          (rows) =>
              rows.length == 1 && rows.single.number('amountMinor') == 5000,
        );
        expect(budgets.single.number('amountMinor'), 5000);
        expect(budgets.single.text('category'), '学习');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
      }
    },
  );
}
