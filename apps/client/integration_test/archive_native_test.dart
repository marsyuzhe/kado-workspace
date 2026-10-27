import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows rename refuses overwrite, verified plan executes and undoes',
    (tester) async {
      if (!Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp('lt-native-archive-');
      final db = AppDatabase.file(File('${root.path}/records.sqlite'));
      await db.initialize();
      final native = NativePlatformAdapter();
      final dir = await Directory('${root.path}/files').create();
      final source = await File('${dir.path}/测试.txt').writeAsString('归档原生验收');
      final occupied = await File('${dir.path}/occupied.txt')
          .writeAsString('不可覆盖');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Archive native verification')),
        ),
      );
      try {
        await expectLater(
          native.moveFileExclusive(source.path, occupied.path),
          throwsA(anything),
        );
        expect(await occupied.readAsString(), '不可覆盖');
        expect(await source.exists(), true);
        final service = ArchiveService(RecordStore(db), native);
        final scan = await ArchiveScanner().scan(dir.path, TaskCancellation());
        final plan = await service.plan(
          scan.files,
          'rename',
          TaskCancellation(),
          rule: const RenameRule(prefix: '归档_'),
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
        final undo = await service.undo(journal, confirmed: true);
        expect(
          (undo.data['items'] as List).every((e) => e['status'] == 'undone'),
          true,
        );
        expect(await source.readAsString(), '归档原生验收');
      } finally {
        native.dispose();
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
