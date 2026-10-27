import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/backup/backup_service.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/memory/memory_repository.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late RecordStore store;
  late BackupService backup;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt-backup-');
    db = AppDatabase.file(File('${root.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    backup = BackupService(db, OwnedFileStore(root), LocalDataHome(root));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  test('DB plus referenced attachments validate, activate on restart and preserve original for rollback', () async {
    final memory = MemoryRepository(store, () async => OwnedFileStore(root));
    final note = await memory.createNote('恢复测试', body: '中文笔记正文');
    final attachment = await memory.attach(
      note,
      'sample.txt',
      Uint8List.fromList(utf8.encode('真实附件内容')),
    );
    await store.setSetting('clipboard.config', jsonEncode({'enabled': true}));
    final zip = await backup.create();
    expect(await zip.exists(), true);
    final preview = await backup.inspect(zip);
    expect(preview.counts['note'], 1);
    expect(preview.files.length, 2);
    await store.save(note.copyWith(body: '备份后的新版本'));
    await backup.home.schedule(preview, confirmed: true);
    await db.close();
    expect(await backup.home.applyPending(), true);
    final active = await backup.home.active();
    expect(active.path, isNot(root.path));
    final restored = AppDatabase.file(
      File('${active.path}/links_toolbox.sqlite'),
    );
    await restored.initialize();
    try {
      final records = RecordStore(restored);
      expect((await records.get(note.id))!.body, '中文笔记正文');
      expect(
        jsonDecode((await records.setting('clipboard.config'))!)['enabled'],
        false,
      );
      expect(
        await OwnedFileStore(active)
            .resolve(attachment.text('attachment'))
            .readAsString(),
        '真实附件内容',
      );
    } finally {
      await restored.close();
    }
    await backup.home.rollbackPointer(confirmed: true);
    expect((await backup.home.active()).path, root.path);
    db = AppDatabase.file(File('${root.path}/links_toolbox.sqlite'));
    await db.initialize();
    expect((await RecordStore(db).get(note.id))!.body, '备份后的新版本');
  });
  test(
    'tampered staging rejects before activating and leaves original note',
    () async {
      final note = await store.create('note', '原始记录', body: '原样');
      final zip = await backup.create();
      final preview = await backup.inspect(zip);
      await File('${preview.directory.path}/database.sqlite')
          .writeAsString('corrupt');
      await backup.home.schedule(preview, confirmed: true);
      await expectLater(
        backup.home.applyPending(),
        throwsA(isA<ToolFailure>()),
      );
      expect((await backup.home.active()).path, root.path);
      expect((await store.get(note.id))!.body, '原样');
    },
  );
  test('archive traversal and malformed manifest are rejected without extraction outside staging', () async {
    final zip = File('${root.path}/malicious.zip');
    final archive = Archive()
      ..add(ArchiveFile.string('../escape.txt', 'forbidden'));
    await zip.writeAsBytes(ZipEncoder().encode(archive));
    await expectLater(backup.inspect(zip), throwsA(isA<ToolFailure>()));
    expect(await File('${root.path}/escape.txt').exists(), false);
  });
  test('missing referenced file aborts backup rather than delivering incomplete success', () async {
    await store.create(
      'attachment',
      'missing',
      data: {
        'attachment':
            'attachments/memory/00000000-0000-4000-8000-000000000000.bin',
      },
    );
    await expectLater(backup.create(), throwsA(isA<ToolFailure>()));
  });
}
