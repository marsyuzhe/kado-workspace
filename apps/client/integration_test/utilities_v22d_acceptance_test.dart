import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/utilities/collection_service.dart';
import 'package:links_toolbox/features/utilities/collection_page.dart';
import 'package:links_toolbox/features/utilities/finance_service.dart';
import 'package:links_toolbox/features/utilities/timeline_providers.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Batch D imports exact bills, preserves card original, fires a real timer reminder and reopens SQLite',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('lt-v22d-native-');
      var db = AppDatabase.file(
        File(p.join(temp.path, 'links_toolbox.sqlite')),
      );
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
          ownedFilesProvider.overrideWith((ref) async => OwnedFileStore(temp)),
        ],
      );
      final artifact = await Directory(
            p.join(
              Platform.environment['LINKS_ARTIFACT_ROOT'] ??
                  '${Directory.current.path}/../../artifacts/v22-regression',
              'batch-d',
            ),
          ).create(recursive: true),
          boundary = GlobalKey();
      var disposed = false;
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await settle();
        expect(tester.takeException(), isNull);
        final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1),
            data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(p.join(artifact.path, name))
            .writeAsBytes(data!.buffer.asUint8List());
      }

      try {
        final store = container.read(recordStoreProvider),
            jobs = container.read(utilityJobsProvider),
            finance = container.read(financeProvider),
            collection = container.read(collectionProvider);
        await container.read(utilityJobsReadyProvider.future);
        Future<ToolRecord> execute(
          String module,
          String op,
          UtilityJobHandler run,
        ) async {
          final job = await jobs.submit(
                module,
                op,
                op,
                {},
                confirmed: true,
                run: run,
              ),
              done = await jobs.waitFor(job.id);
          expect(
            utilityJobStatus(done),
            UtilityJobStatus.succeeded,
            reason: done.text('errorMessage'),
          );
          return (await store.get(done.text('resultReference')))!;
        }

        final bill = Uint8List.fromList(
          utf8.encode(
            '日期,收/支,金额,商户,交易ID,原交易单号\n2026-10-01 09:00,收入,1000.00,合成测试收入,NATIVE-I,\n2026-10-02 12:00,支出,30.10,合成测试餐饮,NATIVE-E,\n2026-10-03 12:00,退款,10.00,合成退款,NATIVE-R,NATIVE-E\n2026-10-04 12:00,内部转账,500.00,自己的账户,NATIVE-T,\n',
          ),
        );
        final input = await File(p.join(temp.path, '合成验收账单.csv'))
                .writeAsBytes(bill),
            table = await finance.read(await input.readAsBytes(), '合成验收账单.csv'),
            mapping = FinanceMapping.detect(table);
        final preview = await execute(
          'finance',
          'preview',
          (ctx, _) async =>
              (await finance.preview(table, mapping, '合成验收账单.csv', ctx)).id,
        );
        await execute(
          'finance',
          'import',
          (ctx, _) async =>
              (await finance.importPreview(preview, ctx, confirmed: true)).id,
        );
        final duplicate = await execute(
          'finance',
          'preview',
          (ctx, _) async =>
              (await finance.preview(table, mapping, '合成验收账单.csv', ctx)).id,
        );
        await execute(
          'finance',
          'deduplicated-import',
          (ctx, _) async =>
              (await finance.importPreview(duplicate, ctx, confirmed: true)).id,
        );
        final ledger = await finance.all(),
            report = FinanceReport.calculate(ledger, 'CNY', month: '2026-10');
        expect(ledger.length, 4);
        expect(report.income, 100000);
        expect(report.expense, 3010);
        expect(report.refunds, 1000);
        expect(report.netExpense, 2010);
        expect(report.balance, 97990);
        final output = await Directory(p.join(temp.path, '输出')).create();
        final csv = await execute(
          'finance',
          'export',
          (ctx, _) async =>
              (await finance.exportRows(ledger, output.path, ctx)).id,
        );
        expect(await File(csv.text('outputPath')).exists(), true);
        var card = await collection.save(
          const CollectionInput(
            name: 'CR7 合成卡片验收',
            playerOrCharacter: 'C罗',
            collectionType: '足球球星卡',
            brand: 'QA ONLY',
            serialNumber: 8,
            serialTotal: 49,
            notes: '测试记录，非市场数据',
          ),
        );
        card = await collection.setCosts(
          card,
          currency: 'CNY',
          purchase: '100',
          shipping: '10',
          buyFee: '5',
          sold: true,
          sale: '200',
          sellingFee: '10',
          manualValue: '180',
          manualValueSource: '合成手动估值，不代表市价',
        );
        expect(CollectionService.cost(card), 11500);
        expect(CollectionService.profit(card), 7500);
        final image = img.Image(width: 640, height: 320);
        img.fill(image, color: img.ColorRgb8(53, 80, 152));
        img.fillRect(
          image,
          x1: 320,
          y1: 0,
          x2: 639,
          y2: 319,
          color: img.ColorRgb8(194, 97, 75),
        );
        final original = Uint8List.fromList(img.encodePng(image)),
            source = await File(p.join(temp.path, '合成卡片.png'))
                .writeAsBytes(original);
        final photo = await execute(
          'collection_cards',
          'add-photo',
          (ctx, _) async => (await collection.addImage(
            card,
            '合成卡片.png',
            await source.readAsBytes(),
            'front',
            ctx,
          )).id,
        );
        final owned = await container.read(ownedFilesProvider.future),
            stored = await owned
                .resolve(photo.text('attachment'))
                .readAsBytes();
        expect(sha256.convert(stored), sha256.convert(original));
        expect(await source.readAsBytes(), original);
        final now = DateTime.now().toUtc(),
            reminderAt = now.add(const Duration(seconds: 2));
        final todo = await container
            .read(timelineServiceProvider)
            .save(
              '真实计时器验收提醒',
              description: '只在本次独立测试进程中检查',
              due: now.add(const Duration(hours: 1)),
              reminderAt: reminderAt,
              tags: ['原生验收'],
            );
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: boundary,
              child: const LinksToolboxApp(),
            ),
          ),
        );
        await settle();
        await tester.runAsync(
          () => container
              .read(timelineReminderControllerProvider.notifier)
              .enable(true),
        );
        expect(await store.list('personal_reminder'), isEmpty);
        // Wait for the production 15-second Timer, not a direct poll or fake clock.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 17)),
        );
        await settle();
        final notices = (await tester.runAsync(
          () => store.list('personal_reminder'),
        ))!;
        expect(notices.length, 1);
        expect(notices.single.text('taskId'), todo.id);
        expect(
          DateTime.parse(notices.single.text('firedAt')).isBefore(reminderAt),
          false,
        );
        expect(find.text('个人日程：1条应用内提醒'), findsOneWidget);
        await File(p.join(artifact.path, 'native-evidence.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'finance': {
              'rows': ledger.length,
              'incomeMinor': report.income,
              'expenseMinor': report.expense,
              'refundsMinor': report.refunds,
              'netExpenseMinor': report.netExpense,
              'balanceMinor': report.balance,
            },
            'collection': {
              'serial': CollectionService.serial(card),
              'costMinor': CollectionService.cost(card),
              'realizedMinor': CollectionService.profit(card),
              'originalSha256': sha256.convert(original).toString(),
              'storedSha256': sha256.convert(stored).toString(),
            },
            'reminder': notices.single.data,
            'realTimerWaitSeconds': 17,
            'systemNotification': false,
            'physicalMobileDevicesVerified': false,
          }),
        );
        for (final size in [
          const Size(1440, 1000),
          const Size(390, 844),
          const Size(320, 640),
        ]) {
          await tester.binding.setSurfaceSize(size);
          for (final id in ['finance', 'collection_cards', 'timeline']) {
            container.read(routerProvider).go('/modules/$id');
            await capture('$id-${size.width.toInt()}.png');
            if (id == 'finance') {
              await tester.ensureVisible(find.text('收支统计'));
              await tester.tap(find.text('收支统计'));
              await capture('finance-stats-${size.width.toInt()}.png');
            }
          }
        }
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        container.read(routerProvider).go('/modules/collection_cards');
        await settle();
        await tester.runAsync(() async {
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(CollectionPage)),
              builder: (_) => CollectionGallery(cardId: card.id),
            ),
          );
        });
        await capture('collection-gallery-1440.png');
        await tester.tap(find.byTooltip('关闭图片窗口'));
        await settle();
        expect(await db.verifyIntegrity(), true);
        await tester.runAsync(
          () => container
              .read(timelineReminderControllerProvider.notifier)
              .stop(),
        );
        await tester.pumpWidget(const SizedBox());
        await settle();
        await jobs.dispose();
        container.dispose();
        disposed = true;
        await db.close();
        db = AppDatabase.file(File(p.join(temp.path, 'links_toolbox.sqlite')));
        await db.initialize();
        final reopened = RecordStore(db);
        expect((await reopened.list('finance_transaction')).length, 4);
        expect((await reopened.get(card.id))!.number('serialNumber'), 8);
        expect((await reopened.get(todo.id))!.title, '真实计时器验收提醒');
        expect((await reopened.list('personal_reminder')).length, 1);
        expect(await db.verifyIntegrity(), true);
      } finally {
        if (!disposed) {
          await container
              .read(timelineReminderControllerProvider.notifier)
              .stop();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await container.read(utilityJobsProvider).dispose();
          container.dispose();
        }
        await db.close();
        await temp.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
