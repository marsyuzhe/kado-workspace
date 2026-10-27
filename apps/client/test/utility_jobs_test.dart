import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/utilities/image_service.dart';

class DispatchRaceRepository extends JobQueueRepository {
  DispatchRaceRepository(super.store);
  final dispatchRead = Completer<void>(),
      cancelRead = Completer<void>(),
      releaseDispatch = Completer<void>(),
      releaseCancel = Completer<void>();
  int reads = 0;
  @override
  Future<ToolRecord> require(String id) async {
    final row = await super.require(id);
    final sequence = ++reads;
    if (sequence == 1) {
      dispatchRead.complete();
      await releaseDispatch.future;
    }
    if (sequence == 2) {
      cancelRead.complete();
      await releaseCancel.future;
    }
    return row;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late JobQueueRepository repo;
  late UtilityJobEngine engine;
  late OwnedFileStore owned;
  late UtilityFileService files;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-v22-job-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    repo = JobQueueRepository(store);
    engine = UtilityJobEngine(repo);
    owned = OwnedFileStore(temp);
    files = UtilityFileService(store, () async => owned);
  });
  tearDown(() async {
    await engine.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  test(
    'queue is serial, idempotent and records real output/progress',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final order = <String>[];
      final first = await engine.submit(
        'image_studio',
        'first',
        '第一批',
        {},
        confirmed: true,
        submissionId: 'once',
        run: (ctx, _) async {
          order.add('first');
          entered.complete();
          await release.future;
          final output = await store.create('utility_output', '真实记录');
          await ctx.output(output.id);
          await ctx.progress(1, 1, force: true);
          return output.id;
        },
      );
      await entered.future;
      final duplicate = await engine.submit(
        'image_studio',
        'first',
        '重复',
        {},
        confirmed: true,
        submissionId: 'once',
        run: (_, _) async => throw StateError('duplicate'),
      );
      expect(duplicate.id, first.id);
      final second = await engine.submit(
        'converter',
        'second',
        '第二批',
        {},
        confirmed: true,
        run: (_, _) async {
          order.add('second');
          return null;
        },
      );
      expect(
        utilityJobStatus(await repo.require(second.id)),
        UtilityJobStatus.queued,
      );
      release.complete();
      await engine.waitIdle();
      final done = await repo.require(first.id);
      expect(order, ['first', 'second']);
      expect(utilityJobStatus(done), UtilityJobStatus.succeeded);
      expect(done.strings('outputReferences'), [done.text('resultReference')]);
      expect(done.number('processedItems'), 1);
      await expectLater(
        repo.update(first.id, {'status': 'running'}),
        throwsA(isA<ToolFailure>()),
      );
      await engine.cancel(first.id);
      expect((await repo.require(first.id)).flag('cancelRequested'), false);
    },
  );
  test('cancel while dispatch is awaiting SQLite prevents a new active context and file side effect', () async {
    await engine.dispose();
    final racing = DispatchRaceRepository(store);
    engine = UtilityJobEngine(racing);
    final output = File('${temp.path}/must-not-be-created.txt');
    final row = await engine.submit(
      'converter',
      'race',
      'Dispatch race',
      {},
      confirmed: true,
      run: (ctx, _) async {
        await output.writeAsString('This side effect must never start');
        return null;
      },
    );
    await racing.dispatchRead.future;
    final cancellation = engine.cancel(row.id);
    try {
      await racing.cancelRead.future;
      racing.releaseDispatch.complete();
      await engine.waitIdle().timeout(const Duration(seconds: 5));
      expect(await output.exists(), false);
    } finally {
      if (!racing.releaseDispatch.isCompleted) {
        racing.releaseDispatch.complete();
      }
      if (!racing.releaseCancel.isCompleted) racing.releaseCancel.complete();
      await cancellation;
    }
    expect(
      utilityJobStatus(await repo.require(row.id)),
      UtilityJobStatus.cancelled,
    );
  });
  test('queued cancellation never executes and active cancellation rejects late output', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var cancelledChild = false, ranQueued = false;
    final active = await engine.submit(
      'converter',
      'hold',
      '活动任务',
      {},
      confirmed: true,
      run: (ctx, _) async {
        ctx.onCancel(() async {
          cancelledChild = true;
          release.complete();
        });
        entered.complete();
        await release.future;
        await ctx.output('late');
        return null;
      },
    );
    await entered.future;
    final queued = await engine.submit(
      'converter',
      'next',
      '排队任务',
      {},
      confirmed: true,
      run: (_, _) async {
        ranQueued = true;
        return null;
      },
    );
    await engine.cancel(queued.id);
    await engine.cancel(active.id);
    await engine.waitIdle();
    expect(cancelledChild, true);
    expect(ranQueued, false);
    for (final id in [active.id, queued.id]) {
      final row = await repo.require(id);
      expect(utilityJobStatus(row), UtilityJobStatus.cancelled);
      expect(row.strings('outputReferences'), isEmpty);
    }
  });
  test(
    'processing error persists and queue continues; confirmation is required',
    () async {
      await expectLater(
        engine.submit(
          'converter',
          'bad',
          '未确认',
          {},
          confirmed: false,
          run: (_, _) async => null,
        ),
        throwsA(isA<ToolFailure>()),
      );
      final failed = await engine.submit(
        'converter',
        'bad',
        '坏输入',
        {},
        confirmed: true,
        run: (_, _) async => throw const ToolFailure('图片损坏'),
      );
      final next = await engine.submit(
        'converter',
        'good',
        '好输入',
        {},
        confirmed: true,
        run: (ctx, _) async {
          await ctx.progress(2, 2);
          return null;
        },
      );
      await engine.waitIdle();
      expect((await repo.require(failed.id)).text('errorMessage'), '图片损坏');
      expect(
        utilityJobStatus(await repo.require(next.id)),
        UtilityJobStatus.succeeded,
      );
      expect(engine.lastStorageError, isNull);
    },
  );
  test(
    'reopen marks unfinished jobs interrupted without replaying side effects',
    () async {
      final queued = await repo.create(
        'renamer',
        'rename',
        '上次排队',
        {},
        submissionId: 'q',
      );
      final running = await repo.create(
        'renamer',
        'rename',
        '上次处理中',
        {},
        submissionId: 'r',
      );
      await repo.start(running.id);
      await engine.dispose();
      await db.close();
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      store = RecordStore(db);
      repo = JobQueueRepository(store);
      engine = UtilityJobEngine(repo);
      var replayed = false;
      engine.register(
        UtilityJobDefinition('renamer', 'rename', (_, _) async {
          replayed = true;
          return null;
        }),
      );
      await engine.initialize();
      await engine.waitIdle();
      for (final id in [queued.id, running.id]) {
        expect(
          utilityJobStatus(await repo.require(id)),
          UtilityJobStatus.interrupted,
        );
      }
      expect(replayed, false);
    },
  );
  test(
    'bounded input budget is released on cancellation and completion',
    () async {
      final hold = Completer<void>(), entered = Completer<void>();
      final first = await engine.submit(
        'image_studio',
        'image',
        '内存限制',
        {},
        confirmed: true,
        retainedBytes: 150 * 1024 * 1024,
        run: (ctx, _) async {
          ctx.onCancel(() async => hold.complete());
          entered.complete();
          await hold.future;
          return null;
        },
      );
      await entered.future;
      await expectLater(
        engine.submit(
          'image_studio',
          'image',
          '超额',
          {},
          confirmed: true,
          retainedBytes: 60 * 1024 * 1024,
          run: (_, _) async => null,
        ),
        throwsA(isA<ToolFailure>()),
      );
      await engine.cancel(first.id);
      await engine.waitIdle();
      final next = await engine.submit(
        'image_studio',
        'image',
        '释放后',
        {},
        confirmed: true,
        retainedBytes: 180 * 1024 * 1024,
        run: (_, _) async => null,
      );
      await engine.waitIdle();
      expect(
        utilityJobStatus(await repo.require(next.id)),
        UtilityJobStatus.succeeded,
      );
    },
  );
  test(
    'exclusive exports validate bytes and preserve existing files',
    () async {
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final input = await files.importBytes('输入.png', data);
      final target = await files.exportFile(
        temp.path,
        '中文.png',
        await files.input(input.id),
        TaskCancellation(),
      );
      expect(await target.readAsBytes(), data);
      await expectLater(
        files.exportBytes(
          temp.path,
          '中文.png',
          Uint8List.fromList([9]),
          TaskCancellation(),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsBytes(), data);
      await expectLater(
        files.exportBytes(temp.path, '../escape', data, TaskCancellation()),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        files.exportBytes(temp.path, 'CON.txt', data, TaskCancellation()),
        throwsA(isA<ToolFailure>()),
      );
      final cancel = TaskCancellation()..cancel();
      await expectLater(
        files.exportBytes(temp.path, 'cancel.png', data, cancel),
        throwsA(isA<ToolFailure>()),
      );
      expect(await File('${temp.path}/cancel.png').exists(), false);
      await (await files.input(input.id)).writeAsBytes([5]);
      await expectLater(files.input(input.id), throwsA(isA<ToolFailure>()));
    },
  );
  test('disk-space preflight refuses output before creating a file', () async {
    final constrained = UtilityFileService(
      store,
      () async => owned,
      availableBytes: (_) async => 1,
    );
    await expectLater(
      constrained.exportBytes(
        temp.path,
        'no-space.txt',
        Uint8List.fromList([1, 2]),
        TaskCancellation(),
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(await File('${temp.path}/no-space.txt').exists(), false);
  });
  test(
    'ten real JPG files become decodable WebP outputs with persistent job refs',
    () async {
      final images = ImageToolService(store, () async => owned);
      final sources = <File>[];
      for (var i = 0; i < 10; i++) {
        final source = File('${temp.path}/photo-$i.jpg');
        await source.writeAsBytes(
          img.encodeJpg(img.Image(width: 40 + i, height: 30)),
        );
        sources.add(source);
      }
      final out = await Directory('${temp.path}/out').create();
      final job = await engine.submit(
        'converter',
        'image_batch',
        '十张真实图片',
        {},
        confirmed: true,
        run: (ctx, _) async {
          for (var i = 0; i < sources.length; i++) {
            final row = await images.process(
              'photo-$i.jpg',
              await sources[i].readAsBytes(),
              const ImageOptions(format: 'webp'),
              ctx.cancellation,
              confirmed: true,
              jobId: ctx.id,
            );
            await files.exportFile(
              out.path,
              'photo-$i.webp',
              owned.resolve(row.text('attachment')),
              ctx.cancellation,
            );
            await ctx.output(row.id);
            await ctx.progress(i + 1, 10, force: true);
          }
          return null;
        },
      );
      await engine.waitIdle();
      expect(
        utilityJobStatus(await repo.require(job.id)),
        UtilityJobStatus.succeeded,
      );
      expect(
        (await repo.require(job.id)).strings('outputReferences').length,
        10,
      );
      for (var i = 0; i < 10; i++) {
        final decoded = img.decodeWebP(
          await File('${out.path}/photo-$i.webp').readAsBytes(),
        );
        expect(decoded!.width, 40 + i);
        expect(await sources[i].exists(), true);
      }
    },
  );
  test(
    'rotation, flips, aspect fitting, no-upscale and alpha watermark are real',
    () async {
      final images = ImageToolService(store, () async => owned);
      final im = img.Image(width: 80, height: 40, numChannels: 4);
      img.fillRect(
        im,
        x1: 0,
        y1: 0,
        x2: 39,
        y2: 39,
        color: img.ColorRgba8(220, 0, 0, 255),
      );
      final bytes = img.encodePng(im);
      final rotated = await images.preview(
        bytes,
        const ImageOptions(rotation: 90),
      );
      expect((rotated.width, rotated.height), (40, 80));
      final flipped = img.decodePng(
        (await images.preview(
          bytes,
          const ImageOptions(flipHorizontal: true),
        )).bytes,
      )!;
      expect(flipped.getPixel(79, 0).r, 220);
      expect(flipped.getPixel(0, 0).a, 0);
      final fitted = await images.preview(
        bytes,
        const ImageOptions(width: 20, height: 20, maintainAspect: true),
      );
      expect((fitted.width, fitted.height), (20, 10));
      final kept = await images.preview(
        bytes,
        const ImageOptions(scalePercent: 200, noUpscale: true),
      );
      expect((kept.width, kept.height), (80, 40));
      final mark = img.Image(width: 5, height: 5, numChannels: 4)
        ..clear(img.ColorRgba8(0, 255, 0, 255));
      final marked = img.decodePng(
        (await images.preview(
          bytes,
          ImageOptions(
            watermark: img.encodePng(mark),
            watermarkPosition: 'topRight',
            watermarkMargin: 2,
            watermarkOpacity: .5,
          ),
        )).bytes,
      )!;
      expect(marked.getPixel(73, 2).g, greaterThan(100));
      expect(marked.getPixel(73, 2).a, inInclusiveRange(126, 129));
      await expectLater(
        images.preview(Uint8List(0), const ImageOptions()),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        images.preview(Uint8List.fromList([0, 1, 2]), const ImageOptions()),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        images.preview(
          bytes,
          const ImageOptions(cropWidth: 100, cropHeight: 100),
        ),
        throwsA(isA<ToolFailure>()),
      );
    },
  );
}
