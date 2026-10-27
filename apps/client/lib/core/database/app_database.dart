import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../storage/data_mutation_gate.dart';

part 'app_database.g.dart';

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

class ModulePreferences extends Table {
  TextColumn get moduleId => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {moduleId};
}

class SyncRecords extends Table {
  TextColumn get id => text()();
  TextColumn get collection => text()();
  TextColumn get ownerId => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version =>
      integer().customConstraint('NOT NULL CHECK (version >= 1)')();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get deviceId => text()();
  TextColumn get payload => text()();
  BoolColumn get localDirty => boolean().withDefault(const Constant(true))();
  IntColumn get lastSyncedVersion => integer().withDefault(const Constant(0))();
  TextColumn get syncState => text().withDefault(const Constant('localOnly'))();
  TextColumn get lastSyncError => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class SyncCursors extends Table {
  TextColumn get ownerId => text()();
  TextColumn get deviceId => text()();
  TextColumn get collection => text()();
  TextColumn get cursor => text()();
  @override
  Set<Column> get primaryKey => {ownerId, deviceId, collection};
}

class LocalRecords extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get data => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get revision =>
      integer().customConstraint('NOT NULL CHECK (revision >= 1)')();
  TextColumn get deviceId => text()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get syncStatus =>
      text().withDefault(const Constant('localOnly'))();
  @override
  Set<Column> get primaryKey => {id};
}

class RecentActions extends Table {
  TextColumn get id => text()();
  TextColumn get targetKey => text().unique()();
  TextColumn get title => text()();
  TextColumn get moduleId => text()();
  TextColumn get action => text()();
  DateTimeColumn get openedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    AppSettings,
    ModulePreferences,
    SyncRecords,
    SyncCursors,
    LocalRecords,
    RecentActions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor, {this.location});
  final File? location;
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => DataMutationGate.shared.run(
    () => super.transaction(action, requireNew: requireNew),
  );

  factory AppDatabase.file(File file) =>
      AppDatabase(NativeDatabase.createInBackground(file), location: file);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
      await _createRecordIndexes();
    },
    onUpgrade: (m, from, to) async {
      if (from < 1 || from > 2 || to != 3) {
        throw StateError('Unsupported schema migration');
      }
      await transaction(() async {
        if (from < 2) {
          await m.createTable(modulePreferences);
          await m.createTable(syncRecords);
          await m.createTable(syncCursors);
          await _createIndexes();
        }
        if (from < 3) {
          await m.createTable(localRecords);
          await m.createTable(recentActions);
          await _createRecordIndexes();
        }
      });
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX sync_records_scope ON sync_records '
      '(owner_id, collection, updated_at)',
    );
    await customStatement(
      'CREATE INDEX sync_records_dirty ON sync_records (local_dirty)',
    );
  }

  Future<void> _createRecordIndexes() async {
    await customStatement(
      'CREATE INDEX local_records_kind_time ON local_records(kind,deleted_at,updated_at)',
    );
    await customStatement(
      'CREATE INDEX recent_actions_time ON recent_actions(opened_at)',
    );
    await customStatement(
      "CREATE VIRTUAL TABLE record_search USING fts5(record_id UNINDEXED,title,body,kind UNINDEXED,tokenize='trigram')",
    );
    await customStatement(
      '''CREATE TRIGGER records_search_insert AFTER INSERT ON local_records WHEN new.deleted_at IS NULL BEGIN
      INSERT INTO record_search(record_id,title,body,kind) VALUES(new.id,new.title,new.body,new.kind); END''',
    );
    await customStatement(
      '''CREATE TRIGGER records_search_update AFTER UPDATE ON local_records BEGIN
      DELETE FROM record_search WHERE record_id=old.id;
      INSERT INTO record_search(record_id,title,body,kind) SELECT new.id,new.title,new.body,new.kind WHERE new.deleted_at IS NULL; END''',
    );
    await customStatement('''CREATE TRIGGER records_search_delete AFTER DELETE ON local_records BEGIN
      DELETE FROM record_search WHERE record_id=old.id; END''');
  }

  Future<void> initialize() async {
    await customSelect('SELECT 1').getSingle();
  }

  Future<bool> verifyIntegrity() async {
    final result = await customSelect('PRAGMA integrity_check').get();
    return result.length == 1 && result.single.data.values.single == 'ok';
  }

  /// VACUUM INTO makes a consistent snapshot, including committed WAL content.
  /// The destination must be a new file, never a user-selected existing file.
  Future<void> backupTo(File destination) async {
    if (await destination.exists()) {
      throw StateError('Backup destination already exists');
    }
    await destination.parent.create(recursive: true);
    final escaped = destination.path.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
  }
}
