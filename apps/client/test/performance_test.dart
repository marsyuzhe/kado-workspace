import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/memory/memory_repository.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';

void main() {
  test(
    'bounded note summaries and cancellable scans on larger own fixtures',
    () async {
      final root = await Directory.systemTemp.createTemp('lt-performance-');
      final db = AppDatabase.file(
        File(p.join(root.path, 'performance.sqlite')),
      );
      await db.initialize();
      final metrics = <String, dynamic>{
        'mode': 'Dart test, real SQLite and filesystem, fixture-only',
        'platform': Platform.operatingSystem,
      };
      try {
        final store = RecordStore(db);
        final memory = MemoryRepository(
          store,
          () async => OwnedFileStore(root),
        );
        final body = '中文全文检索关键内容\n${'正文数据ABC123\n' * 700}';
        final watch = Stopwatch()..start();
        await db.transaction(() async {
          for (var i = 0; i < 250; i++) {
            await memory.createNote('笔记$i', body: body);
          }
        });
        metrics['insert250NotesMs'] = watch.elapsedMilliseconds;
        metrics['bodyBytesEach'] = utf8.encode(body).length;
        watch.reset();
        final summaries = await memory.watchSummaries(limit: 500).first;
        metrics['load250SummariesMs'] = watch.elapsedMilliseconds;
        expect(summaries.length, 250);
        expect(summaries.every((s) => s.preview.length == 160), true);
        watch.reset();
        final found = await store.search('检索关键内容', kinds: ['note'], limit: 300);
        metrics['ChineseFts250NotesMs'] = watch.elapsedMilliseconds;
        expect(found.length, 250);
        final folder = await Directory(p.join(root.path, 'scan-fixture'))
            .create();
        for (var i = 0; i < 1000; i++) {
          await File(p.join(folder.path, 'file-$i.txt'))
              .writeAsString('fixture-$i');
        }
        watch.reset();
        final all = await ArchiveScanner().scan(
          folder.path,
          TaskCancellation(),
        );
        metrics['scan1000FilesMs'] = watch.elapsedMilliseconds;
        expect(all.files.length, 1000);
        final cancel = TaskCancellation();
        final partial = await ArchiveScanner().scan(
          folder.path,
          cancel,
          onProgress: (n, _) {
            if (n >= 250) cancel.cancel();
          },
        );
        expect(partial.cancelled, true);
        expect(partial.files.length, lessThan(1000));
        final output = File(
          p.normalize(
            p.join(
              Directory.current.path,
              '..',
              '..',
              'artifacts',
              'reports',
              'performance-regression.json',
            ),
          ),
        );
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(metrics),
          flush: true,
        );
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
