import 'dart:io';

import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/hub/hub_repository.dart';
import 'package:links_toolbox/features/hub/search_service.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late RecordStore store;
  late HubRepository hub;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('links-hub-');
    db = AppDatabase(NativeDatabase(File('${dir.path}/db.sqlite')));
    await db.initialize();
    store = RecordStore(db);
    hub = HubRepository(store);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  test('v2 migration preserves original theme and disabled modules', () async {
    final schema = await db
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE name IN ('app_settings','module_preferences','sync_records','sync_cursors','sync_records_scope','sync_records_dirty') AND sql IS NOT NULL ORDER BY type DESC",
        )
        .get();
    final legacyFile = File('${dir.path}/v2.sqlite');
    final legacy = sqlite.sqlite3.open(legacyFile.path);
    for (final row in schema) {
      legacy.execute(row.read<String>('sql'));
    }
    legacy.execute("INSERT INTO app_settings VALUES ('themeMode','light')");
    legacy.execute("INSERT INTO module_preferences VALUES ('archive',0,4)");
    legacy.execute('PRAGMA user_version=2');
    legacy.close();
    await db.close();
    db = AppDatabase(NativeDatabase(legacyFile));
    await db.initialize();
    expect(
      (await db.select(db.modulePreferences).getSingle()).enabled,
      isFalse,
    );
    expect((await db.select(db.appSettings).getSingle()).value, 'light');
    expect(await db.select(db.localRecords).get(), isEmpty);
    expect(await db.verifyIntegrity(), isTrue);
  });
  test(
    'favorite add/edit/pin/category/order persists after real reopen',
    () async {
      final ai = await hub.addFavorite(
        'AI',
        const TargetAction('module', 'ai_desk'),
      );
      final mem = await hub.addFavorite(
        'Memory',
        const TargetAction('module', 'memory'),
      );
      await hub.updateFavorite(ai, pinned: true, category: '生产力');
      expect(
        (await hub.addFavorite(
          'duplicate',
          const TargetAction('module', 'memory'),
        )).id,
        mem.id,
      );
      await db.close();
      db = AppDatabase(NativeDatabase(File('${dir.path}/db.sqlite')));
      store = RecordStore(db);
      hub = HubRepository(store);
      final saved = await hub.favorites();
      expect(saved.length, 2);
      expect(saved.first.id, ai.id);
      expect(saved.first.text('category'), '生产力');
      await hub.removeFavorite(saved.last);
      expect((await hub.favorites()).length, 1);
    },
  );
  test(
    'real actions deduplicate recent targets and can be disabled and cleared',
    () async {
      const action = TargetAction('module', 'memory');
      await hub.recordOpened('笔记', 'memory', action);
      await hub.recordOpened('笔记', 'memory', action);
      expect((await db.select(db.recentActions).get()).length, 1);
      await hub.setRecentEnabled(false);
      await hub.recordOpened(
        'AI',
        'ai_desk',
        const TargetAction('module', 'ai_desk'),
      );
      expect((await db.select(db.recentActions).get()).length, 1);
      await hub.clearRecent();
      expect(await db.select(db.recentActions).get(), isEmpty);
    },
  );
  test('Chinese short substring and FTS trigram find real content and exclude tombstones', () async {
    final note = await store.create('note', '旅行计划', body: '上海周末骑行与摄影');
    expect((await store.search('上海')).single.id, note.id);
    expect((await store.search('周末骑行')).single.id, note.id);
    expect((await store.search('不存在')), isEmpty);
    final saved = await store.save(note.copyWith(body: '杭州周末徒步'));
    expect(await store.search('骑行'), isEmpty);
    await expectLater(
      store.save(note.copyWith(body: '过期内容')),
      throwsA(isA<RecordConflict>()),
    );
    await store.delete(saved);
    expect(await store.search('杭州'), isEmpty);
    final raw = await (db.select(db.localRecords)).getSingle();
    expect(raw.body, isEmpty);
    expect(raw.deletedAt, isNotNull);
  });
  test('unified search retains source and validates cursor scope', () async {
    await store.create('note', '工作笔记', body: '工作内容');
    await hub.addFavorite('工作台', const TargetAction('module', 'hub'));
    final service = SearchService([
      ModuleSearchProvider((m) => true),
      LocalSearchProvider(store),
    ]);
    final page = await service.search('工作', limit: 1);
    expect(page.results.length, 1);
    expect(page.nextCursor, isNotNull);
    final second = await service.search(
      '工作',
      limit: 1,
      cursor: page.nextCursor,
    );
    expect(second.results.single.id, isNot(page.results.single.id));
    await expectLater(
      service.search('别的', cursor: page.nextCursor),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      (await service.search(
        '工作',
        sourceFilters: {'memory'},
      )).results.every((r) => r.sourceModule == 'memory'),
      isTrue,
    );
  });
  test(
    'UUID and device identity remain stable under concurrent record creation',
    () async {
      final rows = await Future.wait(
        List.generate(5, (i) => store.create('note', 'n$i')),
      );
      expect(rows.map((r) => r.id).toSet().length, 5);
      expect(rows.map((r) => r.deviceId).toSet().length, 1);
      expect(RegExp(r'^[a-f0-9-]{36}$').hasMatch(rows.first.id), isTrue);
    },
  );
  test(
    'launch descriptors reject shell strings and unsupported URL schemes',
    () {
      expect(
        () => const TargetAction('url', 'javascript:alert(1)').validate(),
        throwsA(isA<ToolFailure>()),
      );
      expect(
        () => const TargetAction('application', 'cmd /c del').validate(),
        throwsA(isA<ToolFailure>()),
      );
      expect(
        const TargetAction(
          'application',
          r'C:\Tools\tool.exe',
          arguments: ['--flag', 'a b'],
        ).toJson()['arguments'],
        ['--flag', 'a b'],
      );
    },
  );
}
