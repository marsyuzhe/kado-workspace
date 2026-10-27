import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real SQLite transaction holds the shared gate before other writers queue',
    () async {
      final temp = await Directory.systemTemp.createTemp('lt-lock-order-'),
          db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      final store = RecordStore(db),
          entered = Completer<void>(),
          release = Completer<void>();
      try {
        final transaction = store.transaction(() async {
          await store.create('test', 'First');
          entered.complete();
          await release.future;
          await store.create('test', 'Second');
        });
        await entered.future;
        final competing = store.create('test', 'Competing timer writer');
        release.complete();
        await Future.wait([transaction, competing])
            .timeout(const Duration(seconds: 5));
        expect((await store.list('test')).length, 3);
      } finally {
        if (!release.isCompleted) release.complete();
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
