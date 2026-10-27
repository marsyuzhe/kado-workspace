import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/database/app_database.dart';
import '../../core/platform/system_actions.dart';
import 'web_catalog.dart';
import 'web_models.dart';
import '../hub/hub_repository.dart';

/// 管理分类与现有URL收藏。所有关系改动在同一写事务内完成，保留旧UUID。
class WebLibraryRepository {
  WebLibraryRepository(this.store, {Future<WebCatalog> Function()? catalog})
    : loadCatalog = catalog ?? WebCatalog.bundled;
  final RecordStore store;
  final Future<WebCatalog> Function() loadCatalog;
  Future<void>? _initializing;
  static const siteLimit = 10000, categoryLimit = 16384;
  Future<void> initialize() => _initializing ??= _initializeSafely();
  Future<void> _initializeSafely() async {
    try {
      await _initialize();
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    final catalog = await loadCatalog();
    await store.transaction(() async {
      // 索引只覆盖实际的分类/排序和URL去重查询，不改变通用表结构版本。
      await store.db.customStatement(
        "CREATE INDEX IF NOT EXISTS web_categories_parent ON local_records(json_extract(data,'\$.parentId'),json_extract(data,'\$.sortOrder')) WHERE kind='website_category' AND deleted_at IS NULL",
      );
      await store.db.customStatement(
        "CREATE INDEX IF NOT EXISTS web_sites_category_order ON local_records(json_extract(data,'\$.categoryId'),json_extract(data,'\$.pinned') DESC,json_extract(data,'\$.order')) WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url'",
      );
      await store.db.customStatement(
        "CREATE INDEX IF NOT EXISTS web_sites_url ON local_records(json_extract(data,'\$.normalizedUrl')) WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url'",
      );
      if (await store.setting('webLibrary.dataVersion') == null) {
        for (final row in catalog.categories) {
          if (!await _identityExists(row['id'] as String)) {
            await store.createWithId(
              row['id'] as String,
              'website_category',
              row['name'] as String,
              body: row['description'] as String? ?? '',
              data: {...row, 'payloadVersion': 1, 'syncAllowed': false},
            );
          }
        }
        await _adoptUnlinkedFavorites();
        // 只首次自动添加精选推荐。后续启动及升级不重放用户删掉的种子。
        final current = await _rawSites();
        for (final row in catalog.sites.where((s) => s['featured'] == true)) {
          final id = row['id'] as String,
              url = normalizeWebsiteUrl(row['url'] as String);
          if (await _identityExists(id) ||
              current.any((s) => s.record.text('normalizedUrl') == url)) {
            continue;
          }
          final saved = await store.createWithId(
            id,
            'favorite',
            row['title'] as String,
            body: row['description'] as String,
            data: websiteRecordData(
              WebsiteInput(
                row['title'] as String,
                url,
                categoryId: row['categoryId'] as String,
                tags: (row['tags'] as List).cast<String>(),
              ),
              url,
              categoryName:
                  catalog.categories.firstWhere(
                        (c) => c['id'] == row['categoryId'],
                      )['name']
                      as String,
              order: current.length,
              extra: {
                'source': 'catalog-v${catalog.version}',
                'sourceType': 'RECOMMENDED',
                'isSeeded': true,
                'catalogId': id,
                'catalogVersion': catalog.version,
                'verifiedAt': row['verifiedAt'],
                'verificationStatus': row['verificationStatus'],
              },
            ),
          );
          current.add(WebsiteBookmark(saved));
        }
        await store.setSetting('webLibrary.dataVersion', '1');
        await store.setSetting(
          'webLibrary.catalogVersion',
          '${catalog.version}',
        );
      } else {
        await _adoptUnlinkedFavorites();
      }
    });
  }

  Future<void> _adoptUnlinkedFavorites() async {
    final categories = await _rawCategories();
    for (final site in await _unlinkedSites()) {
      final row = site.record;
      if (row.text('categoryId').isNotEmpty) continue;
      final oldName = row.text('category', '未分类').trim();
      var category = categories
          .where((c) => c.name == oldName && c.parentId.isEmpty)
          .firstOrNull;
      if (category == null && oldName.isNotEmpty && oldName != '未分类') {
        final id = stableWebId('legacy-category', oldName);
        final existing = await (store.db.select(
          store.db.localRecords,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existing != null) {
          if (existing.kind != 'website_category') {
            throw const ToolFailure('旧分类UUID与其他实体冲突，未改动原收藏。');
          }
          // 删除过的分类不能被旧入口复活；保留原分类文字并暂归未分类。
          if (existing.deletedAt == null) {
            category = WebsiteCategory(ToolRecord.fromRow(existing));
          }
        } else {
          final added = await store.createWithId(
            id,
            'website_category',
            oldName,
            data: {
              'payloadVersion': 1,
              'parentId': '',
              'iconKey': 'folder',
              'sortOrder': categories.length,
              'isSystemPreset': false,
              'isHidden': false,
              'color': '#8196BE',
              'syncAllowed': false,
            },
          );
          category = WebsiteCategory(added);
          categories.add(category);
        }
      }
      String normalized;
      try {
        normalized = normalizeWebsiteUrl(site.url);
      } on ToolFailure {
        normalized = '';
      }
      final recent =
          await (store.db.select(store.db.recentActions)
                ..where((t) => t.targetKey.equals(row.text('targetKey'))))
              .getSingleOrNull();
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'webDataVersion': 1,
            'categoryId': category?.id ?? uncategorizedId,
            'legacyCategoryName': oldName,
            'favorite': row.data.containsKey('favorite')
                ? row.flag('favorite')
                : true,
            'category': category?.name ?? oldName,
            'normalizedUrl': normalized,
            'domain': Uri.tryParse(normalized)?.host ?? '',
            'sourceType': row.text('source').startsWith('import')
                ? 'IMPORTED'
                : 'USER_CONFIRMED',
            'isSeeded': false,
            'visitCount': recent == null ? 0 : 1,
            'lastVisitedAt':
                recent?.openedAt.toUtc().toIso8601String() ??
                row.text('lastOpenedAt'),
            'syncAllowed': false,
          },
        ),
      );
    }
  }

  Future<List<WebsiteBookmark>> _unlinkedSites() async => _convert(
    await store.db
        .customSelect(
          "SELECT * FROM local_records WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url' AND (json_extract(data,'\$.categoryId') IS NULL OR json_extract(data,'\$.categoryId')='') LIMIT 10001",
          readsFrom: {store.db.localRecords},
        )
        .get(),
  );
  Future<bool> _identityExists(String id) async =>
      await (store.db.select(
        store.db.localRecords,
      )..where((t) => t.id.equals(id))).getSingleOrNull() !=
      null;
  List<WebsiteCategory> _convertCategories(List<QueryRow> rows) {
    if (rows.length > categoryLimit) {
      throw const ToolFailure('分类超过安全上限，未截断或修改原数据。');
    }
    return rows
        .map(
          (r) => WebsiteCategory(
            ToolRecord.fromRow(store.db.localRecords.map(r.data)),
          ),
        )
        .toList();
  }

  Selectable<QueryRow> _categoriesQuery() => store.db.customSelect(
    "SELECT * FROM local_records WHERE kind='website_category' AND deleted_at IS NULL ORDER BY json_extract(data,'\$.sortOrder'),created_at,id LIMIT 16385",
    readsFrom: {store.db.localRecords},
  );
  Future<List<WebsiteCategory>> _rawCategories() async =>
      _convertCategories(await _categoriesQuery().get());
  Selectable<QueryRow> _siteQuery({
    bool deleted = false,
  }) => store.db.customSelect(
    "SELECT * FROM local_records WHERE kind='favorite' AND deleted_at IS ${deleted ? 'NOT ' : ''}NULL AND json_extract(data,'\$.action.type')='url' ORDER BY COALESCE(json_extract(data,'\$.pinned'),0) DESC,COALESCE(json_extract(data,'\$.order'),0),created_at,id LIMIT 10001",
    readsFrom: {store.db.localRecords},
  );
  List<WebsiteBookmark> _convert(List<QueryRow> rows) {
    if (rows.length > siteLimit) throw const ToolFailure('网站超过10000条，请分期导出管理。');
    return rows
        .map(
          (r) => WebsiteBookmark(
            ToolRecord.fromRow(store.db.localRecords.map(r.data)),
          ),
        )
        .toList();
  }

  Future<List<WebsiteBookmark>> _rawSites() async =>
      _convert(await _siteQuery().get());
  Future<List<WebsiteCategory>> categories() async {
    await initialize();
    return _rawCategories();
  }

  Future<List<WebsiteBookmark>> sites() async {
    await initialize();
    return _rawSites();
  }

  Stream<List<WebsiteCategory>> watchCategories() async* {
    await initialize();
    yield* _categoriesQuery().watch().map(_convertCategories);
  }

  Stream<List<WebsiteBookmark>> watchSites() async* {
    await initialize();
    yield* _siteQuery().watch().map(_convert);
  }

  Stream<List<WebsiteBookmark>> watchTrash() async* {
    await initialize();
    yield* _siteQuery(deleted: true).watch().map(_convert);
  }

  Future<WebsiteCategory> _category(String id) async {
    final row = await store.get(id);
    if (row?.kind != 'website_category') {
      throw const ToolFailure('分类已不存在，请重新选择。');
    }
    return WebsiteCategory(row!);
  }

  Future<ToolRecord> _current(ToolRecord snapshot, String kind) async {
    final row = await store.get(snapshot.id);
    if (row?.kind != kind || row!.revision != snapshot.revision) {
      throw const RecordConflict();
    }
    return row;
  }

  Future<ToolRecord> _currentWebsite(WebsiteBookmark site) async {
    final row = await _current(site.record, 'favorite');
    if ((row.data['action'] as Map?)?['type'] != 'url') {
      throw const ToolFailure('所选记录不是网页收藏。');
    }
    return row;
  }

  /// 仅在系统打开网址成功之后调用；关闭历史记录时不额外保存访问统计。
  Future<void> recordOpened(WebsiteBookmark opened) async {
    final hub = HubRepository(store);
    if (!await hub.recentEnabled()) return;
    await initialize();
    await store.transaction(() async {
      if (!await hub.recentEnabled()) return;
      final row = await store.get(opened.id);
      TargetAction('url', opened.url).validate();
      await hub.recordOpened(
        opened.title,
        'bookmarks',
        TargetAction('url', opened.url),
      );
      if (row?.kind != 'favorite' || WebsiteBookmark(row!).url != opened.url) {
        return;
      }
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'visitCount': row.number('visitCount') + 1,
            'lastVisitedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
    });
  }

  Future<WebsiteCategory> saveCategory(
    WebsiteCategoryInput input, {
    WebsiteCategory? existing,
  }) async {
    input.validate();
    await initialize();
    return store.transaction(() async {
      final all = await _rawCategories();
      if (existing == null && all.length >= categoryLimit) {
        throw const ToolFailure('分类达到16384个安全上限，请先整理空分类。');
      }
      if (all.any(
        (c) =>
            c.id != existing?.id &&
            c.parentId == input.parentId &&
            c.name.toLowerCase() == input.name.trim().toLowerCase(),
      )) {
        throw const ToolFailure('这个上级分类中已有同名分类。');
      }
      if (input.parentId.isNotEmpty) {
        final parent = await _category(input.parentId);
        if (parent.id == existing?.id ||
            parent.parentId.isNotEmpty ||
            all.any((c) => c.parentId == existing?.id)) {
          throw const ToolFailure('分类最多两层，不能形成循环；请先移动子分类。');
        }
      }
      if (existing?.id == uncategorizedId && input.parentId.isNotEmpty) {
        throw const ToolFailure('默认归类入口需保留在顶层。');
      }
      final row = existing == null
          ? null
          : await _current(existing.record, 'website_category');
      final data = {
        ...row?.data ?? {},
        'payloadVersion': 1,
        'parentId': input.parentId,
        'iconKey': input.iconKey,
        'color': input.color.toUpperCase(),
        'sortOrder': input.sortOrder,
        'isHidden': input.isHidden,
        'isSystemPreset': row?.flag('isSystemPreset') ?? false,
        'userModified': true,
        'syncAllowed': false,
      };
      final saved = row == null
          ? await store.create(
              'website_category',
              input.name,
              body: input.description,
              data: data,
            )
          : await store.save(
              row.copyWith(
                title: input.name.trim(),
                body: input.description,
                data: data,
              ),
            );
      if (row != null && row.title != saved.title) {
        await _moveCategorySites(row.id, row.id, saved.title);
      }
      return WebsiteCategory(saved);
    });
  }

  Future<void> reorderCategories(
    List<String> ids, {
    String parentId = '',
  }) async {
    await initialize();
    await store.transaction(() async {
      final current = (await _rawCategories())
          .where((c) => c.parentId == parentId)
          .toList();
      _sameIds(ids, current.map((c) => c.id));
      final byId = {for (final c in current) c.id: c};
      for (var i = 0; i < ids.length; i++) {
        final row = byId[ids[i]]!.record;
        await store.save(
          row.copyWith(
            data: {...row.data, 'sortOrder': i, 'userModified': true},
          ),
        );
      }
    });
  }

  void _sameIds(List<String> requested, Iterable<String> actual) {
    final set = actual.toSet();
    if (requested.length != set.length ||
        requested.toSet().length != requested.length ||
        !requested.toSet().containsAll(set)) {
      throw const ToolFailure('列表已经变化，请刷新后重新排序。');
    }
  }

  Future<void> _moveCategorySites(String from, String to, String name) async {
    await store.db.customUpdate(
      "UPDATE local_records SET data=json_set(data,'\$.categoryId',?,'\$.category',?,'\$.userModified',json('true')),revision=revision+1,updated_at=?,device_id=? WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url' AND json_extract(data,'\$.categoryId')=?",
      variables: [
        Variable(to),
        Variable(name),
        Variable(DateTime.now().toUtc()),
        Variable(await store.deviceId),
        Variable(from),
      ],
      updates: {store.db.localRecords},
    );
  }

  /// 只删除分类本身：子分类保留到顶层，站点明确移入所选分类。
  Future<void> removeCategory(
    WebsiteCategory category, {
    required String moveTo,
    required bool confirmed,
  }) async {
    if (!confirmed || category.id == uncategorizedId || category.id == moveTo) {
      throw const ToolFailure('请选择保留的网站目标分类并确认，默认归类入口不能删除。');
    }
    await initialize();
    await store.transaction(() async {
      final current = await _current(category.record, 'website_category'),
          destination = await _category(moveTo),
          all = await _rawCategories();
      final children = all.where((c) => c.parentId == category.id).toList();
      if (children.any(
        (child) => all.any(
          (c) =>
              c.parentId.isEmpty &&
              c.id != category.id &&
              c.name.toLowerCase() == child.name.toLowerCase(),
        ),
      )) {
        throw const ToolFailure('子分类移至顶层后将同名，请先重命名子分类。');
      }
      for (final child in children) {
        await store.save(
          child.record.copyWith(
            data: {...child.record.data, 'parentId': '', 'userModified': true},
          ),
        );
      }
      await _moveCategorySites(current.id, destination.id, destination.name);
      await store.delete(current);
    });
  }

  Future<WebsiteBookmark> saveWebsite(
    WebsiteInput input, {
    WebsiteBookmark? existing,
  }) async {
    final url = input.validate();
    await initialize();
    return store.transaction(() async {
      final category = await _category(
        input.categoryId.isEmpty ? uncategorizedId : input.categoryId,
      );
      final duplicates = await store.db
          .customSelect(
            "SELECT id FROM local_records WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url' AND json_extract(data,'\$.normalizedUrl')=? LIMIT 2",
            variables: [Variable(url)],
            readsFrom: {store.db.localRecords},
          )
          .get();
      if (duplicates.any((r) => r.read<String>('id') != existing?.id)) {
        throw const ToolFailure('相同网址已经存在，请编辑已有记录；不同查询参数会作为不同网址保留。');
      }
      final row = existing == null ? null : await _currentWebsite(existing);
      final all = await _rawSites();
      if (row == null && all.length >= siteLimit) {
        throw const ToolFailure('网站达到10000条上限。');
      }
      final fields = websiteRecordData(
        input,
        url,
        categoryName: category.name,
        order: row?.number('order') ?? all.length,
        extra: row == null
            ? const {}
            : {
                ...row.data,
                'action': TargetAction('url', url).toJson(),
                'targetKey': TargetAction('url', url).key,
                'normalizedUrl': url,
                'domain': Uri.parse(url).host,
                'categoryId': category.id,
                'category': category.name,
                'tags': input.tags
                    .map((v) => v.trim())
                    .where((v) => v.isNotEmpty)
                    .toSet()
                    .toList(),
                'favorite': input.isFavorite,
                'pinned': input.isPinned,
                'alternateUrl': input.alternateUrl.isEmpty
                    ? ''
                    : normalizeWebsiteUrl(input.alternateUrl),
                'payloadVersion': 2,
                'webDataVersion': 1,
                'userModified': true,
              },
      );
      return WebsiteBookmark(
        row == null
            ? await store.create(
                'favorite',
                input.title,
                body: input.description,
                data: fields,
              )
            : await store.save(
                row.copyWith(
                  title: input.title.trim(),
                  body: input.description,
                  data: fields,
                ),
              ),
      );
    });
  }

  Future<void> updateWebsites(
    List<WebsiteBookmark> selection, {
    String? categoryId,
    List<String>? addTags,
    bool? favorite,
    bool? pinned,
  }) async {
    if (selection.isEmpty ||
        selection.length > siteLimit ||
        selection.map((s) => s.id).toSet().length != selection.length ||
        addTags != null &&
            (addTags.length > 30 || addTags.any((v) => v.length > 80))) {
      throw const ToolFailure('批量选择或标签无效。');
    }
    await initialize();
    await store.transaction(() async {
      final category = categoryId == null ? null : await _category(categoryId);
      for (final site in selection) {
        final row = await _currentWebsite(site),
            tags = {...row.strings('tags'), ...addTags ?? []}.toList();
        if (tags.length > 30) throw const ToolFailure('合并后标签超过30个，整批尚未提交。');
        await store.save(
          row.copyWith(
            data: {
              ...row.data,
              if (category != null) 'categoryId': category.id,
              if (category != null) 'category': category.name,
              'favorite': ?favorite,
              'pinned': ?pinned,
              'tags': tags,
              'userModified': true,
            },
          ),
        );
      }
    });
  }

  Future<void> reorderWebsites(
    List<String> ids, {
    String categoryId = '',
    bool pinnedOnly = false,
  }) async {
    await initialize();
    await store.transaction(() async {
      final rows = (await _rawSites())
          .where(
            (s) =>
                (categoryId.isEmpty || s.categoryId == categoryId) &&
                (!pinnedOnly || s.isPinned),
          )
          .toList();
      _sameIds(ids, rows.map((r) => r.id));
      final byId = {for (final site in rows) site.id: site};
      for (var i = 0; i < ids.length; i++) {
        final row = byId[ids[i]]!.record;
        await store.save(
          row.copyWith(data: {...row.data, 'order': i, 'userModified': true}),
        );
      }
    });
  }

  /// 网页删除保留回收站内容；旧通用删除仍保持原有的数据清除语义。
  Future<void> removeWebsites(
    List<WebsiteBookmark> selection, {
    required bool confirmed,
  }) async {
    if (!confirmed ||
        selection.isEmpty ||
        selection.map((s) => s.id).toSet().length != selection.length) {
      throw const ToolFailure('请明确选择网站并确认移入回收站。');
    }
    await initialize();
    await store.transaction(() async {
      for (final site in selection) {
        final row = await _currentWebsite(site);
        final count =
            await (store.db.update(store.db.localRecords)..where(
                  (t) =>
                      t.id.equals(row.id) &
                      t.revision.equals(row.revision) &
                      t.deletedAt.isNull(),
                ))
                .write(
                  LocalRecordsCompanion(
                    deletedAt: Value(DateTime.now().toUtc()),
                    updatedAt: Value(DateTime.now().toUtc()),
                    revision: Value(row.revision + 1),
                    deviceId: Value(await store.deviceId),
                  ),
                );
        if (count != 1) throw const RecordConflict();
      }
    });
  }

  Future<WebsiteBookmark> restoreWebsite(WebsiteBookmark deleted) async {
    await initialize();
    return store.transaction(() async {
      final raw = await (store.db.select(
        store.db.localRecords,
      )..where((t) => t.id.equals(deleted.id))).getSingleOrNull();
      if (raw == null ||
          raw.kind != 'favorite' ||
          raw.deletedAt == null ||
          raw.revision != deleted.record.revision) {
        throw const RecordConflict();
      }
      final row = ToolRecord.fromRow(raw),
          site = WebsiteBookmark(row),
          url = normalizeWebsiteUrl(site.url),
          duplicate = await store.find('favorite', 'normalizedUrl', url);
      if (duplicate != null) throw const ToolFailure('已有相同网址，未覆盖当前记录。');
      final category =
          (await store.get(site.categoryId))?.kind == 'website_category'
          ? await _category(site.categoryId)
          : await _category(uncategorizedId);
      await (store.db.update(store.db.localRecords)..where(
            (t) => t.id.equals(row.id) & t.revision.equals(row.revision),
          ))
          .write(
            LocalRecordsCompanion(
              deletedAt: const Value(null),
              updatedAt: Value(DateTime.now().toUtc()),
              revision: Value(row.revision + 1),
              deviceId: Value(await store.deviceId),
              data: Value(
                jsonEncode({
                  ...row.data,
                  'categoryId': category.id,
                  'category': category.name,
                  'userModified': true,
                  'restoredAt': DateTime.now().toUtc().toIso8601String(),
                }),
              ),
            ),
          );
      return WebsiteBookmark((await store.get(row.id))!);
    });
  }

  Future<({int added, int skipped})> mergeCatalog(
    WebCatalog catalog,
    List<String> ids, {
    required bool confirmed,
  }) async {
    if (!confirmed ||
        ids.isEmpty ||
        ids.toSet().length != ids.length ||
        !ids.every((id) => catalog.sites.any((s) => s['id'] == id))) {
      throw const ToolFailure('请先选择并确认推荐目录条目。');
    }
    await initialize();
    return store.transaction(() async {
      final existing = await _rawSites(),
          urls = existing.map((s) => s.record.text('normalizedUrl')).toSet();
      var added = 0, skipped = 0;
      for (final entry in catalog.sites.where((s) => ids.contains(s['id']))) {
        final id = entry['id'] as String,
            url = normalizeWebsiteUrl(entry['url'] as String);
        if (await _identityExists(id) || urls.contains(url)) {
          skipped++;
          continue;
        }
        if (existing.length + added >= siteLimit) {
          throw const ToolFailure('网站达到10000条上限，整批未提交。');
        }
        var category = entry['categoryId'] as String;
        if (!await _identityExists(category)) {
          final c = catalog.categories.firstWhere((c) => c['id'] == category);
          await store.createWithId(
            category,
            'website_category',
            c['name'] as String,
            body: c['description'] as String? ?? '',
            data: {...c, 'syncAllowed': false},
          );
        }
        final c = await store.get(category);
        if (c?.kind != 'website_category') category = uncategorizedId;
        await store.createWithId(
          id,
          'favorite',
          entry['title'] as String,
          body: entry['description'] as String,
          data: websiteRecordData(
            WebsiteInput(
              entry['title'] as String,
              url,
              categoryId: category,
              tags: (entry['tags'] as List).cast<String>(),
            ),
            url,
            categoryName: (await _category(category)).name,
            order: existing.length + added,
            extra: {
              'source': 'catalog-v${catalog.version}',
              'sourceType': 'RECOMMENDED',
              'isSeeded': true,
              'catalogId': id,
              'catalogVersion': catalog.version,
              'verifiedAt': entry['verifiedAt'],
              'verificationStatus': entry['verificationStatus'],
            },
          ),
        );
        urls.add(url);
        added++;
      }
      await store.setSetting('webLibrary.catalogVersion', '${catalog.version}');
      return (added: added, skipped: skipped);
    });
  }
}
