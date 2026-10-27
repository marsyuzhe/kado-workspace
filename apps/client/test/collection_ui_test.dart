import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/utilities/collection_service.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

import 'collection_service_test.dart' show collectionFixture;

import 'persistence_ui_support.dart';

void main() => runCollectionUi(const Size(320, 640));
void runCollectionUi(Size size) {
  late Directory temp;
  late AppDatabase db;
  late ProviderContainer container;
  late String cardId;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-collection-ui-');
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    final service = container.read(collectionProvider),
        card = await service.save(
          const CollectionInput(
            name: 'UI收藏卡',
            playerOrCharacter: '测试人物',
            collectionType: '动漫卡',
            serialNumber: 8,
            serialTotal: 49,
          ),
        );
    cardId = card.id;
    final jobs = container.read(utilityJobsProvider),
        image = await jobs.submit(
          'collection_cards',
          'image',
          'UI实际图片副本',
          {'cardId': card.id},
          confirmed: true,
          run: (job, _) async => (await service.addImage(
            card,
            'ui-front.png',
            collectionFixture(),
            'front',
            job,
          )).id,
        );
    await jobs.waitFor(image.id);
    await container.read(utilityJobsReadyProvider.future);
    await container.read(ownedFilesProvider.future);
  });
  tearDown(() async {
    await container.read(utilityJobsProvider).dispose();
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  testWidgets(
    'collection actual structured edits, costs, sold profit, original gallery and favorite fit $size',
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
        await Scrollable.of(
          tester.element(finder),
          axis: Axis.vertical,
        ).position.ensureVisible(tester.renderObject(finder), alignment: .5);
        await settle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> click(String label) async {
        final finder = find.text(label);
        await reveal(finder);
        await tester.runAsync(() => tester.tap(finder.hitTestable()));
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
        container.read(routerProvider).go('/modules/collection_cards');
        await settle();
        await click('编辑资料');
        await tester.ensureVisible(field('编数序号（可空）'));
        await tester.enterText(field('编数序号（可空）'), '66');
        await tester.enterText(field('编数总量（可空）'), '99');
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        var card = (await waitForPersisted<ToolRecord?>(
          tester,
          () => container.read(recordStoreProvider).get(cardId),
          (r) => r != null && r.number('serialNumber') == 66,
        ))!;
        expect(CollectionService.serial(card), '66/99');
        await click('成本/出售');
        await tester.enterText(field('购买价（赠送可填0）'), '12.00');
        await tester.enterText(field('运费'), '2.00');
        await tester.enterText(field('购入平台手续费'), '1.00');
        await tester.ensureVisible(field('手动估值（可空）'));
        await tester.enterText(field('手动估值（可空）'), '20.00');
        final ownedStatus = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('仍拥有'),
            )
            .last;
        await reveal(ownedStatus);
        await tester.runAsync(() => tester.tap(ownedStatus.hitTestable()));
        await settle();
        await tester.runAsync(() => tester.tap(find.text('已出售').last));
        await settle();
        await tester.ensureVisible(field('成交价（已出售时必填）'));
        await tester.enterText(field('成交价（已出售时必填）'), '25.00');
        await tester.enterText(field('售出平台手续费'), '1.00');
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        card = (await waitForPersisted<ToolRecord?>(
          tester,
          () => container.read(recordStoreProvider).get(cardId),
          (r) =>
              r != null && r.flag('sold') && r.number('purchaseMinor') == 1200,
        ))!;
        expect(CollectionService.cost(card), 1500);
        expect(CollectionService.profit(card), 900);
        expect(card.number('manualValueMinor'), 2000);
        await click('资料与图片（1）');
        expect(find.text('正面 · ui-front.png'), findsOneWidget);
        expect(find.byType(Image).hitTestable(), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭图片窗口'));
        await settle();
        final favorite = find.byTooltip('设为喜爱');
        await reveal(favorite);
        await tester.runAsync(() => tester.tap(favorite.hitTestable()));
        await settle();
        expect(
          (await tester.runAsync(
            () => container.read(recordStoreProvider).get(cardId),
          ))!.flag('favorite'),
          true,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
      }
    },
  );
}
