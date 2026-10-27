import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/version.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/utilities/media_converter.dart';
import 'package:links_toolbox/features/utilities/transcribe_service.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Batch B verifies package properties, real environment export and optional ASR/media workflows',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('lt-v22b-native-');
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
          'batch-b',
        ),
      );
      await artifact.create(recursive: true);
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(p.join(artifact.path, name))
            .writeAsBytes(png!.buffer.asUint8List());
      }

      try {
        final native = container.read(nativePlatformProvider),
            hardware = await container
                .read(nativePlatformProvider)
                .systemEnvironmentSummary();
        expect(hardware['processorCount'], greaterThan(0));
        expect(hardware['totalMemoryBytes'], greaterThan(0));
        expect(hardware['disks'] as List, isNotEmpty);
        final metadata = await native.installerMetadata(
          Platform.resolvedExecutable,
        );
        expect(metadata['version'].toString(), contains(appVersion));
        expect(metadata['signatureStatus'], isIn(['unsigned', 'unverified']));
        final jobs = container.read(utilityJobsProvider),
            software = container.read(softwareLibraryProvider);
        final zip = File(p.join(temp.path, 'safe-native-package.zip'));
        await zip.writeAsString(
          'Safe owned metadata fixture; never an executable.',
        );
        final packages = await jobs.submit(
          'software_library',
          'import',
          '原生安装包登记',
          {},
          confirmed: true,
          run: (ctx, _) async {
            await software.importPaths([
              Platform.resolvedExecutable,
              zip.path,
            ], ctx);
            return null;
          },
        );
        await jobs.waitIdle();
        expect(
          utilityJobStatus(await jobs.repository.require(packages.id)),
          UtilityJobStatus.succeeded,
        );
        final stored = await container
            .read(recordStoreProvider)
            .list('software_package');
        expect(stored.length, 2);
        expect(
          stored
              .firstWhere((r) => r.text('installerType') == 'exe')
              .text('version'),
          contains(appVersion),
        );
        expect(
          stored
              .firstWhere((r) => r.text('installerType') == 'zip')
              .text('signatureStatus'),
          'not_supported',
        );
        final config = File(p.join(temp.path, 'settings.json'));
        const privateFixture = 'fixture-secret-must-never-enter-snapshot';
        await config.writeAsString(
          jsonEncode({'apiKey': privateFixture, 'theme': 'dark'}),
        );
        final snapshot = container.read(environmentSnapshotProvider),
            plan = await container.read(environmentSnapshotProvider).plan([
              config.path,
            ]);
        expect(
          utf8.decode(plan.configs.single.content),
          isNot(contains(privateFixture)),
        );
        final output = await Directory(p.join(temp.path, 'snapshot-output'))
            .create();
        final collected = await jobs.submit(
          'environment_snapshot',
          'collect',
          '原生环境快照',
          {},
          confirmed: true,
          run: (ctx, _) async =>
              (await snapshot.collect(plan, output.path, ctx)).id,
        );
        await jobs.waitIdle();
        final done = await jobs.repository.require(collected.id);
        expect(
          utilityJobStatus(done),
          UtilityJobStatus.succeeded,
          reason: done.text('errorMessage'),
        );
        final record = (await container
            .read(recordStoreProvider)
            .get(done.text('resultReference')))!;
        final reportDir = Directory(record.text('outputDirectory'));
        for (final name in [
          'environment.json',
          'software-list.csv',
          'README.md',
          'restore-guide.md',
        ]) {
          final file = File(p.join(reportDir.path, name));
          expect(await file.exists(), true);
          final text = await file.readAsString();
          expect(text, isNot(contains(privateFixture)));
          final secret = Platform.environment['LINKS_QA_SECRET'];
          if (secret != null) expect(text, isNot(contains(secret)));
          await file.copy(p.join(artifact.path, name));
        }
        for (final manifest in record.data['manifest'] as List) {
          final entry = manifest as Map;
          expect(
            await archiveHash(
              File(p.join(reportDir.path, entry['name'] as String)),
              TaskCancellation(),
            ),
            entry['sha256'],
          );
        }
        final environment = jsonDecode(
          await File(p.join(reportDir.path, 'environment.json')).readAsString(),
        ) as Map;
        expect(
          (environment['privacy'] as Map)['environmentValuesExported'],
          false,
        );
        expect(environment.containsKey('environmentVariableValues'), false);
        final ff = Platform.environment['LINKS_FFMPEG_BIN'],
            whisper = Platform.environment['LINKS_WHISPER_BIN'],
            model = Platform.environment['LINKS_WHISPER_MODEL'],
            sample = Platform.environment['LINKS_SPEECH_SAMPLE'];
        if (ff != null && whisper != null && model != null && sample != null) {
          await container
              .read(mediaRuntimeProvider)
              .trust(
                await container.read(mediaRuntimeProvider).inspect(ff),
                confirmed: true,
              );
          await container
              .read(whisperRuntimeProvider)
              .trust(
                await container.read(whisperRuntimeProvider).inspect(whisper),
                confirmed: true,
              );
          final modelJob = await jobs.submit(
            'transcribe',
            'import_model',
            '原生导入tiny',
            {},
            confirmed: true,
            run: (ctx, _) async =>
                (await container
                        .read(speechModelsProvider)
                        .importModel(model, speechModels.first, ctx))
                    .id,
          );
          await jobs.waitIdle();
          final imported = await jobs.repository.require(modelJob.id);
          expect(utilityJobStatus(imported), UtilityJobStatus.succeeded);
          final storedModel = (await container
              .read(recordStoreProvider)
              .get(imported.text('resultReference')))!;
          final asr = await jobs.submit(
            'transcribe',
            'transcribe',
            '原生公开英文录音识别',
            {'modelId': storedModel.id},
            confirmed: true,
            run: (ctx, _) async =>
                (await container
                        .read(transcribeServiceProvider)
                        .transcribe(sample, storedModel, 'en', ctx))
                    .id,
          );
          await jobs.waitIdle();
          final recognized = await jobs.repository.require(asr.id);
          expect(
            utilityJobStatus(recognized),
            UtilityJobStatus.succeeded,
            reason: recognized.text('errorMessage'),
          );
          final transcript = (await container
              .read(recordStoreProvider)
              .get(recognized.text('resultReference')))!;
          expect(transcript.body.toLowerCase(), contains('country'));
          await File(p.join(artifact.path, 'native-transcript.json'))
              .writeAsString(TranscriptRepository.export(transcript, 'json'));
          final video = p.join(temp.path, 'real-video.mp4');
          await boundedProcess(p.join(ff, 'ffmpeg.exe'), [
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'color=c=purple:size=240x160:rate=5',
            '-t',
            '1',
            '-c:v',
            'libopenh264',
            '-pix_fmt',
            'yuv420p',
            video,
          ]);
          final library = await jobs.submit(
            'media_library',
            'index',
            '原生视频素材',
            {},
            confirmed: true,
            run: (ctx, _) async {
              await container.read(mediaLibraryProvider).importPaths([
                video,
              ], ctx);
              return null;
            },
          );
          await jobs.waitIdle();
          expect(
            utilityJobStatus(await jobs.repository.require(library.id)),
            UtilityJobStatus.succeeded,
          );
        }
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
        for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
          await tester.binding.setSurfaceSize(size);
          for (final id in [
            'transcribe',
            'media_library',
            'software_library',
            'environment_snapshot',
            'utility_jobs',
          ]) {
            container.read(routerProvider).go('/modules/$id');
            await capture('$id-${size.width.toInt()}.png');
          }
          container.read(routerProvider).go('/modules/transcribe');
          await tester.pumpAndSettle();
          for (final tab in ['模型与执行器', '结果与字幕编辑']) {
            await tester.tap(find.text(tab));
            await capture(
              'transcribe-${tab == '模型与执行器' ? 'models' : 'results'}-${size.width.toInt()}.png',
            );
          }
        }
        expect(await db.verifyIntegrity(), true);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await container.read(utilityJobsProvider).dispose();
        container.dispose();
        await db.close();
        await temp.delete(recursive: true);
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
