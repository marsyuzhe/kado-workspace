import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late ArchiveService service;
  late NativePlatformAdapter native;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt-archive-test-');
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    native = NativePlatformAdapter();
    service = ArchiveService(
      RecordStore(db),
      native,
      mover: (source, target) async {
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const ToolFailure('禁止覆盖');
        }
        await File(source).rename(target);
      },
    );
  });
  tearDown(() async {
    native.dispose();
    await db.close();
    await root.delete(recursive: true);
  });
  Future<ScanResult> fixture() async {
    await File('${root.path}/first.txt').writeAsString('相同内容');
    await File('${root.path}/second.md').writeAsString('相同内容');
    await File('${root.path}/third.txt').writeAsString('不同内容');
    return ArchiveScanner().scan(root.path, TaskCancellation());
  }

  test(
    'authorized scan statistics, Chinese metadata index and SHA duplicates',
    () async {
      final grant = await service.grant(root.path);
      final scan = await fixture();
      expect(scan.files.length, 3);
      expect(scan.bytes, 36);
      expect(scan.categories['文档'], 3);
      await service.index(grant, scan);
      expect((await service.store.search('first')).length, 1);
      final groups = await DuplicateDetector().find(
        scan.files,
        TaskCancellation(),
      );
      expect(groups.length, 1);
      expect(groups.single.length, 2);
    },
  );
  test(
    'cancel and bounds yield explicit partial scans without mutations',
    () async {
      await fixture();
      final token = TaskCancellation()..cancel();
      final scan = await ArchiveScanner().scan(root.path, token);
      expect(scan.cancelled, true);
      expect(scan.files, isEmpty);
      final limited = await ArchiveScanner().scan(
        root.path,
        TaskCancellation(),
        limit: 2,
      );
      expect(limited.limited, true);
      expect(limited.files.length, 2);
      expect((await root.list().toList()).length, 3);
    },
  );
  test(
    'rename preview confirms then real execute, logs and conditional undo',
    () async {
      final scan = await fixture();
      final plan = await service.plan(
        scan.files,
        'rename',
        TaskCancellation(),
        rule: const RenameRule(prefix: '归档_', sequence: true),
      );
      expect(plan.valid, true);
      expect(await File(plan.files.first.target).exists(), false);
      await expectLater(
        service.execute(plan, TaskCancellation(), confirmed: false),
        throwsA(isA<ToolFailure>()),
      );
      final journal = await service.execute(
        plan,
        TaskCancellation(),
        confirmed: true,
      );
      expect(
        (journal.data['items'] as List).every((e) => e['status'] == 'done'),
        true,
      );
      for (final f in plan.files) {
        expect(await File(f.source).exists(), false);
        expect(await File(f.target).exists(), true);
      }
      final undone = await service.undo(journal, confirmed: true);
      expect(
        (undone.data['items'] as List).every((e) => e['status'] == 'undone'),
        true,
      );
      expect(
        (await ArchiveScanner().scan(
          root.path,
          TaskCancellation(),
        )).files.length,
        3,
      );
    },
  );
  test(
    'collision, reserved name and changed source cannot overwrite files',
    () async {
      final scan = await fixture();
      final invalid = await service.plan(
        scan.files,
        'rename',
        TaskCancellation(),
        rule: const RenameRule(),
      );
      expect(invalid.valid, false);
      expect(validArchiveName('CON.txt'), false);
      expect(validArchiveName('../a.txt'), false);
      final plan = await service.plan(
        [scan.files.first],
        'rename',
        TaskCancellation(),
        rule: const RenameRule(prefix: 'new_'),
      );
      await File(plan.files.first.source).writeAsString('changed');
      final journal = await service.execute(
        plan,
        TaskCancellation(),
        confirmed: true,
      );
      expect((journal.data['items'] as List).single['status'], 'failed');
      expect(await File(plan.files.first.target).exists(), false);
    },
  );
  test('undo refuses changed target and occupied original path', () async {
    final scan = await fixture();
    final plan = await service.plan(
      [scan.files.first],
      'rename',
      TaskCancellation(),
      rule: const RenameRule(prefix: 'new_'),
    );
    final journal = await service.execute(
      plan,
      TaskCancellation(),
      confirmed: true,
    );
    await File(plan.files.first.source).writeAsString('new occupied file');
    final undone = await service.undo(journal, confirmed: true);
    expect((undone.data['items'] as List).single['undoError'], isNotNull);
    expect(
      await File(plan.files.first.source).readAsString(),
      'new occupied file',
    );
    await File(plan.files.first.target).writeAsString('modified target');
    final refused = await service.undo(undone, confirmed: true);
    expect((refused.data['items'] as List).single['status'], 'done');
    expect(
      await File(plan.files.first.target).readAsString(),
      'modified target',
    );
  });
  test('copy preserves source and undo retains copied content in recovery directory', () async {
    final scan = await fixture();
    final dest = await Directory('${root.path}/dest').create();
    final plan = await service.plan(
      [scan.files.first],
      'copy',
      TaskCancellation(),
      destination: dest.path,
      byCategory: true,
    );
    final journal = await service.execute(
      plan,
      TaskCancellation(),
      confirmed: true,
    );
    expect(await File(plan.files.first.source).exists(), true);
    expect(await File(plan.files.first.target).exists(), true);
    final undone = await service.undo(journal, confirmed: true);
    expect((undone.data['items'] as List).single['status'], 'undone');
    expect(await File(plan.files.first.target).exists(), false);
    final retained = await dest
        .list(recursive: true)
        .where((e) => e is File)
        .toList();
    expect(retained.length, 1);
    expect(
      await File(retained.single.path).readAsString(),
      await File(plan.files.first.source).readAsString(),
    );
  });
}
