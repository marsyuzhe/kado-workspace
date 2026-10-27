import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/utilities/game_saves.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, source, destination, restore;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late GameSaveService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-game-test-');
    source = await Directory('${temp.path}/存档').create();
    destination = await Directory('${temp.path}/版本').create();
    restore = await Directory('${temp.path}/恢复').create();
    await Directory('${source.path}/世界/空目录').create(recursive: true);
    await File('${source.path}/世界/level.dat').writeAsString('原始世界一');
    await File('${source.path}/settings.json').writeAsString('{"中文":true}');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    service = GameSaveService(
      store,
      UtilityFileService(store, () async => OwnedFileStore(temp)),
      NativePlatformAdapter(),
      mover: (from, to) async {
        if (await FileSystemEntity.type(to, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const ToolFailure('测试移动禁止覆盖。');
        }
        if (await FileSystemEntity.type(from, followLinks: false) ==
            FileSystemEntityType.directory) {
          await Directory(from).rename(to);
        } else {
          await File(from).rename(to);
        }
      },
    );
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> profile({int keep = 5}) => service.save(
    '我的世界',
    'Windows / Java',
    source.path,
    destination.path,
    keep: keep,
  );
  Future<ToolRecord> job(
    String operation,
    Future<String?> Function(UtilityJobContext, Map<String, dynamic>) run,
  ) async {
    final submitted = await jobs.submit(
      'game_saves',
      operation,
      operation,
      {},
      confirmed: true,
      run: run,
    );
    return jobs.waitFor(submitted.id);
  }

  Future<ToolRecord> backup(ToolRecord p) async {
    final plan = await service.plan(p, TaskCancellation());
    final done = await job(
      'backup',
      (ctx, _) async => (await service.backup(plan, '升级前版本', ctx)).id,
    );
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  test('versioned streaming ZIP preserves Unicode, nested and empty directories; fresh restore and DB reopen', () async {
    // A real 8 MiB stream fixture exercises file-backed ZIP input/output.
    final sink = File('${source.path}/世界/region.bin').openWrite();
    final block = Uint8List.fromList(List.generate(65536, (i) => i % 251));
    for (var i = 0; i < 128; i++) {
      sink.add(block);
    }
    await sink.close();
    final p = await profile();
    final b = await backup(p);
    expect(b.number('fileCount'), 3);
    expect(b.number('directoryCount'), 2);
    expect(b.text('sha256'), hasLength(64));
    expect(b.text('status'), 'complete');
    await File('${source.path}/世界/level.dat').writeAsString('用户后来修改');
    final restored = await job(
      'restore',
      (ctx, _) async =>
          (await service.restore(b, restore.path, 'Links-restored-世界', ctx)).id,
    );
    expect(
      utilityJobStatus(restored),
      UtilityJobStatus.succeeded,
      reason: restored.text('errorMessage'),
    );
    expect(
      await File('${restore.path}/Links-restored-世界/世界/level.dat')
          .readAsString(),
      '原始世界一',
    );
    expect(
      await Directory('${restore.path}/Links-restored-世界/世界/空目录').exists(),
      true,
    );
    expect(
      await archiveHash(
        File('${restore.path}/Links-restored-世界/世界/region.bin'),
        TaskCancellation(),
      ),
      await archiveHash(
        File('${source.path}/世界/region.bin'),
        TaskCancellation(),
      ),
    );
    expect(await File('${source.path}/世界/level.dat').readAsString(), '用户后来修改');
    final conflict = await job(
      'restore',
      (ctx, _) async =>
          (await service.restore(b, restore.path, 'Links-restored-世界', ctx)).id,
    );
    expect(utilityJobStatus(conflict), UtilityJobStatus.failed);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await store.get(b.id))!.text('sha256'), b.text('sha256'));
    expect(
      (await store.list('game_restore'))
          .where((r) => r.text('status') == 'complete')
          .length,
      1,
    );
    expect(
      (await destination.list().toList()).any(
        (f) => f.path.endsWith('.part') || f.path.contains('.links-verify-'),
      ),
      false,
    );
  });
  test('changed sources and damaged archives fail without modifying saves; retention deletes only confirmed owned versions', () async {
    final p = await profile(keep: 1);
    final plan = await service.plan(p, TaskCancellation());
    await File('${source.path}/settings.json').writeAsString('预检后改变文件长度');
    final changed = await job(
      'backup',
      (ctx, _) async => (await service.backup(plan, '', ctx)).id,
    );
    expect(utilityJobStatus(changed), UtilityJobStatus.failed);
    expect(await destination.list().toList(), isEmpty);
    final first = await backup(p),
        second = await backup((await store.get(p.id))!);
    final old = await service.retentionPreview(p);
    expect(old.single.id, first.id);
    final refused = await job('cleanup', (ctx, _) async {
      await service.deleteBackups([first.id], ctx, confirmed: false);
      return null;
    });
    expect(utilityJobStatus(refused), UtilityJobStatus.failed);
    final deleted = await job('cleanup', (ctx, _) async {
      await service.deleteBackups([first.id], ctx, confirmed: true);
      return null;
    });
    expect(utilityJobStatus(deleted), UtilityJobStatus.succeeded);
    expect((await store.get(first.id))!.text('status'), 'deleted');
    final zip = await service.requireBackup(second, TaskCancellation());
    await zip.writeAsString('损坏ZIP', mode: FileMode.append);
    final bad = await job(
      'restore',
      (ctx, _) async => (await service.restore(
        second,
        restore.path,
        'Links-restored-bad',
        ctx,
      )).id,
    );
    expect(utilityJobStatus(bad), UtilityJobStatus.failed);
    expect(await restore.list().toList(), isEmpty);
    expect(
      await File('${source.path}/settings.json').readAsString(),
      '预检后改变文件长度',
    );
  });
  test('cancellation waits for the ZIP worker, cleans only owned temporary files and preserves sources', () async {
    final random = Random(47),
        out = File('${source.path}/large.bin').openWrite();
    final block = Uint8List.fromList(
      List.generate(1024 * 1024, (_) => random.nextInt(256)),
    );
    for (var i = 0; i < 20; i++) {
      out.add(block);
    }
    await out.close();
    final p = await profile(), plan = await service.plan(p, TaskCancellation());
    final submitted = await jobs.submit(
      'game_saves',
      'backup',
      '取消实际压缩',
      {},
      confirmed: true,
      run: (ctx, _) async => (await service.backup(plan, '', ctx)).id,
    );
    while ((await store.list('game_backup')).isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await jobs.cancel(submitted.id);
    final done = await jobs.waitFor(submitted.id);
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.cancelled,
      reason: done.text('errorMessage'),
    );
    expect(await destination.list().toList(), isEmpty);
    expect(await File('${source.path}/large.bin').length(), 20 * 1024 * 1024);
    expect(
      (await store.list('game_backup')).single.text('status'),
      'cancelled',
    );
  });
}

