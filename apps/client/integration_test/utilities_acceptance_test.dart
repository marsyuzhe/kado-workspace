import 'package:links_toolbox/features/web_library/web_providers.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/utilities/image_service.dart';
import 'package:links_toolbox/features/utilities/utilities_page.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native utilities store actual bookmarks, image output, personal todos and responsive views',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp(
        'lt-utilities-native-',
      );
      final db = AppDatabase.file(
        File(p.join(temp.path, 'links_toolbox.sqlite')),
      );
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      final boundary = GlobalKey();
      final root = Directory(
        Platform.environment['LINKS_ARTIFACT_ROOT'] ??
            '${Directory.current.path}/../../artifacts/v15-regression',
      );
      final output = Directory(p.join(root.path, 'utilities'));
      await output.create(recursive: true);
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(p.join(output.path, name))
            .writeAsBytes(bytes!.buffer.asUint8List());
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      try {
        expect(
          await container
              .read(nativePlatformProvider)
              .availableDiskBytes(temp.path),
          greaterThan(0),
        );
        final source = img.Image(width: 320, height: 180, numChannels: 4)
          ..clear(img.ColorRgba8(100, 130, 180, 255));
        img.fillRect(
          source,
          x1: 30,
          y1: 30,
          x2: 290,
          y2: 150,
          color: img.ColorRgba8(200, 180, 140, 255),
        );
        final result = await container
            .read(imageToolProvider)
            .process(
              '原生验收图.png',
              img.encodePng(source),
              const ImageOptions(format: 'webp', width: 160),
              TaskCancellation(),
              confirmed: true,
            );
        final data = await (await container.read(ownedFilesProvider.future))
            .resolve(result.text('attachment'))
            .readAsBytes();
        expect(img.decodeWebP(data)!.width, 160);
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
        await tester.pumpAndSettle();
        container.read(routerProvider).go('/modules/utilities?view=legacy');
        await tester.pumpAndSettle();
        await container.read(webRepositoryProvider).initialize();
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加网站'));
        await tester.pumpAndSettle();
        await tester.enterText(field('网站名称'), 'Links 资料入口');
        await tester.enterText(
          field('网址'),
          'https://example.invalid/pixel-workspace',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        await capture('01-bookmarks.png');
        expect(
          (await container.read(recordStoreProvider).list('favorite'))
              .where((r) => r.title == 'Links 资料入口')
              .single
              .title,
          'Links 资料入口',
        );
        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('图片处理')),
        );
        await capture('02-image-tools.png');
        expect(find.text('原生验收图.png'), findsOneWidget);
        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('格式转换')),
        );
        await capture('03-image-conversion.png');
        await tester.tap(
          find.descendant(
            of: find.byType(TabBar),
            matching: find.text('个人时间轴'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('新建个人待办'));
        await tester.pumpAndSettle();
        await tester.enterText(field('标题'), '复核像素工作室');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          (await container.read(recordStoreProvider).list('personal_todo'))
              .single
              .title,
          '复核像素工作室',
        );
        expect(
          await container.read(recordStoreProvider).list('studio_task'),
          isEmpty,
        );
        await capture('04-personal-timeline.png');
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await capture('05-personal-mobile-layout.png');
        await tester.ensureVisible(
          find.descendant(of: find.byType(TabBar), matching: find.text('图片处理')),
        );
        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('图片处理')),
        );
        await capture('06-image-mobile-layout.png');
        final renameRoot = await Directory(p.join(temp.path, 'rename-fixture'))
            .create();
        for (var i = 0; i < 30; i++) {
          await File(p.join(renameRoot.path, '测试$i.txt'))
              .writeAsString('native content $i');
        }
        final renameService = container.read(archiveServiceProvider);
        final scan = await ArchiveScanner().scan(
          renameRoot.path,
          TaskCancellation(),
        );
        final plan = await renameService.plan(
          scan.files,
          'rename',
          TaskCancellation(),
          stagedRename: true,
          rule: const RenameRule(
            prefix: '旅行_',
            sequence: true,
            keepOriginal: false,
            sequenceStep: 2,
          ),
        );
        final jobs = container.read(utilityJobsProvider);
        final job = await jobs.submit(
          'renamer',
          'rename',
          '原生30文件重命名',
          {},
          confirmed: true,
          run: (ctx, _) async {
            final journal = await renameService.execute(
              plan,
              ctx.cancellation,
              confirmed: true,
              onProgress: (n, t) => ctx.progress(n, t, force: true),
            );
            await ctx.output(journal.id);
            expect(journal.text('status'), 'finished');
            return journal.id;
          },
        );
        container.read(routerProvider).go('/modules/utilities');
        await tester.pumpAndSettle();
        await jobs.waitIdle();
        final completed = await jobs.repository.require(job.id);
        expect(utilityJobStatus(completed), UtilityJobStatus.succeeded);
        for (final file in plan.files) {
          expect(
            await archiveHash(File(file.target), TaskCancellation()),
            file.hash,
          );
        }
        final journal = (await container
            .read(recordStoreProvider)
            .get(completed.text('resultReference')))!;
        expect(
          (await renameService.undo(journal, confirmed: true)).text('status'),
          'undone',
        );
        for (final file in plan.files) {
          expect(
            await archiveHash(File(file.source), TaskCancellation()),
            file.hash,
          );
        }
        for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
          await tester.binding.setSurfaceSize(size);
          for (final id in [
            'utilities',
            'renamer',
            'image_studio',
            'converter',
            'bookmarks',
            'utility_jobs',
          ]) {
            container.read(routerProvider).go('/modules/$id');
            await tester.pumpAndSettle();
            await capture('v22-$id-${size.width.toInt()}.png');
          }
          container.read(routerProvider).go('/modules/converter');
          await tester.pumpAndSettle();
          for (final tab in ['音频与视频', '文本文档']) {
            await tester.tap(find.text(tab));
            await tester.pumpAndSettle();
            await capture(
              'v22-converter-${tab == '文本文档' ? 'documents' : 'media'}-${size.width.toInt()}.png',
            );
          }
        }
        expect(await db.verifyIntegrity(), isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        container.dispose();
        await db.close();
        await temp.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
