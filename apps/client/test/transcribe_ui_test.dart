import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/utilities/transcribe_service.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late ToolRecord sample;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    sample = await RecordStore(db).create(
      'transcript',
      '人工字幕编辑样本',
      data: {
        'status': 'complete',
        'modelName': '手工编辑测试，不宣称模型识别',
        'language': 'zh',
        'segments': [
          const TranscriptSegment(0, 2000, '第一句样本').toJson(),
          const TranscriptSegment(2000, 4000, '第二句样本').toJson(),
        ],
      },
    );
    await container.read(utilityJobsReadyProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });
  testWidgets(
    'phone transcript editor saves real corrections, split and merge with revisions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await tester.pumpAndSettle();
      }

      Future<void> menu(String label) async {
        final popup = find.byType(PopupMenuButton<String>).first;
        final element = tester.element(popup);
        await Scrollable.of(
          element,
          axis: Axis.vertical,
        ).position.ensureVisible(tester.renderObject(popup), alignment: .5);
        await settle();
        await tester.runAsync(() => tester.tap(popup.hitTestable()));
        await settle();
        await tester.runAsync(() => tester.tap(find.text(label)));
        await settle();
      }

      Future<ToolRecord> current() async => (await tester.runAsync(
        () => container.read(recordStoreProvider).get(sample.id),
      ))!;
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const LinksToolboxApp(),
          ),
        );
        await settle();
        container
            .read(routerProvider)
            .go('/modules/transcribe?id=${sample.id}');
        await settle();
        expect(find.text('人工字幕编辑样本'), findsWidgets);
        await menu('修订文字和时间');
        await tester.enterText(field('文字'), '更正内容');
        await tester.enterText(field('结束 HH:MM:SS,mmm'), '00:00:01,800');
        await tester.ensureVisible(find.text('保存'));
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        expect(transcriptSegments(await current()).first.text, '更正内容');
        await menu('拆分字幕');
        await tester.enterText(field('前半句字符数'), '2');
        await tester.enterText(field('拆分时间 HH:MM:SS,mmm'), '00:00:01,000');
        await tester.ensureVisible(find.text('保存'));
        await tester.runAsync(() => tester.tap(find.text('保存')));
        await settle();
        expect(transcriptSegments(await current()).length, 3);
        await menu('与下一条合并');
        await settle();
        expect(transcriptSegments(await current()).length, 2);
        expect((await current()).number('editCount'), 3);
        expect(
          (await tester.runAsync(
            () =>
                container.read(recordStoreProvider).list('transcript_revision'),
          ))!.length,
          3,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
