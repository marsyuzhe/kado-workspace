import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/studio/office_domain.dart';
import 'package:links_toolbox/features/studio/office_game.dart';
import 'package:links_toolbox/features/studio/office_presentation.dart';
import 'package:links_toolbox/features/studio/studio_providers.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Flame office clicks, A star movement, actual Memory task, approval and reopen',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('lt-studio-native-');
      final file = File(p.join(temp.path, 'fixture.sqlite'));
      var db = AppDatabase.file(file);
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      final boundary = GlobalKey();
      final output = Directory(
        Platform.environment['LINKS_STUDIO_ARTIFACT_ROOT'] ??
            '${Directory.current.path}/../../artifacts/v2-studio',
      );
      await output.create(recursive: true);
      final checks = <String, dynamic>{
        'platform': 'Windows native Flutter + Flame',
        'data': 'owned temporary fixture',
        'externalApiVerified': false,
      };
      final frameTimings = <ui.FrameTiming>[];
      void timings(List<ui.FrameTiming> frames) => frameTimings.addAll(frames);
      tester.binding.addTimingsCallback(timings);
      Future<void> waitFor(bool Function() condition, {int steps = 300}) async {
        for (var i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (condition()) return;
        }
        fail('Native condition did not complete');
      }

      Future<void> capture(String name) async {
        await tester.pump();
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(p.join(output.path, name))
            .writeAsBytes(bytes!.buffer.asUint8List());
      }

      try {
        final memory = container.read(memoryRepositoryProvider);
        final project = await memory.project('Pixel Workspace 验收');
        await memory.createNote(
          '办公室资料',
          body: '真正的本地笔记检索与任务审批工作流。',
          projectId: project.id,
        );
        await container.read(agentRuntimeProvider).initialize();
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
        await capture('01-workspace.png');
        container.read(routerProvider).go('/modules/studio');
        await waitFor(
          () => find.byType(GameWidget<OfficeGame>).evaluate().isNotEmpty,
        );
        final widget = tester.widget<GameWidget<OfficeGame>>(
          find.byType(GameWidget<OfficeGame>),
        );
        final game = widget.game!;
        await waitFor(
          () =>
              game.actors.length == 6 &&
              game.actors.values.every((a) => a.isMounted),
        );
        // Mount completion precedes the first visual update. In a native
        // automation run the window may be inactive, so resume this owned
        // test scene explicitly and wait for actual hit-test geometry.
        game.resumeEngine();
        await waitFor(
          () => game.actors.entries.every((entry) {
            final motion = container
                .read(agentRuntimeProvider)
                .movement
                .actors[entry.key]!;
            return (entry.value.x - motion.x).abs() < 1 &&
                (entry.value.y - motion.y).abs() < 1;
          }),
        );
        expect(tester.takeException(), isNull);
        checks['actors'] = game.actors.keys.toList();
        Offset worldPoint(double x, double y) {
          final point = game.camera.localToGlobal(Vector2(x, y));
          return tester.getTopLeft(find.byType(GameWidget<OfficeGame>)) +
              Offset(point.x, point.y);
        }

        final nova = container
            .read(agentRuntimeProvider)
            .movement
            .actors['nova']!;
        final actorCanvas = game.camera.localToGlobal(
          Vector2(nova.x, nova.y - 22),
        );
        expect(game.actorAt(Offset(actorCanvas.x, actorCanvas.y)), 'nova');
        await tester.tapAt(worldPoint(nova.x, nova.y - 22));
        // The double-tap recognizer may hold the first tap past 200ms.
        // Observe the actual selection result instead of a fixed delay.
        await waitFor(
          () => find.text('Nova').hitTestable().evaluate().isNotEmpty,
        );
        expect(find.text('Nova'), findsOneWidget);
        checks['actorSelection'] = 'actual pointer tap';
        await tester.tapAt(worldPoint(336, 316));
        await waitFor(
          () =>
              container
                  .read(agentRuntimeProvider)
                  .movement
                  .actors['links']!
                  .cell ==
              const Cell(10, 9),
        );
        await waitFor(
          () => !container
              .read(agentRuntimeProvider)
              .movement
              .actors['links']!
              .walking,
        );
        checks['userMoveTarget'] = '10,9';
        await expectLater(
          container.read(agentRuntimeProvider).moveUser(const Cell(2, 3)),
          throwsA(anything),
        );
        checks['blockedFurniture'] = 'rejected';
        await capture('02-office.png');
        for (final mode in [
          OfficeEnvironment.day,
          OfficeEnvironment.evening,
          OfficeEnvironment.night,
        ]) {
          await tester.tap(find.byTooltip('办公室昼夜环境'));
          await tester.pump(const Duration(milliseconds: 220));
          await tester.tap(find.text(mode.label).last);
          await waitFor(
            () =>
                container.read(agentRuntimeProvider).presentation.environment ==
                mode,
          );
          await tester.pump(const Duration(milliseconds: 400));
          await capture('06-office-${mode.name}.png');
        }
        checks['environmentModes'] = ['day', 'evening', 'night'];
        final byte = container
            .read(agentRuntimeProvider)
            .movement
            .actors['byte']!;
        await tester.longPressAt(worldPoint(byte.x, byte.y - 22));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('聚焦角色'), findsOneWidget);
        await capture('07-actor-menu.png');
        await tester.tap(find.text('聚焦角色'));
        await tester.pump(const Duration(milliseconds: 220));
        expect(game.camera.viewfinder.zoom, 2);
        await capture('09-agent-card.png');
        // ensureVisible would also scroll the ancestor horizontal TabBarView
        // toward the right-hand inspector. The button is already in view.
        await waitFor(
          () => find.text('Codex 本地诊断').hitTestable().evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Codex 本地诊断').hitTestable());
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('尚未选择 codex.exe'), findsOneWidget);
        await capture('10-codex-diagnostic.png');
        await tester.tap(find.text('关闭'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byType(GameWidget<OfficeGame>).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('回到全景'));
        await tester.pump(const Duration(milliseconds: 220));
        expect(game.camera.viewfinder.zoom, 1);
        final overviewActorCanvas = game.camera.localToGlobal(
          Vector2(nova.x, nova.y - 22),
        );
        expect(
          game.actorAt(Offset(overviewActorCanvas.x, overviewActorCanvas.y)),
          'nova',
        );
        await tester.tapAt(worldPoint(nova.x, nova.y - 22));
        await waitFor(
          () => find.text('Nova').hitTestable().evaluate().isNotEmpty,
        );
        checks['actorContextMenu'] = 'actual long press and focus action';
        final liveBinding = tester.binding as LiveTestWidgetsFlutterBinding;
        final previousPolicy = liveBinding.framePolicy;
        game.resetPerformanceSamples();
        frameTimings.clear();
        liveBinding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
        final measurement = Stopwatch()..start();
        try {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 6)),
          );
        } finally {
          liveBinding.framePolicy = previousPolicy;
        }
        final benchmark = {
          ...game.performanceSnapshot,
          'wallSeconds': measurement.elapsedMilliseconds / 1000,
          'rssBytes': ProcessInfo.currentRss,
          'scope': 'six-second foreground Windows debug fixture, fullyLive frames; not a Release or 30-minute benchmark',
        };
        final benchmarkTimings = List<ui.FrameTiming>.of(frameTimings);
        await tester.tap(find.text('安排任务').first);
        await tester.pump(const Duration(milliseconds: 200));
        final query = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '知识库搜索词',
        );
        await capture('11-task-composer.png');
        await tester.enterText(query, '本地笔记检索');
        await tester.tap(find.text('加入任务队列'));
        await tester.pump(const Duration(milliseconds: 200));
        String? taskId;
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          await Future<void>.delayed(const Duration(milliseconds: 40));
          final tasks = await container
              .read(recordStoreProvider)
              .list('studio_task');
          if (tasks.isNotEmpty) {
            taskId = tasks.first.id;
            if (taskState(tasks.first) == TaskState.waitingApproval) break;
          }
        }
        expect(taskId, isNotNull);
        final repository = container.read(studioRepositoryProvider);
        expect(
          taskState(await repository.requireTask(taskId!)),
          TaskState.waitingApproval,
        );
        expect(
          (await repository.requireTask(taskId)).text('assignedAgentId'),
          'nova',
        );
        expect(
          (await repository.artifacts(taskId)).single.body,
          contains('办公室资料'),
        );
        checks['localTask'] = 'actual RecordStore Chinese search';
        await tester.tap(find.text('任务中心').last);
        await waitFor(
          () => find.text('搜索知识库笔记').hitTestable().evaluate().isNotEmpty,
        );
        await tester.tap(find.text('搜索知识库笔记').first);
        await tester.pump(const Duration(milliseconds: 250));
        await capture('03-task-review.png');
        await tester.tap(find.text('审核通过'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('存入 Memory'));
        await tester.pump(const Duration(milliseconds: 250));
        final savedTask = await repository.requireTask(taskId);
        expect(savedTask.text('memoryNoteId'), isNotEmpty);
        expect(taskState(savedTask), TaskState.completed);
        checks['approvedMemoryNote'] = savedTask.text('memoryNoteId');
        checks['eventCount'] = (await repository.events(taskId)).length;
        await tester.tap(find.text('关闭'));
        await tester.pump();
        final boardSwitch = find.widgetWithText(FilterChip, '看板');
        await waitFor(() => boardSwitch.hitTestable().evaluate().isNotEmpty);
        ScaffoldMessenger.of(tester.element(boardSwitch)).hideCurrentSnackBar();
        await tester.tap(boardSwitch);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('已完成 · 1'), findsOneWidget);
        await capture('08-task-board.png');
        await tester.tap(boardSwitch);
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.widget<FilterChip>(boardSwitch).selected, isFalse);
        container.read(routerProvider).go('/modules/studio');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await capture('04-tasks-mobile-layout.png');
        await tester.tap(find.text('办公室'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(tester.takeException(), isNull);
        await capture('05-office-mobile-layout.png');
        checks['scenePerformance'] = benchmark;
        final spans =
            benchmarkTimings
                .map((t) => t.totalSpan.inMicroseconds / 1000)
                .toList()
              ..sort();
        checks['engineFrameTimings'] = {
          'samples': spans.length,
          if (spans.isNotEmpty) 'p50TotalMs': spans[spans.length ~/ 2],
          if (spans.isNotEmpty)
            'p95TotalMs':
                spans[(spans.length * .95).floor().clamp(0, spans.length - 1)],
          'scope': 'same six-second foreground debug fixture; no interaction during sampling',
        };
        checks['mobileLayout'] =
            'Windows engine 390x844; not device acceptance';
        container.read(routerProvider).go('/');
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await container.read(agentRuntimeProvider).dispose();
        container.dispose();
        await db.close();
        db = AppDatabase.file(file);
        await db.initialize();
        final recheck = ProviderContainer(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              SettingsRepository(db),
            ),
          ],
        );
        expect(
          OfficePresentation.decode(
            await recheck
                .read(recordStoreProvider)
                .setting('studio.presentation'),
          ).environment,
          OfficeEnvironment.night,
        );
        expect(
          taskState((await recheck.read(recordStoreProvider).get(taskId))!),
          TaskState.completed,
        );
        expect(
          (await recheck.read(studioRepositoryProvider).layout())
              .furniture
              .length,
          12,
        );
        expect(
          await recheck
              .read(recordStoreProvider)
              .setting('studio.links.position'),
          jsonEncode(const Cell(10, 9).toJson()),
        );
        expect(
          (await recheck.read(studioRepositoryProvider).artifacts(taskId))
              .single
              .body,
          contains('办公室资料'),
        );
        checks['reopen'] =
            'completed task, output, layout and player position persisted';
        recheck.dispose();
        await File(p.join(output.path, 'native-acceptance.json'))
            .writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
      } finally {
        tester.binding.removeTimingsCallback(timings);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        // dispose is idempotent; explicit await keeps database connections ordered.
        try {
          await container.read(agentRuntimeProvider).dispose();
          container.dispose();
        } catch (_) {}
        await db.close();
        await temp.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
