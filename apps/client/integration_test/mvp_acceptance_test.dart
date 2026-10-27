import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native MVP render, persisted workflow and measured local operations',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('lt-mvp-acceptance-');
      final db = AppDatabase.file(
        File(p.join(temp.path, 'links_toolbox.sqlite')),
      );
      await db.initialize();
      final outputs = Directory(
        Platform.environment['LINKS_ARTIFACT_ROOT'] ??
            '${Directory.current.path}/../../artifacts',
      );
      final shots = Directory(p.join(outputs.path, 'screenshots'));
      await shots.create(recursive: true);
      final reports = Directory(p.join(outputs.path, 'reports'));
      await reports.create(recursive: true);
      final boundary = GlobalKey();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      final timings = <String, dynamic>{
        'platform': Platform.operatingSystem,
        'mode': 'native Windows integration debug; own fixture data',
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      };
      try {
        final watch = Stopwatch()..start();
        final project = await container
            .read(memoryRepositoryProvider)
            .project(
              'Links Toolbox',
              description: '将日常工具放在一个本地工作台。',
              stack: 'Flutter · SQLite',
              progress: '本地MVP验收',
            );
        final note = await container
            .read(memoryRepositoryProvider)
            .createNote(
              '日常工作流',
              body: '# 日常工作流\n\n- 收集一段文字\n- 保存到项目笔记\n- 检索中文内容\n- 预览并导出上下文\n\n> 这些记录来自验收专用临时数据库。',
              projectId: project.id,
              tags: ['工作流', '本地优先'],
              category: 'WORKFLOWS.md',
            );
        await container
            .read(clipboardRepositoryProvider)
            .snippet('写作检查提示词', '请检查下文的逻辑与表达，并保留原意。', tags: ['写作']);
        await container.read(clipboardProvider.notifier).service.capture({
          'type': 'text',
          'text': '想法与记录留在本机，需要时再明确选择内容。',
        });
        await container
            .read(hubRepositoryProvider)
            .addFavorite('我的记忆仓库', const TargetAction('module', 'memory'));
        final folder = await Directory(p.join(temp.path, 'files')).create();
        await File(p.join(folder.path, '工作说明.md')).writeAsString('验收文本，相同内容');
        await File(p.join(folder.path, '说明副本.txt')).writeAsString('验收文本，相同内容');
        await File(p.join(folder.path, '清单.txt')).writeAsString('另一份内容');
        final root = await container
            .read(archiveServiceProvider)
            .grant(folder.path);
        final scanWatch = Stopwatch()..start();
        final scan = await ArchiveScanner().scan(
          folder.path,
          TaskCancellation(),
        );
        timings['scanFixtureMs'] = scanWatch.elapsedMilliseconds;
        final hashWatch = Stopwatch()..start();
        expect(
          (await DuplicateDetector().find(
            scan.files,
            TaskCancellation(),
          )).single.length,
          2,
        );
        timings['duplicateFixtureMs'] = hashWatch.elapsedMilliseconds;
        await container.read(archiveServiceProvider).index(root, scan);
        await verifyCredentialStore(const SystemCredentialStore());
        timings['fixtureSetupAndSecureProbeMs'] = watch.elapsedMilliseconds;
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        final start = Stopwatch()..start();
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
        timings['initialWidgetSettleMs'] = start.elapsedMilliseconds;
        Future<void> capture(String filename, String route) async {
          container.read(routerProvider).go(route);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File(p.join(shots.path, filename))
              .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
        }

        await capture('01-hub-windows.png', '/');
        await capture('02-clipboard-windows.png', '/modules/clipboard');
        container.read(routerProvider).go('/modules/archive');
        await tester.pumpAndSettle();
        await tester.tap(find.text('files'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await capture('03-archive-windows.png', '/modules/archive');
        await capture('04-memory-windows.png', '/modules/memory');
        await capture(
          '05-memory-editor-windows.png',
          '/modules/memory?id=${note.id}',
        );
        await capture('06-ai-configuration-windows.png', '/modules/ai_desk');
        await capture('07-server-windows.png', '/modules/server');
        final searchWatch = Stopwatch()..start();
        final search = await container
            .read(searchServiceProvider)
            .search('工作流');
        expect(search.results.any((r) => r.id == note.id), true);
        timings['ChineseSearchFixtureMs'] = searchWatch.elapsedMilliseconds;
        await capture('08-settings-windows.png', '/settings');
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpAndSettle();
        await capture('09-hub-mobile-layout.png', '/');
        await capture('10-memory-mobile-layout.png', '/modules/memory');
        timings['screenshots'] = 'Actual Flutter native-engine widget renders. Mobile layouts are desktop engine viewport checks, not Android/iOS device screenshots.';
        await File(p.join(reports.path, 'performance-native.json'))
            .writeAsString(
              const JsonEncoder.withIndent('  ').convert(timings),
              flush: true,
            );
      } finally {
        await container.read(nativePlatformProvider).unregisterHotkey();
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
