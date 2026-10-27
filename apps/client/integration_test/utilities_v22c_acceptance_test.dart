import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/utilities/home_dashboard.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Batch C verifies real game ZIP moves, loopback device changes, receiver hashes and external metadata without launching LocalSend',
    (tester) async {
      HttpOverrides.global = null;
      final temp = await Directory.systemTemp.createTemp('lt-v22c-native-');
      final db = AppDatabase.file(
        File(p.join(temp.path, 'links_toolbox.sqlite')),
      );
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      final artifact = Directory(
        p.join(
          Platform.environment['LINKS_ARTIFACT_ROOT'] ??
              '${Directory.current.path}/../../artifacts/v22-regression',
          'batch-c',
        ),
      );
      await artifact.create(recursive: true);
      final boundary = GlobalKey();
      HttpServer? server;
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
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(p.join(artifact.path, name))
            .writeAsBytes(bytes!.buffer.asUint8List());
      }

      try {
        final jobs = container.read(utilityJobsProvider),
            store = container.read(recordStoreProvider),
            games = container.read(gameSavesProvider),
            transfer = container.read(lanTransferProvider),
            home = container.read(homeDashboardProvider);
        Future<ToolRecord> execute(
          String module,
          String op,
          Future<String?> Function(UtilityJobContext, Map<String, dynamic>) run,
        ) async {
          final submitted = await jobs.submit(
                module,
                op,
                op,
                {},
                confirmed: true,
                run: run,
              ),
              done = await jobs.waitFor(submitted.id);
          expect(
            utilityJobStatus(done),
            UtilityJobStatus.succeeded,
            reason: done.text('errorMessage'),
          );
          return (await store.get(done.text('resultReference')))!;
        }

        final source = await Directory(p.join(temp.path, '游戏世界')).create(),
            backupRoot = await Directory(p.join(temp.path, '备份')).create(),
            restored = await Directory(p.join(temp.path, '恢复')).create();
        await Directory(p.join(source.path, 'region', '空目录'))
            .create(recursive: true);
        final level = await File(p.join(source.path, 'level.dat'))
            .writeAsString('本应用自有测试世界，绝不读取用户真实存档');
        final profile = await games.save(
          'Minecraft Java测试实例',
          'Windows Java',
          source.path,
          backupRoot.path,
        );
        final plan = await games.plan(profile, TaskCancellation());
        final backup = await execute(
          'game_saves',
          'backup',
          (ctx, _) async => (await games.backup(plan, '版本升级前', ctx)).id,
        );
        expect(
          await games.requireBackup(backup, TaskCancellation()),
          isA<File>(),
        );
        final restoredRecord = await execute(
          'game_saves',
          'restore',
          (ctx, _) async => (await games.restore(
            backup,
            restored.path,
            'Links-restored-native',
            ctx,
          )).id,
        );
        expect(
          await File(
            p.join(restoredRecord.text('outputDirectory'), 'level.dat'),
          ).readAsString(),
          await level.readAsString(),
        );
        expect(
          await Directory(
            p.join(restoredRecord.text('outputDirectory'), 'region', '空目录'),
          ).exists(),
          true,
        );
        var httpStatus = 200;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          request.response.statusCode = httpStatus;
          request.response.close();
        });
        final device = await home.save(
          HomeDeviceInput(
            '可控制HTTP测试设备',
            'NAS',
            '127.0.0.1',
            server.port,
            'http',
            tags: ['自有测试'],
          ),
        );
        final first = await execute(
          'home_dashboard',
          'check',
          (ctx, _) async => (await home.check(device, 'http', ctx)).id,
        );
        expect(first.number('httpStatus'), 200);
        httpStatus = 503;
        final changed = await execute(
          'home_dashboard',
          'check',
          (ctx, _) async =>
              (await home.check((await store.get(device.id))!, 'http', ctx)).id,
        );
        expect(changed.number('httpStatus'), 503);
        expect(changed.flag('reachable'), true);
        final prepared = await execute(
          'lan_transfer',
          'prepare',
          (ctx, _) async => (await transfer.prepare([level.path], ctx)).id,
        );
        final exported = await execute(
          'lan_transfer',
          'export',
          (ctx, _) async =>
              (await transfer.export(prepared, backupRoot.path, ctx)).id,
        );
        final verify = await execute(
          'lan_transfer',
          'verify',
          (ctx, _) async => (await transfer.verifyReceived(
            exported.text('outputPath'),
            restoredRecord.text('outputDirectory'),
            ctx,
          )).id,
        );
        expect(verify.text('status'), 'verified');
        final localSend = Platform.environment['LINKS_LOCALSEND_BIN'] ?? '';
        ToolRecord? runtime;
        if (await File(localSend).exists()) {
          runtime = await execute(
            'lan_transfer',
            'configure',
            (ctx, _) async => (await transfer.configure(localSend, ctx)).id,
          );
          expect(runtime.text('version'), contains('1.18.2'));
          expect(
            runtime.text('signatureStatus'),
            isIn(['valid_offline', 'unverified']),
          );
          await execute('lan_transfer', 'preflight', (ctx, _) async {
            final action = await transfer.handoff(runtime!, prepared, ctx);
            expect(action.arguments, [level.path]);
            return prepared.id;
          });
        }
        await File(p.join(artifact.path, 'native-evidence.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'game': backup.data,
            'restored': restoredRecord.data,
            'httpStatuses': [
              first.number('httpStatus'),
              changed.number('httpStatus'),
            ],
            'receiverVerification': verify.data,
            'localSend': runtime?.data,
            'localSendExecuted': false,
            'twoPhysicalDevicesVerified': false,
          }),
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
        for (final size in [
          const Size(1440, 1000),
          const Size(390, 844),
          const Size(320, 640),
        ]) {
          await tester.binding.setSurfaceSize(size);
          for (final id in ['home_dashboard', 'game_saves', 'lan_transfer']) {
            container.read(routerProvider).go('/modules/$id');
            await capture('$id-${size.width.toInt()}.png');
            if (id == 'game_saves') {
              await tester.tap(find.text('版本与恢复'));
              await capture('game-versions-${size.width.toInt()}.png');
            }
          }
        }
        expect(await db.verifyIntegrity(), true);
      } finally {
        await server?.close(force: true);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await container.read(utilityJobsProvider).dispose();
        container.dispose();
        await db.close();
        await temp.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
