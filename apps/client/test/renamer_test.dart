import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late ArchiveService service;
  late NativePlatformAdapter native;
  Future<void> move(String from, String to) async {
    if (await FileSystemEntity.type(to, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ToolFailure('禁止覆盖');
    }
    await File(from).rename(to);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-renamer-');
    db = AppDatabase.file(File('${temp.path}/db/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    native = NativePlatformAdapter();
    service = ArchiveService(store, native, mover: move);
  });
  tearDown(() async {
    native.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<List<ArchiveFile>> fixture(int count) async {
    final dir = await Directory('${temp.path}/files').create();
    for (var i = 0; i < count; i++) {
      await File('${dir.path}/原图 $i.jpg').writeAsString('内容-${i * 97}');
    }
    return (await ArchiveScanner().scan(
      dir.path,
      TaskCancellation(),
    )).files.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  test('30 unicode files keep exact contents through sequence step and conditional undo after reopening DB', () async {
    final files = await fixture(30), hashes = <String, String>{};
    for (final f in files) {
      hashes[f.path] = await archiveHash(File(f.path), TaskCancellation());
    }
    final plan = await service.plan(
      files,
      'rename',
      TaskCancellation(),
      stagedRename: true,
      rule: const RenameRule(
        prefix: '旅行_',
        sequence: true,
        keepOriginal: false,
        sequenceStart: 7,
        sequenceStep: 2,
        sequenceWidth: 3,
      ),
    );
    expect(plan.valid, true);
    expect(plan.files.first.target.endsWith('旅行_007.jpg'), true);
    expect(plan.files[1].target.endsWith('旅行_009.jpg'), true);
    final journal = await service.execute(
      plan,
      TaskCancellation(),
      confirmed: true,
    );
    expect(journal.text('status'), 'finished');
    for (final f in plan.files) {
      expect(
        await archiveHash(File(f.target), TaskCancellation()),
        hashes[f.source],
      );
    }
    await db.close();
    db = AppDatabase.file(File('${temp.path}/db/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    service = ArchiveService(store, native, mover: move);
    final undone = await service.undo(
      (await store.get(journal.id))!,
      confirmed: true,
    );
    expect(undone.text('status'), 'undone');
    for (final entry in hashes.entries) {
      expect(
        await archiveHash(File(entry.key), TaskCancellation()),
        entry.value,
      );
    }
  });
  test(
    'cyclic names swap with exclusive temporary moves and undo safely',
    () async {
      final files = await fixture(3), before = <String, String>{};
      for (final f in files) {
        before[f.path] = await File(f.path).readAsString();
      }
      final names = [files[1].name, files[2].name, files[0].name];
      final plan = await service.plan(
        files,
        'rename',
        TaskCancellation(),
        stagedRename: true,
        names: names,
      );
      expect(plan.valid, true);
      final journal = await service.execute(
        plan,
        TaskCancellation(),
        confirmed: true,
      );
      expect(journal.text('status'), 'finished');
      for (final f in plan.files) {
        expect(await File(f.target).readAsString(), before[f.source]);
      }
      expect(
        (await service.undo(journal, confirmed: true)).text('status'),
        'undone',
      );
      for (final e in before.entries) {
        expect(await File(e.key).readAsString(), e.value);
      }
    },
  );
  test(
    'changed output rejects the whole undo before touching other files',
    () async {
      final files = await fixture(3);
      final plan = await service.plan(
        files,
        'rename',
        TaskCancellation(),
        stagedRename: true,
        rule: const RenameRule(prefix: '新_'),
      );
      final journal = await service.execute(
        plan,
        TaskCancellation(),
        confirmed: true,
      );
      await File(plan.files.last.target).writeAsString('用户后续编辑');
      final rejected = await service.undo(journal, confirmed: true);
      expect(rejected.text('undoError'), contains('内容已变化'));
      for (final f in plan.files) {
        expect(await File(f.target).exists(), true);
        expect(await File(f.source).exists(), false);
      }
      expect(await File(plan.files.last.target).readAsString(), '用户后续编辑');
    },
  );
  test('staging failure is journaled and partial files can be restored without overwrite', () async {
    final files = await fixture(3);
    var moves = 0;
    service = ArchiveService(
      store,
      native,
      mover: (a, b) async {
        if (++moves == 2) throw const ToolFailure('文件占用');
        await move(a, b);
      },
    );
    final plan = await service.plan(
      files,
      'rename',
      TaskCancellation(),
      stagedRename: true,
      rule: const RenameRule(prefix: '新_'),
    );
    final journal = await service.execute(
      plan,
      TaskCancellation(),
      confirmed: true,
    );
    expect(journal.text('status'), 'failed');
    service = ArchiveService(store, native, mover: move);
    final undone = await service.undo(journal, confirmed: true);
    expect(undone.text('status'), 'undone');
    for (final f in files) {
      expect(await File(f.path).exists(), true);
    }
    expect((await Directory('${temp.path}/files').list().toList()).length, 3);
  });
  test(
    'reserved, repeated, unchanged, stale and missing inputs never overwrite',
    () async {
      final files = await fixture(2);
      for (final names in [
        ['CON.txt', 'ok.txt'],
        ['same.jpg', 'same.jpg'],
        [files[0].name, files[1].name],
      ]) {
        expect(
          (await service.plan(
            files,
            'rename',
            TaskCancellation(),
            stagedRename: true,
            names: names,
          )).valid,
          false,
        );
      }
      final plan = await service.plan(
        files,
        'rename',
        TaskCancellation(),
        stagedRename: true,
        rule: const RenameRule(prefix: 'new_'),
      );
      await File(plan.files.first.target).writeAsString('foreign');
      final result = await service.execute(
        plan,
        TaskCancellation(),
        confirmed: true,
      );
      expect(result.text('status'), 'failed');
      expect(await File(plan.files.first.target).readAsString(), 'foreign');
      for (final f in files) {
        expect(await File(f.path).exists(), true);
      }
      await File(files.first.path).delete();
      expect(
        (await service.plan(
          files,
          'rename',
          TaskCancellation(),
          stagedRename: true,
          rule: const RenameRule(prefix: 'x_'),
        )).valid,
        false,
      );
    },
  );
}
