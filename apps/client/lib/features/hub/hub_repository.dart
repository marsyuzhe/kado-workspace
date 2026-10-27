import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';

class HubRepository {
  HubRepository(this.store);
  final RecordStore store;
  Selectable<QueryRow> _favoritesQuery() => store.db.customSelect(
    "SELECT * FROM local_records WHERE kind='favorite' AND deleted_at IS NULL AND (COALESCE(json_extract(data,'\$.action.type'),'')!='url' OR json_extract(data,'\$.webDataVersion') IS NULL OR json_extract(data,'\$.favorite')=1 OR json_extract(data,'\$.pinned')=1) ORDER BY COALESCE(json_extract(data,'\$.pinned'),0) DESC,COALESCE(json_extract(data,'\$.order'),0),created_at,id LIMIT 10000",
    readsFrom: {store.db.localRecords},
  );
  List<ToolRecord> _favorites(List<QueryRow> rows) => sortFavorites(
    rows
        .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
        .toList(),
  );
  Stream<List<ToolRecord>> watchFavorites() =>
      _favoritesQuery().watch().map(_favorites);
  List<ToolRecord> sortFavorites(List<ToolRecord> records) => [...records]
    ..sort((a, b) {
      final pins = (b.flag('pinned') ? 1 : 0) - (a.flag('pinned') ? 1 : 0);
      return pins != 0 ? pins : a.number('order').compareTo(b.number('order'));
    });
  Future<List<ToolRecord>> favorites() async =>
      _favorites(await _favoritesQuery().get());
  Future<ToolRecord> addFavorite(
    String title,
    TargetAction action, {
    String category = '常用',
  }) => store.transaction(() async {
    action.validate();
    final existing = await store.find('favorite', 'targetKey', action.key);
    if (existing != null) {
      if (action.type == 'url' && !existing.flag('favorite')) {
        return store.save(
          existing.copyWith(
            data: {...existing.data, 'favorite': true, 'userModified': true},
          ),
        );
      }
      return existing;
    }
    return store.create(
      'favorite',
      title,
      data: {
        'action': action.toJson(),
        'targetKey': action.key,
        'category': category,
        'pinned': false,
        if (action.type == 'url') 'favorite': true,
        'order': (await favorites()).length,
      },
    );
  });

  Future<ToolRecord> updateFavorite(
    ToolRecord record, {
    String? title,
    String? category,
    bool? pinned,
    int? order,
  }) => store.save(
    record.copyWith(
      title: title,
      data: {
        ...record.data,
        'category': ?category,
        'pinned': ?pinned,
        'order': ?order,
        if (record.data['webDataVersion'] != null) 'userModified': true,
      },
    ),
  );
  Future<void> removeFavorite(ToolRecord record) => store.delete(record);
  Future<void> reorder(List<ToolRecord> ordered) async {
    await store.transaction(() async {
      for (var i = 0; i < ordered.length; i++) {
        await updateFavorite(ordered[i], order: i);
      }
    });
  }

  Future<bool> recentEnabled() async =>
      await store.setting('hub.recordRecent') != 'false';
  Future<void> setRecentEnabled(bool value) =>
      store.setSetting('hub.recordRecent', value.toString());
  Stream<List<RecentAction>> watchRecent() =>
      (store.db.select(store.db.recentActions)
            ..orderBy([(t) => OrderingTerm.desc(t.openedAt)])
            ..limit(12))
          .watch();
  Future<void> clearRecent() => store.db.delete(store.db.recentActions).go();
  Future<void> recordOpened(
    String title,
    String module,
    TargetAction action,
  ) async {
    if (!await recentEnabled()) return;
    final table = store.db.recentActions;
    final prior = await (store.db.select(
      table,
    )..where((t) => t.targetKey.equals(action.key))).getSingleOrNull();
    await store.db
        .into(table)
        .insertOnConflictUpdate(
          RecentActionsCompanion.insert(
            id: prior?.id ?? newId(),
            targetKey: action.key,
            title: title,
            moduleId: module,
            action: jsonEncode(action.toJson()),
            openedAt: DateTime.now().toUtc(),
          ),
        );
    await store.db.customStatement(
      'DELETE FROM recent_actions WHERE id NOT IN (SELECT id FROM recent_actions ORDER BY opened_at DESC LIMIT 100)',
    );
  }
}
