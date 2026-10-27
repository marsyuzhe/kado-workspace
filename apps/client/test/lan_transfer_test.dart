import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/utilities/lan_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, input, received, output;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late LanTransferService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-transfer-test-');
    input = await Directory('${temp.path}/源文件').create();
    received = await Directory('${temp.path}/接收').create();
    output = await Directory('${temp.path}/输出').create();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    service = LanTransferService(
      store,
      UtilityFileService(store, () async => OwnedFileStore(temp)),
      NativePlatformAdapter(),
    );
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> run(
    String operation,
    Future<String?> Function(UtilityJobContext, Map<String, dynamic>) handler,
  ) async {
    final j = await jobs.submit(
      'lan_transfer',
      operation,
      operation,
      {},
      confirmed: true,
      run: handler,
    );
    return jobs.waitFor(j.id);
  }

  Future<ToolRecord> result(ToolRecord done) async {
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  test('real file manifest export excludes absolute paths; receiver detects match, missing and corruption', () async {
    final one = await File('${input.path}/中文.txt').writeAsString('授权文件内容');
    final two = await File('${input.path}/two.bin')
        .writeAsBytes(List.generate(1024 * 1024, (i) => i % 251));
    final manifest = await result(
      await run(
        'prepare',
        (ctx, _) async => (await service.prepare([one.path, two.path], ctx)).id,
      ),
    );
    expect(manifest.flag('deliveryConfirmed'), false);
    expect(manifest.text('status'), 'prepared');
    final exported = await result(
      await run(
        'export',
        (ctx, _) async => (await service.export(manifest, output.path, ctx)).id,
      ),
    );
    final text = await File(exported.text('outputPath')).readAsString();
    expect(text, contains('sha256'));
    expect(text, isNot(contains(input.path)));
    expect(text, isNot(contains('source')));
    await one.copy('${received.path}/中文.txt');
    await two.copy('${received.path}/two.bin');
    final checked = await result(
      await run(
        'verify',
        (ctx, _) async => (await service.verifyReceived(
          exported.text('outputPath'),
          received.path,
          ctx,
        )).id,
      ),
    );
    expect(checked.text('status'), 'verified');
    expect(checked.number('matched'), 2);
    await File('${received.path}/two.bin').writeAsString('损坏');
    await File('${received.path}/中文.txt').delete();
    final bad = await result(
      await run(
        'verify',
        (ctx, _) async => (await service.verifyReceived(
          exported.text('outputPath'),
          received.path,
          ctx,
        )).id,
      ),
    );
    expect(bad.text('status'), 'mismatch');
    expect(bad.number('matched'), 0);
    expect(
      (bad.data['results'] as List).map((r) => (r as Map)['status']),
      containsAll(['missing', 'mismatch']),
    );
    expect(await one.readAsString(), '授权文件内容');
    final overwrite = await run(
      'export',
      (ctx, _) async => (await service.export(manifest, output.path, ctx)).id,
    );
    expect(utilityJobStatus(overwrite), UtilityJobStatus.failed);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await store.list('transfer_verification')).length, 2);
  });
  test('folder manifest preserves relative paths and rejects traversal, duplicate basenames and modified handoff inputs', () async {
    await Directory('${input.path}/目录').create();
    final src = await File('${input.path}/目录/save.dat').writeAsString('safe');
    final manifest = await result(
      await run(
        'prepare',
        (ctx, _) async =>
            (await service.prepare([], ctx, directory: input.path)).id,
      ),
    );
    expect(
      ((manifest.data['files'] as List).single as Map)['name'],
      '目录/save.dat',
    );
    for (final name in [
      '../escape',
      '/absolute',
      'C:/outside',
      'folder/../outside',
      'x\\y',
      'x:ads',
    ]) {
      expect(
        () => service.parseManifest(
          '{"schemaVersion":1,"totalBytes":4,"files":[{"name":"$name","size":4,"sha256":"${'a' * 64}"}]}',
        ),
        throwsA(isA<ToolFailure>()),
      );
    }
    final same = await File('${input.path}/save.dat').writeAsString('second');
    final duplicate = await run(
      'prepare',
      (ctx, _) async => (await service.prepare([src.path, same.path], ctx)).id,
    );
    expect(utilityJobStatus(duplicate), UtilityJobStatus.failed);
    final executable = await File('${temp.path}/localsend_app.exe')
        .writeAsString('owned inert fixture; never executed');
    // Only an inert executable fingerprint fixture is used here. No network
    // app is launched and no delivery is simulated by this test.
    final hash = await File(executable.path).readAsBytes();
    expect(hash, isNotEmpty);
    final dll = await File('${temp.path}/flutter_windows.dll')
        .writeAsString('inert DLL; never loaded');
    final aot = await File('${temp.path}/data/app.so').create(recursive: true);
    await aot.writeAsString('inert AOT; never loaded');
    final runtime = await store.create(
      'transfer_runtime',
      'inert fixture',
      data: {
        'path': executable.path,
        'size': await executable.length(),
        'fingerprints': {
          'localsend_app.exe': await archiveHash(
            executable,
            TaskCancellation(),
          ),
          'flutter_windows.dll': await archiveHash(dll, TaskCancellation()),
          'data/app.so': await archiveHash(aot, TaskCancellation()),
        },
        'sha256': await archiveHash(executable, TaskCancellation()),
      },
    );
    final preflight = await run('handoff', (ctx, _) async {
      final action = await service.handoff(runtime, manifest, ctx);
      expect(action.target, executable.path);
      expect(action.arguments, isEmpty);
      return null;
    });
    expect(utilityJobStatus(preflight), UtilityJobStatus.succeeded);
    await src.writeAsString('source changed after manifest');
    final refused = await run('handoff', (ctx, _) async {
      await service.handoff(runtime, manifest, ctx);
      return null;
    });
    expect(utilityJobStatus(refused), UtilityJobStatus.failed);
    expect((await store.get(manifest.id))!.text('status'), 'prepared');
  });
}
