import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/utilities/software_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late UtilityJobEngine jobs;
  late NativePlatformAdapter native;
  late SoftwareLibraryService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-software-library-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    native = NativePlatformAdapter();
    service = SoftwareLibraryService(store, native);
  });
  tearDown(() async {
    await jobs.dispose();
    native.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  test('safe test package streams SHA256, records explicit unavailable metadata, exact duplicates and edits persist', () async {
    final paths = <String>[];
    for (var i = 0; i < 3; i++) {
      final file = File('${temp.path}/safe-test-$i.zip');
      await file.writeAsString(
        'safe controlled test data $i; never an executable',
      );
      paths.add(file.path);
    }
    final row = await jobs.submit(
      'software_library',
      'import',
      '安全测试文件',
      {},
      confirmed: true,
      run: (ctx, _) async {
        await service.importPaths(paths, ctx);
        return null;
      },
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(row.id)),
      UtilityJobStatus.succeeded,
    );
    var records = await store.list('software_package');
    expect(records.length, 3);
    for (final record in records) {
      expect(
        record.text('sha256'),
        (await sha256.bind(File(record.text('installerPath')).openRead()).first)
            .toString(),
      );
      expect(record.text('version'), isEmpty);
      expect(record.text('signatureStatus'), 'not_available');
    }
    final duplicate = await jobs.submit(
      'software_library',
      'import',
      '重复登记',
      {},
      confirmed: true,
      run: (ctx, _) async {
        await service.importPaths(paths, ctx);
        return null;
      },
    );
    await jobs.waitIdle();
    expect((await store.list('software_package')).length, 3);
    expect(
      utilityJobStatus(await jobs.repository.require(duplicate.id)),
      UtilityJobStatus.succeeded,
    );
    final edited = await service.edit(
      records.first,
      name: '测试软件',
      version: '手动版本1',
      publisher: '用户填写',
      category: '开发',
      officialUrl: 'https://example.invalid',
      notes: '可搜索的说明',
      favorite: true,
    );
    await expectLater(
      service.edit(
        edited,
        name: '测试',
        version: '',
        publisher: '',
        category: '',
        officialUrl: 'javascript:bad()',
        notes: '',
        favorite: false,
      ),
      throwsA(isA<ToolFailure>()),
    );
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await store.get(edited.id))!.text('version'), '手动版本1');
    expect((await store.get(edited.id))!.flag('favorite'), true);
  });
  test('changed, missing and empty packages fail verification and never launch or overwrite', () async {
    final file = File('${temp.path}/safe.zip');
    await file.writeAsString('initial');
    ToolRecord? package;
    final job = await jobs.submit(
      'software_library',
      'import',
      '登记',
      {},
      confirmed: true,
      run: (ctx, _) async {
        package = (await service.importPaths([file.path], ctx)).single;
        return package!.id;
      },
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(job.id)),
      UtilityJobStatus.succeeded,
    );
    await file.writeAsString('subsequent edit');
    final verify = await jobs.submit(
      'software_library',
      'verify',
      '检查变化',
      {},
      confirmed: true,
      run: (ctx, _) async => (await service.verify(package!.id, ctx)).id,
    );
    await jobs.waitIdle();
    expect(
      utilityJobStatus(await jobs.repository.require(verify.id)),
      UtilityJobStatus.failed,
    );
    expect((await store.get(package!.id))!.flag('checksumMatches'), false);
    expect(await file.readAsString(), 'subsequent edit');
    await file.delete();
    await expectLater(service.selected(file.path), throwsA(isA<ToolFailure>()));
    await file.create();
    await expectLater(service.selected(file.path), throwsA(isA<ToolFailure>()));
  });
}
