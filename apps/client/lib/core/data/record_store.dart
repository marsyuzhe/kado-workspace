import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import 'tool_record.dart';
import '../storage/data_mutation_gate.dart';

/// Shared persistence boundary. Feature repositories expose only their own kinds.
class RecordStore {
  RecordStore(this.db);
  final AppDatabase db;
  Future<String>? _deviceFuture;

  /// Acquire the shared write gate before SQLite's transaction lock. All feature
  /// writes use this order so timer reminders and foreground writes cannot deadlock.
  Future<T> transaction<T>(Future<T> Function() action) =>
      DataMutationGate.shared.run(() => db.transaction(action));
  Future<String?> setting(String key) async => (await (db.select(
    db.appSettings,
  )..where((t) => t.key.equals(key))).getSingleOrNull())?.value;
  Future<void> setSetting(String key, String value) => db
      .into(db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: key, value: value),
      );
  Future<String> get deviceId => _deviceFuture ??= _resolveDevice();
  Future<String> _resolveDevice() async {
    final existing = await setting('deviceId');
    final device = existing ?? newId();
    if (existing == null) await setSetting('deviceId', device);
    return device;
  }

  Future<ToolRecord?> get(String id) async {
    final r = await (db.select(
      db.localRecords,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    return r == null ? null : ToolRecord.fromRow(r);
  }

  Stream<ToolRecord?> watchOne(String id) =>
      (db.select(db.localRecords)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .watchSingleOrNull()
          .map((row) => row == null ? null : ToolRecord.fromRow(row));

  SimpleSelectStatement<$LocalRecordsTable, LocalRecord> _query(
    String kind,
    int limit,
  ) {
    return db.select(db.localRecords)
      ..where((t) => t.kind.equals(kind) & t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm(
          expression: const CustomExpression<int>('rowid'),
          mode: OrderingMode.desc,
        ),
      ])
      ..limit(limit.clamp(1, 10000));
  }

  Future<List<ToolRecord>> list(String kind, {int limit = 500}) async =>
      (await _query(kind, limit).get()).map(ToolRecord.fromRow).toList();
  Stream<List<ToolRecord>> watch(String kind, {int limit = 500}) => _query(
    kind,
    limit,
  ).watch().map((rows) => rows.map(ToolRecord.fromRow).toList());
  Future<ToolRecord?> find(String kind, String field, String value) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM local_records WHERE kind=? AND deleted_at IS NULL AND json_extract(data,?)=? LIMIT 1',
          variables: [Variable(kind), Variable('\$.$field'), Variable(value)],
          readsFrom: {db.localRecords},
        )
        .get();
    return rows.isEmpty
        ? null
        : ToolRecord.fromRow(db.localRecords.map(rows.first.data));
  }

  Future<ToolRecord> create(
    String kind,
    String title, {
    String body = '',
    Map<String, dynamic> data = const {},
  }) => createWithId(newId(), kind, title, body: body, data: data);

  /// 用于种子与显式导入的稳定UUID。重复ID由主键拒绝，绝不覆盖旧记录。
  Future<ToolRecord> createWithId(
    String id,
    String kind,
    String title, {
    String body = '',
    Map<String, dynamic> data = const {},
    DateTime? createdAt,
  }) => DataMutationGate.shared.run(() async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(id)) {
      throw const ToolFailure('记录UUID无效。');
    }
    final now = DateTime.now().toUtc();
    final device = await deviceId;
    final record = ToolRecord(
      id: id.toLowerCase(),
      kind: kind,
      title: title.trim(),
      body: body,
      data: data,
      createdAt: createdAt?.toUtc() ?? now,
      updatedAt: now,
      revision: 1,
      deviceId: device,
    );
    await db
        .into(db.localRecords)
        .insert(
          LocalRecordsCompanion.insert(
            id: record.id,
            kind: kind,
            title: record.title,
            body: Value(body),
            data: Value(jsonEncode(data)),
            createdAt: record.createdAt,
            updatedAt: now,
            revision: 1,
            deviceId: device,
          ),
        );
    return (await get(record.id))!;
  });

  Future<ToolRecord> save(ToolRecord record) =>
      DataMutationGate.shared.run(() async {
        final count =
            await (db.update(db.localRecords)..where(
                  (t) =>
                      t.id.equals(record.id) &
                      t.revision.equals(record.revision) &
                      t.deletedAt.isNull(),
                ))
                .write(
                  LocalRecordsCompanion(
                    title: Value(record.title),
                    body: Value(record.body),
                    data: Value(jsonEncode(record.data)),
                    updatedAt: Value(DateTime.now().toUtc()),
                    revision: Value(record.revision + 1),
                    deviceId: Value(await deviceId),
                  ),
                );
        if (count != 1) throw const RecordConflict();
        return (await get(record.id))!;
      });

  Future<void> delete(ToolRecord record) =>
      DataMutationGate.shared.run(() async {
        final count =
            await (db.update(db.localRecords)..where(
                  (t) =>
                      t.id.equals(record.id) &
                      t.revision.equals(record.revision) &
                      t.deletedAt.isNull(),
                ))
                .write(
                  LocalRecordsCompanion(
                    title: const Value(''),
                    body: const Value(''),
                    data: const Value('{}'),
                    deletedAt: Value(DateTime.now().toUtc()),
                    updatedAt: Value(DateTime.now().toUtc()),
                    revision: Value(record.revision + 1),
                  ),
                );
        if (count != 1) throw const RecordConflict();
      });

  Future<List<ToolRecord>> search(
    String query, {
    List<String> kinds = const [],
    int limit = 200,
  }) async {
    query = query.trim();
    if (query.isEmpty) return [];
    final filters = kinds.isEmpty
        ? ''
        : ' AND r.kind IN (${List.filled(kinds.length, '?').join(',')})';
    final List<Variable> args = [];
    String sql;
    if (query.runes.length >= 3) {
      sql =
          'SELECT r.* FROM local_records r JOIN record_search f ON f.record_id=r.id WHERE record_search MATCH ? AND r.deleted_at IS NULL$filters ORDER BY r.updated_at DESC LIMIT ?';
      args.add(Variable('"${query.replaceAll('"', '""')}"'));
    } else {
      sql =
          "SELECT r.* FROM local_records r WHERE r.deleted_at IS NULL AND instr(lower(r.title||char(10)||r.body),lower(?))>0$filters ORDER BY r.updated_at DESC LIMIT ?";
      args.add(Variable(query));
    }
    args.addAll(kinds.map(Variable.new));
    args.add(Variable(limit.clamp(1, 1000)));
    return (await db
            .customSelect(sql, variables: args, readsFrom: {db.localRecords})
            .get())
        .map((r) => ToolRecord.fromRow(db.localRecords.map(r.data)))
        .toList();
  }
}
