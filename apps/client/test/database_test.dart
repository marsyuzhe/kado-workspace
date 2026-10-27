import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  late Directory directory;
  late AppDatabase db;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('links-database-test-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/source.sqlite')));
    await db.initialize();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'settings and disabled modules survive a real database reopen',
    () async {
      final repository = SettingsRepository(db);
      expect((await repository.load()).themeMode, ThemeMode.dark);
      await repository.setTheme(ThemeMode.light);
      await repository.setModuleEnabled('archive', false);
      await db.close();
      db = AppDatabase(NativeDatabase(File('${directory.path}/source.sqlite')));
      final settings = await SettingsRepository(db).load();
      expect(settings.themeMode, ThemeMode.light);
      expect(settings.moduleEnabled('archive'), isFalse);
      expect(settings.moduleEnabled('memory'), isTrue);
    },
  );

  test('schema v1 upgrades to current without losing settings', () async {
    await db.close();
    final file = File('${directory.path}/v1.sqlite');
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute(
      'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
    );
    legacy.execute("INSERT INTO app_settings VALUES ('themeMode', 'system')");
    legacy.execute('PRAGMA user_version = 1');
    legacy.close();
    final upgraded = db = AppDatabase(NativeDatabase(file));
    await upgraded.initialize();
    expect(
      (await SettingsRepository(upgraded).load()).themeMode,
      ThemeMode.system,
    );
    expect(await upgraded.select(upgraded.syncRecords).get(), isEmpty);
    expect(await upgraded.verifyIntegrity(), isTrue);
    final version = await upgraded
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(version.data.values.single, upgraded.schemaVersion);
    expect(
      (await upgraded.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .single,
      1,
    );
  });

  test('transaction rolls back on interrupted setting write', () async {
    await expectLater(
      db.transaction(() async {
        await db
            .into(db.appSettings)
            .insert(
              AppSettingsCompanion.insert(key: 'themeMode', value: 'light'),
            );
        throw StateError('injected failure');
      }),
      throwsStateError,
    );
    expect((await SettingsRepository(db).load()).themeMode, ThemeMode.dark);
  });

  test(
    'snapshot is independently readable and never overwrites a destination',
    () async {
      await db.customStatement('PRAGMA journal_mode = WAL');
      await SettingsRepository(db).setTheme(ThemeMode.light);
      final backup = File('${directory.path}/backup.sqlite');
      await db.backupTo(backup);
      await expectLater(db.backupTo(backup), throwsStateError);
      await db.close();
      final restored = db = AppDatabase(NativeDatabase(backup));
      expect(await restored.verifyIntegrity(), isTrue);
      expect(
        (await SettingsRepository(restored).load()).themeMode,
        ThemeMode.light,
      );
    },
  );

  test(
    'sync schema retains tombstones and scoped cursors; rejects version zero',
    () async {
      final now = DateTime.now().toUtc();
      SyncRecordsCompanion record(int version) => SyncRecordsCompanion.insert(
        id: '43b215a8-e0ad-4b98-9f20-57e322b11a67',
        collection: 'notes',
        ownerId: 'local-owner',
        createdAt: now,
        updatedAt: now,
        version: version,
        deviceId: 'test-device',
        payload: '{}',
        deletedAt: Value(now),
      );
      await expectLater(
        db.into(db.syncRecords).insert(record(0)),
        throwsA(isA<Exception>()),
      );
      await db.into(db.syncRecords).insert(record(1));
      final saved = await db.select(db.syncRecords).getSingle();
      expect(saved.deletedAt, isNotNull);
      expect(saved.localDirty, isTrue);
      expect(saved.lastSyncedVersion, 0);
      for (final owner in ['a', 'b']) {
        await db
            .into(db.syncCursors)
            .insert(
              SyncCursorsCompanion.insert(
                ownerId: owner,
                deviceId: 'd',
                collection: 'notes',
                cursor: 'c',
              ),
            );
      }
      expect((await db.select(db.syncCursors).get()).length, 2);
    },
  );

  test('corrupt database fails without replacing user bytes', () async {
    await db.close();
    final corrupt = File('${directory.path}/corrupt.sqlite');
    await corrupt.writeAsString('preserve-original-content');
    final broken = db = AppDatabase(NativeDatabase(corrupt));
    try {
      await expectLater(broken.initialize(), throwsA(isA<Exception>()));
    } finally {
      await broken.close();
    }
    expect(await corrupt.readAsString(), 'preserve-original-content');
  });

  test(
    'future schema is rejected and its original data remains readable',
    () async {
      await db.close();
      final future = File('${directory.path}/future.sqlite');
      final raw = sqlite.sqlite3.open(future.path);
      raw.execute(
        'CREATE TABLE app_settings (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
      );
      raw.execute("INSERT INTO app_settings VALUES ('themeMode', 'light')");
      raw.execute('PRAGMA user_version = 99');
      raw.close();
      db = AppDatabase(NativeDatabase(future));
      await expectLater(db.initialize(), throwsA(anything));
      await db.close();
      final preserved = sqlite.sqlite3.open(future.path);
      try {
        expect(
          preserved.select('PRAGMA user_version').single.values.single,
          99,
        );
        expect(
          preserved
              .select('SELECT value FROM app_settings')
              .single
              .values
              .single,
          'light',
        );
      } finally {
        preserved.close();
      }
    },
  );
}
