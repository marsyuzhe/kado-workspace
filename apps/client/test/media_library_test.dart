import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/utilities/media_converter.dart';
import 'package:links_toolbox/features/utilities/media_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ff = Platform.environment['LINKS_FFMPEG_BIN'];
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late MediaRuntimeService runtime;
  late MediaLibraryService library;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-media-library-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    final files = UtilityFileService(store, () async => OwnedFileStore(temp));
    runtime = MediaRuntimeService(store);
    library = MediaLibraryService(
      store,
      MediaConverterService(store, files, runtime, () async => temp),
      files,
      () async => temp,
    );
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  test('media annotations validate links, source missing state and cache deletion needs confirmation', () async {
    final row = await store.create(
      'media_asset',
      '自有元数据',
      data: {'path': '${temp.path}/missing.mp4'},
    );
    await expectLater(
      library.edit(
        row,
        title: 'x',
        tags: [],
        notes: '',
        favorite: false,
        projectId: 'missing',
      ),
      throwsA(isA<ToolFailure>()),
    );
    final updated = await library.check(row);
    expect(updated.flag('lastExists'), false);
    await expectLater(
      library.clearCache(confirmed: false),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(library.setCacheLimit(1), throwsA(isA<ToolFailure>()));
    final job = await jobs.submit(
      'media_library',
      'index',
      '缺少执行器',
      {},
      confirmed: true,
      run: (ctx, _) async {
        await library.importPaths(['${temp.path}/missing.mp4'], ctx);
        return null;
      },
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(job.id)),
      UtilityJobStatus.failed,
    );
  });
  test(
    '20 real videos get correct duration/dimensions and reusable thumbnails, annotations persist after restart',
    () async {
      await runtime.trust(await runtime.inspect(ff!), confirmed: true);
      final paths = <String>[];
      for (var i = 0; i < 20; i++) {
        final path = '${temp.path}/素材-$i.mp4';
        await boundedProcess(p.join(ff, 'ffmpeg.exe'), [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:size=${128 + i * 2}x80:rate=5',
          '-t',
          '1',
          '-c:v',
          'libopenh264',
          '-pix_fmt',
          'yuv420p',
          path,
        ]);
        paths.add(path);
      }
      final job = await jobs.submit(
        'media_library',
        'index',
        '20真实视频',
        {},
        confirmed: true,
        run: (ctx, _) async {
          await library.importPaths(paths, ctx);
          return null;
        },
      );
      await jobs.waitIdle();
      final done = await jobs.repository.require(job.id);
      expect(
        utilityJobStatus(done),
        UtilityJobStatus.succeeded,
        reason: done.text('errorMessage'),
      );
      expect(done.strings('outputReferences').length, 20);
      final rows = await store.list('media_asset');
      expect(rows.length, 20);
      for (final row in rows) {
        expect((row.data['duration'] as num).toDouble(), closeTo(1, .1));
        expect(row.number('height'), 80);
        expect(
          img.decodePng((await library.thumbnail(row))!)!.width,
          lessThanOrEqualTo(320),
        );
        expect(await File(row.text('path')).exists(), true);
      }
      final thumbNames = rows.map((r) => r.text('thumbnail')).toSet();
      final repeat = await jobs.submit(
        'media_library',
        'index',
        '重复索引不重生成',
        {},
        confirmed: true,
        run: (ctx, _) async {
          await library.importPaths(paths, ctx);
          return null;
        },
      );
      await jobs.waitIdle();
      expect(
        utilityJobStatus(await jobs.repository.require(repeat.id)),
        UtilityJobStatus.succeeded,
      );
      expect(
        (await store.list('media_asset'))
            .map((r) => r.text('thumbnail'))
            .toSet(),
        thumbNames,
      );
      final project = await store.create('project', '素材项目');
      final edited = await library.edit(
        rows.first,
        title: '找到我',
        tags: ['旅行'],
        notes: '备注中文',
        favorite: true,
        rating: 4,
        projectId: project.id,
      );
      expect(
        (await library.search('旅行')).single.id,
        edited.id,
      );
      await db.close();
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      store = RecordStore(db);
      expect((await store.get(edited.id))!.text('projectId'), project.id);
      expect((await store.get(edited.id))!.number('rating'), 4);
      await library.clearCache(confirmed: true);
      expect(await library.cacheSize(), 0);
      for (final path in paths) {
        expect(await File(path).exists(), true);
      }
    },
    skip: ff == null
        ? 'Set LINKS_FFMPEG_BIN to run 20 actual video fixtures'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
