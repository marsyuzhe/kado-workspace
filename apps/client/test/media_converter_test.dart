import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/utilities/media_converter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final runtimePath = Platform.environment['LINKS_FFMPEG_BIN'];
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late MediaRuntimeService runtime;
  late MediaConverterService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-media-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    runtime = MediaRuntimeService(store);
    service = MediaConverterService(
      store,
      UtilityFileService(store, () async => OwnedFileStore(temp)),
      runtime,
      () async => temp,
    );
    jobs = UtilityJobEngine(JobQueueRepository(store));
    if (runtimePath != null) {
      await runtime.trust(await runtime.inspect(runtimePath), confirmed: true);
    }
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<void> fixture(String path, {bool video = false}) =>
      boundedProcess(p.join(runtimePath!, 'ffmpeg.exe'), [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        video
            ? 'testsrc2=size=320x240:rate=10'
            : 'sine=frequency=440:sample_rate=44100',
        '-t',
        '1',
        if (video) ...[
          '-c:v',
          'libopenh264',
          '-pix_fmt',
          'yuv420p',
        ] else ...[
          '-c:a',
          'pcm_s16le',
        ],
        path,
      ]).then((_) {});
  Future<ToolRecord> run(String path, String name, MediaOptions options) async {
    final row = await jobs.submit(
      'converter',
      'media',
      '真实媒体转换',
      {},
      confirmed: true,
      run: (job, _) async =>
          (await service.convert(path, temp.path, name, options, job)).id,
    );
    await jobs.waitIdle();
    return jobs.repository.require(row.id);
  }

  test(
    'media settings reject unsupported codecs/options without launching executors',
    () async {
      expect(
        () => const MediaOptions(format: 'exe').validate(),
        throwsA(isA<ToolFailure>()),
      );
      expect(
        () => const MediaOptions(width: 1, height: 10).validate(),
        throwsA(isA<ToolFailure>()),
      );
      final source = File('${temp.path}/source.wav');
      await source.writeAsBytes([1]);
      await expectLater(
        service.probe(source.path),
        throwsA(isA<ToolFailure>()),
      );
    },
    skip: runtimePath != null
        ? 'Missing-runtime branch runs separately without LINKS_FFMPEG_BIN'
        : false,
  );
  test(
    'real WAV converts to MP3 FLAC M4A AAC WAV and probes readable output',
    () async {
      final source = '${temp.path}/source.wav';
      await fixture(source);
      for (final format in ['mp3', 'flac', 'm4a', 'aac', 'wav']) {
        final result = await run(
          source,
          'out.$format',
          MediaOptions(format: format, channels: 1, sampleRate: 16000),
        );
        expect(
          utilityJobStatus(result),
          UtilityJobStatus.succeeded,
          reason: result.text('errorMessage'),
        );
        final output = await store.get(result.text('resultReference'));
        expect(output!.number('size'), greaterThan(0));
        expect((await service.probe(output.text('outputPath'))).hasAudio, true);
        expect(output.text('checksum').length, 64);
      }
      expect((await service.probe(source)).seconds, closeTo(1, .05));
    },
    skip: runtimePath == null
        ? 'Set LINKS_FFMPEG_BIN to verified optional runtime'
        : false,
  );
  test(
    'real MP4 remuxes MKV and reencodes MOV at adjusted size',
    () async {
      final source = '${temp.path}/source.mp4';
      await fixture(source, video: true);
      final mkv = await run(
        source,
        'out.mkv',
        const MediaOptions(format: 'mkv', remux: true),
      );
      expect(
        utilityJobStatus(mkv),
        UtilityJobStatus.succeeded,
        reason: mkv.text('errorMessage'),
      );
      final mov = await run(
        '${temp.path}/out.mkv',
        'out.mov',
        const MediaOptions(format: 'mov', width: 160, height: 120),
      );
      expect(
        utilityJobStatus(mov),
        UtilityJobStatus.succeeded,
        reason: mov.text('errorMessage'),
      );
      final video = (await service.probe('${temp.path}/out.mov')).streams
          .firstWhere((s) => s['codec_type'] == 'video');
      expect(video['width'], 160);
      expect(video['height'], 120);
    },
    skip: runtimePath == null
        ? 'Set LINKS_FFMPEG_BIN to verified optional runtime'
        : false,
  );
  test(
    'empty corrupt conflicts missing encoders and cancellation cannot create false success',
    () async {
      final source = '${temp.path}/source.wav';
      await fixture(source);
      await File('${temp.path}/empty.mp3').create();
      await expectLater(
        service.probe('${temp.path}/empty.mp3'),
        throwsA(isA<ToolFailure>()),
      );
      await File('${temp.path}/bad.mp3').writeAsString('invalid binary');
      await expectLater(
        service.probe('${temp.path}/bad.mp3'),
        throwsA(isA<ToolFailure>()),
      );
      await File('${temp.path}/conflict.mp3').writeAsString('original');
      final conflict = await run(source, 'conflict.mp3', const MediaOptions());
      expect(utilityJobStatus(conflict), UtilityJobStatus.failed);
      expect(
        await File('${temp.path}/conflict.mp3').readAsString(),
        'original',
      );
      final engine = await runtime.verified();
      expect(
        () => service.conversionArgs(
          awaitInfo(),
          const MediaOptions(),
          engine.copyWith(data: {...engine.data, 'encoders': ''}),
        ),
        throwsA(isA<ToolFailure>()),
      );
      final row = await jobs.submit(
        'converter',
        'media',
        '取消',
        {},
        confirmed: true,
        run: (job, _) async => (await service.convert(
          source,
          temp.path,
          'cancelled.mp3',
          const MediaOptions(),
          job,
        )).id,
      );
      await jobs.cancel(row.id);
      await jobs.waitIdle();
      expect(
        utilityJobStatus(await jobs.repository.require(row.id)),
        UtilityJobStatus.cancelled,
      );
      expect(await File('${temp.path}/cancelled.mp3').exists(), false);
    },
    skip: runtimePath == null
        ? 'Set LINKS_FFMPEG_BIN to verified optional runtime'
        : false,
  );
}

MediaInfo awaitInfo() => MediaInfo({
  'format': {'duration': '1'},
  'streams': [
    {'codec_type': 'audio', 'codec_name': 'pcm_s16le'},
  ],
});
