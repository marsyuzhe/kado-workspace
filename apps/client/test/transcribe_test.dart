import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/utilities/media_converter.dart';
import 'package:links_toolbox/features/utilities/transcribe_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ff = Platform.environment['LINKS_FFMPEG_BIN'],
      whisper = Platform.environment['LINKS_WHISPER_BIN'],
      modelPath = Platform.environment['LINKS_WHISPER_MODEL'],
      sample = Platform.environment['LINKS_SPEECH_SAMPLE'];
  final real =
      ff != null && whisper != null && modelPath != null && sample != null;
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late MediaRuntimeService mediaRuntime;
  late WhisperRuntimeService runtime;
  late SpeechModelManager models;
  late TranscribeService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-asr-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    final files = UtilityFileService(store, () async => OwnedFileStore(temp));
    mediaRuntime = MediaRuntimeService(store);
    runtime = WhisperRuntimeService(store, mediaRuntime);
    models = SpeechModelManager(store, files, () async => temp);
    service = TranscribeService(
      store,
      MediaConverterService(store, files, mediaRuntime, () async => temp),
      runtime,
      models,
      () async => temp,
    );
    jobs = UtilityJobEngine(JobQueueRepository(store));
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> importRealModel() async {
    await mediaRuntime.trust(await mediaRuntime.inspect(ff!), confirmed: true);
    await runtime.trust(await runtime.inspect(whisper!), confirmed: true);
    final job = await jobs.submit(
      'transcribe',
      'import_model',
      '真实模型导入',
      {},
      confirmed: true,
      run: (ctx, _) async =>
          (await models.importModel(modelPath!, speechModels.first, ctx)).id,
    );
    await jobs.waitIdle();
    final done = await jobs.repository.require(job.id);
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  Future<ToolRecord> recognize(
    String path,
    ToolRecord model, {
    String language = 'en',
  }) async {
    final job = await jobs.submit(
      'transcribe',
      'transcribe',
      '真实识别',
      {'modelId': model.id},
      confirmed: true,
      run: (ctx, _) async =>
          (await service.transcribe(path, model, language, ctx)).id,
    );
    await jobs.waitIdle();
    final done = await jobs.repository.require(job.id);
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  test('subtitle formats preserve timestamps and edits persist with revision history', () async {
    final row = await store.create(
      'transcript',
      '录音',
      body: '第一句\nSecond line',
      data: {
        'status': 'complete',
        'language': 'zh',
        'modelName': 'tiny',
        'segments': [
          const TranscriptSegment(0, 1250, '第一句').toJson(),
          const TranscriptSegment(1500, 3100, 'Second line').toJson(),
        ],
      },
    );
    final srt = TranscriptRepository.export(row, 'srt'),
        vtt = TranscriptRepository.export(row, 'vtt');
    expect(srt, contains('00:00:00,000 --> 00:00:01,250'));
    expect(vtt, startsWith('WEBVTT\n\n1\n00:00:00.000'));
    expect(
      (jsonDecode(TranscriptRepository.export(row, 'json')) as Map)['language'],
      'zh',
    );
    final edited = await TranscriptRepository(store).revise(row, [
      const TranscriptSegment(0, 1000, '更正文字'),
      const TranscriptSegment(1000, 3100, '合并后续字幕'),
    ]);
    expect(edited.number('editCount'), 1);
    expect(
      (await store.list('transcript_revision')).single.body,
      '第一句\nSecond line',
    );
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await store.get(row.id))!.body, '更正文字\n合并后续字幕');
    expect(
      () => TranscriptRepository.validate([
        const TranscriptSegment(100, 100, 'bad'),
      ]),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => TranscriptRepository.validate([
        const TranscriptSegment(0, 200, 'one'),
        const TranscriptSegment(100, 300, 'overlap'),
      ]),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      TranscriptRepository(store).revise(
        edited.copyWith(data: {...edited.data, 'status': 'processing'}),
        [],
      ),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('missing runtime and incomplete model are actionable failures with no false transcript', () async {
    await expectLater(runtime.verified(), throwsA(isA<ToolFailure>()));
    final bad = File('${temp.path}/for-tests-tiny.bin');
    await bad.writeAsBytes([1, 2, 3]);
    final job = await jobs.submit(
      'transcribe',
      'import_model',
      '空权重拒绝',
      {},
      confirmed: true,
      run: (ctx, _) async =>
          (await models.importModel(bad.path, speechModels.first, ctx)).id,
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(job.id)),
      UtilityJobStatus.failed,
    );
    expect(await store.list('speech_model'), isEmpty);
    expect(await store.list('transcript'), isEmpty);
  });
  test(
    'real multilingual model transcribes English WAV MP3 and AMR, exports all four formats and reopens',
    () async {
      final model = await importRealModel();
      final inputs = [sample!];
      for (final ext in ['mp3', 'amr']) {
        final path = '${temp.path}/jfk.$ext';
        await boundedProcess(p.join(ff!, 'ffmpeg.exe'), [
          '-v',
          'error',
          '-i',
          sample,
          '-ar',
          ext == 'amr' ? '8000' : '44100',
          '-ac',
          '1',
          '-c:a',
          ext == 'amr' ? 'libopencore_amrnb' : 'libmp3lame',
          if (ext == 'amr') ...['-b:a', '12.2k'],
          path,
        ]);
        inputs.add(path);
      }
      for (final path in inputs) {
        final result = await recognize(path, model);
        expect(result.body.toLowerCase(), contains('country'));
        expect(transcriptSegments(result), isNotEmpty);
        final artifacts = Platform.environment['LINKS_UTILITIES_ARTIFACT_ROOT'];
        for (final format in ['txt', 'srt', 'vtt', 'json']) {
          final text = TranscriptRepository.export(result, format);
          expect(text.trim(), isNotEmpty);
          if (artifacts != null) {
            final dir = await Directory(p.join(artifacts, 'asr-service'))
                .create(recursive: true);
            await File(
              p.join(dir.path, '${p.extension(path).substring(1)}.$format'),
            ).writeAsString(text);
          }
        }
      }
      await db.close();
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      store = RecordStore(db);
      expect((await store.list('transcript')).length, 3);
      expect(
        (await store.list('transcript'))
            .every((r) => r.text('status') == 'complete'),
        true,
      );
    },
    skip: !real
        ? 'Set verified FFmpeg/Whisper/model/sample environment variables'
        : false,
  );
  test(
    'model deletion is guarded and restore metadata can reimport the optional model',
    () async {
      final model = await importRealModel();
      final queued = await jobs.repository.create(
        'transcribe',
        'transcribe',
        '引用模型',
        {'modelId': model.id},
        submissionId: 'hold-model',
      );
      await expectLater(
        models.remove(model, confirmed: true),
        throwsA(isA<ToolFailure>()),
      );
      await jobs.repository.requestCancel(queued.id, active: false);
      final copy = await models.verify(model);
      await copy.delete();
      final again = await importRealModel();
      expect(again.id, model.id);
      expect(await (await models.verify(again)).exists(), true);
      await models.remove(again, confirmed: true);
      expect(await store.list('speech_model'), isEmpty);
      expect(await File(modelPath!).exists(), true);
    },
    skip: !real
        ? 'Set verified FFmpeg/Whisper/model/sample environment variables'
        : false,
  );
  test(
    'long audio is split into bounded chunks and cancellation leaves no successful result',
    () async {
      final model = await importRealModel(), path = '${temp.path}/long.wav';
      await boundedProcess(p.join(ff!, 'ffmpeg.exe'), [
        '-v',
        'error',
        '-stream_loop',
        '-1',
        '-i',
        sample!,
        '-t',
        '610',
        '-ar',
        '16000',
        '-ac',
        '1',
        path,
      ]);
      final row = await recognize(path, model);
      expect(row.number('completedChunks'), 2);
      expect(row.number('totalChunks'), 2);
      expect(transcriptSegments(row).last.endMs, greaterThan(600000));
      final job = await jobs.submit(
        'transcribe',
        'transcribe',
        '活动识别取消',
        {'modelId': model.id},
        confirmed: true,
        run: (ctx, _) async =>
            (await service.transcribe(path, model, 'en', ctx)).id,
      );
      for (var i = 0; i < 150; i++) {
        final current = await jobs.repository.require(job.id);
        if (current.text('currentFile').contains('本地识别')) break;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await jobs.cancel(job.id);
      await jobs.waitIdle();
      final cancelled = await jobs.repository.require(job.id);
      expect(utilityJobStatus(cancelled), UtilityJobStatus.cancelled);
      for (final id in cancelled.strings('outputReferences')) {
        expect((await store.get(id))!.text('status'), 'cancelled');
      }
      expect(
        await Directory('${temp.path}/utility-work/${job.id}').exists(),
        false,
      );
    },
    skip: !real
        ? 'Set verified FFmpeg/Whisper/model/sample environment variables'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'Chinese synthetic speech and reduced-volume speech use actual inference',
    () async {
      final path = Platform.environment['LINKS_CHINESE_SAMPLE']!;
      final model = await importRealModel();
      final quiet = '${temp.path}/zh-quiet.wav';
      await boundedProcess(p.join(ff!, 'ffmpeg.exe'), [
        '-v',
        'error',
        '-i',
        path,
        '-af',
        'volume=0.12',
        '-ar',
        '16000',
        '-ac',
        '1',
        quiet,
      ]);
      for (final source in [path, quiet]) {
        final row = await recognize(source, model, language: 'zh');
        expect(RegExp(r'[\u3400-\u9fff]').hasMatch(row.body), true);
        expect(row.text('language'), 'zh');
        final artifacts = Platform.environment['LINKS_UTILITIES_ARTIFACT_ROOT'];
        if (artifacts != null) {
          final dir = await Directory(p.join(artifacts, 'asr-service'))
              .create(recursive: true);
          await File(
            p.join(
              dir.path,
              source == path ? 'zh-synthetic.json' : 'zh-quiet-synthetic.json',
            ),
          ).writeAsString(TranscriptRepository.export(row, 'json'));
        }
      }
    },
    skip: !real || Platform.environment['LINKS_CHINESE_SAMPLE'] == null
        ? 'Requires owned Chinese synthetic speech fixture'
        : false,
  );
}
