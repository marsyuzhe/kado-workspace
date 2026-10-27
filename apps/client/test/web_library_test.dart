import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/features/hub/hub_repository.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_catalog.dart';
import 'package:links_toolbox/features/web_library/web_repository.dart';
import 'package:links_toolbox/features/web_library/web_search_service.dart';

WebCatalog fixtureCatalog({int version = 1, bool extra = false}) {
  final categories = [
    for (final key in ['uncategorized', 'ai'])
      {
        'id': stableWebId('category', key),
        'name': key == 'ai' ? 'AI 工具' : '未分类',
        'description': '测试分类',
        'iconKey': 'folder',
        'color': '#8196BE',
        'sortOrder': key == 'ai' ? 1 : 0,
        'parentId': '',
        'isSystemPreset': true,
        'isHidden': false,
      },
  ];
  final sites = [
    for (final title in [
      'ChatGPT',
      'TRAE',
      'ComfyUI',
      if (extra) 'New version only',
    ])
      {
        'id': stableWebId('site', 'https://example.com/$title'),
        'title': title,
        'url': 'https://example.com/${Uri.encodeComponent(title)}',
        'categoryId': stableWebId('category', 'ai'),
        'description': '自有测试推荐，不表示真实访问',
        'tags': ['QA'],
        'sourceType': 'RECOMMENDED',
        'featured': true,
        'verifiedAt': '',
        'verificationStatus': 'TEST_FIXTURE',
      },
  ];
  return WebCatalog.parse(
    jsonEncode({
      'schemaVersion': 1,
      'catalogVersion': version,
      'categories': categories,
      'sites': sites,
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late WebLibraryRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kado-web-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test('URL normalization preserves query semantics, escaped path and fragment; unsafe schemes are refused', () {
    expect(normalizeWebsiteUrl('EXAMPLE.com:443'), 'https://example.com/');
    expect(
      normalizeWebsiteUrl('https://EXAMPLE.com:443/A%20b?q=a%2Fb&q=c#Section'),
      'https://example.com/A%20b?q=a%2Fb&q=c#Section',
    );
    expect(normalizeWebsiteUrl('http://example.com:80'), 'http://example.com/');
    expect(normalizeWebsiteUrl('localhost:8080/a'), 'https://localhost:8080/a');
    for (final url in [
      'javascript:alert(1)',
      'data:text/plain,hello',
      'file:///c:/private',
      'https://user:pass@example.com/',
      'https://example.com/a\nb',
    ]) {
      expect(() => normalizeWebsiteUrl(url), throwsA(isA<ToolFailure>()));
    }
  });
  test('legacy UUID/body/pin/order/recent and unrelated records survive transactional migration; seeds do not resurrect', () async {
    final hub = HubRepository(store),
        old = await hub.addFavorite(
          '旧收藏',
          const TargetAction('url', 'https://example.org/docs'),
          category: '旧科技',
        );
    final changed = await store.save(
      old.copyWith(
        body: '旧笔记',
        data: {
          ...old.data,
          'pinned': true,
          'order': 7,
          'tags': ['保留'],
        },
      ),
    );
    await hub.recordOpened(
      changed.title,
      'hub',
      const TargetAction('url', 'https://example.org/docs'),
    );
    final application = await hub.addFavorite(
      '非网页',
      const TargetAction('application', r'C:\qa.exe'),
    );
    final note = await store.create('note', '原笔记', body: '不改写');
    await store.setSetting('qa.credentialRef', 'existing-reference-only');
    await repo.initialize();
    final legacy = (await repo.sites()).singleWhere((s) => s.id == old.id);
    expect(legacy.description, '旧笔记');
    expect(legacy.isPinned, true);
    expect(legacy.sortOrder, 7);
    expect(legacy.tags, ['保留']);
    expect(legacy.visitCount, 1);
    expect(legacy.sourceType, 'USER_CONFIRMED');
    expect(
      (await repo.categories())
          .singleWhere((c) => c.id == legacy.categoryId)
          .name,
      '旧科技',
    );
    expect((await store.get(application.id))!.revision, application.revision);
    expect((await store.get(note.id))!.body, '不改写');
    expect(await store.setting('qa.credentialRef'), 'existing-reference-only');
    final seeds = (await repo.sites()).where((s) => s.isSeeded).toList();
    expect(seeds.length, 3);
    expect(
      seeds.every((s) => !s.isFavorite && !s.isPinned && s.visitCount == 0),
      true,
    );
    await repo.removeWebsites([seeds.first], confirmed: true);
    repo = WebLibraryRepository(
      store,
      catalog: () async => fixtureCatalog(version: 2, extra: true),
    );
    await repo.initialize();
    expect((await repo.sites()).length, 3);
    expect(
      (await repo.sites()).any((s) => s.title == 'New version only'),
      false,
    );
    expect(await store.setting('webLibrary.catalogVersion'), '1');
  });
  test('category hierarchy avoids cycles and third levels; delete moves sites while retaining children and ordering', () async {
    final root = await repo.saveCategory(
      const WebsiteCategoryInput('我的 AI 工具', iconKey: 'spark', sortOrder: 2),
    );
    final child = await repo.saveCategory(
      WebsiteCategoryInput('本地工具', parentId: root.id),
    );
    await expectLater(
      repo.saveCategory(WebsiteCategoryInput('第三层', parentId: child.id)),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      repo.saveCategory(
        WebsiteCategoryInput('循环', parentId: child.id),
        existing: root,
      ),
      throwsA(isA<ToolFailure>()),
    );
    final selected = (await repo.sites())
        .where((s) => ['ChatGPT', 'TRAE', 'ComfyUI'].contains(s.title))
        .toList();
    await repo.updateWebsites(selected, categoryId: root.id);
    expect(
      (await repo.sites()).where((s) => s.categoryId == root.id).length,
      3,
    );
    final renamed = await repo.saveCategory(
      const WebsiteCategoryInput('自己的 AI', isHidden: true, sortOrder: 2),
      existing: root,
    );
    expect(renamed.isHidden, true);
    expect(
      (await repo.sites()).every((s) => s.record.text('category') == '自己的 AI'),
      true,
    );
    final roots = (await repo.categories())
        .where((c) => c.parentId.isEmpty)
        .toList();
    await repo.reorderCategories(roots.reversed.map((c) => c.id).toList());
    final current = (await repo.categories()).singleWhere(
      (c) => c.id == root.id,
    );
    await expectLater(
      repo.removeCategory(current, moveTo: uncategorizedId, confirmed: false),
      throwsA(isA<ToolFailure>()),
    );
    await repo.removeCategory(
      current,
      moveTo: uncategorizedId,
      confirmed: true,
    );
    expect(
      (await repo.sites()).every((s) => s.categoryId == uncategorizedId),
      true,
    );
    expect(
      (await repo.categories()).singleWhere((c) => c.id == child.id).parentId,
      '',
    );
    final uncategorized = (await repo.categories()).singleWhere(
      (c) => c.id == uncategorizedId,
    );
    await expectLater(
      repo.removeCategory(uncategorized, moveTo: child.id, confirmed: true),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('real website CRUD rejects duplicates and stale batches, preserves query-specific links and source identity', () async {
    final site = await repo.saveWebsite(
      const WebsiteInput(
        '网站',
        'https://EXAMPLE.org:443/?mode=one',
        tags: ['one'],
        isFavorite: true,
        isPinned: true,
      ),
    );
    await expectLater(
      repo.saveWebsite(
        const WebsiteInput('重复', 'https://example.org/?mode=one'),
      ),
      throwsA(isA<ToolFailure>()),
    );
    final second = await repo.saveWebsite(
      const WebsiteInput('另一用途', 'https://example.org/?mode=two'),
    );
    final edited = await repo.saveWebsite(
      const WebsiteInput(
        '修改名称',
        'example.org/?mode=one',
        description: '保存说明',
        tags: ['two'],
        isFavorite: true,
      ),
      existing: site,
    );
    expect(edited.id, site.id);
    expect(edited.description, '保存说明');
    expect(edited.tags, ['two']);
    await expectLater(
      repo.updateWebsites([second, site], favorite: true),
      throwsA(isA<RecordConflict>()),
    );
    expect((await store.get(second.id))!.flag('favorite'), false);
    final app = await HubRepository(store)
        .addFavorite('App', const TargetAction('application', r'C:\qa.exe'));
    await expectLater(
      repo.removeWebsites([WebsiteBookmark(app)], confirmed: true),
      throwsA(isA<ToolFailure>()),
    );
    expect(await store.get(app.id), isNotNull);
  });
  test('manual ordering remains stable across visits, history opt out is respected, data reopens without duplicate seeds', () async {
    var sites = await repo.sites();
    await repo.reorderWebsites(sites.reversed.map((s) => s.id).toList());
    sites = await repo.sites();
    final ids = sites.map((s) => s.id).toList();
    await repo.recordOpened(sites.last);
    expect((await repo.sites()).map((s) => s.id).toList(), ids);
    expect((await store.get(sites.last.id))!.number('visitCount'), 1);
    await store.setSetting('hub.recordRecent', 'false');
    await repo.recordOpened(sites.last);
    expect((await store.get(sites.last.id))!.number('visitCount'), 1);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    expect((await repo.sites()).map((s) => s.id).toList(), ids);
    expect(await db.verifyIntegrity(), true);
  });
  test('soft-deleted websites can restore with category fallback but cannot overwrite a duplicate URL', () async {
    final category = await repo.saveCategory(
      const WebsiteCategoryInput('临时分类'),
    );
    final site = await repo.saveWebsite(
      WebsiteInput(
        '回收测试',
        'https://example.org/trash',
        categoryId: category.id,
      ),
    );
    await repo.removeWebsites([site], confirmed: true);
    var trash = await repo.watchTrash().first;
    expect(trash.single.title, '回收测试');
    await repo.removeCategory(
      category,
      moveTo: uncategorizedId,
      confirmed: true,
    );
    var restored = await repo.restoreWebsite(trash.single);
    expect(restored.id, site.id);
    expect(restored.categoryId, uncategorizedId);
    await repo.removeWebsites([restored], confirmed: true);
    trash = await repo.watchTrash().first;
    await repo.saveWebsite(
      const WebsiteInput('新记录', 'https://example.org/trash'),
    );
    await expectLater(
      repo.restoreWebsite(trash.single),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('local search is read-only, paginated, field-complete and respects hidden/personal scopes', () async {
    final old = await HubRepository(store).addFavorite(
      'LegacyUnique',
      const TargetAction('url', 'https://legacy.example.org/'),
      category: '保留原分类',
    );
    final search = WebLibrarySearchService(store);
    expect((await search.search('LegacyUnique')).items.single.id, old.id);
    expect(await store.list('website_category'), isEmpty);
    expect(await store.setting('webLibrary.dataVersion'), isNull);
    await repo.initialize();
    expect((await search.search('QA', view: 'personal')).total, 0);
    final first = (await repo.sites()).firstWhere((s) => s.isSeeded);
    await repo.updateWebsites([first], favorite: true);
    expect((await search.search('QA', view: 'personal')).total, 1);
    expect(
      (await search.search('example.com', limit: 1, offset: 1)).hasMore,
      true,
    );
    expect((await search.search('AI 工具')).total, 3);
    expect((await search.search("' OR 1=1--")).total, 0);
    final category = (await repo.categories()).singleWhere(
      (c) => c.name == 'AI 工具',
    );
    await repo.saveCategory(
      const WebsiteCategoryInput('AI 工具', isHidden: true),
      existing: category,
    );
    expect((await search.search('QA')).total, 0);
    expect((await search.search('QA', includeHidden: true)).total, 3);
  });
  test('URL favorites created by legacy Hub after initialization are adopted once without reseeding', () async {
    await repo.initialize();
    final old = await HubRepository(store).addFavorite(
      '后添加的旧入口',
      const TargetAction('url', 'https://after.example.org/'),
      category: '后添加分类',
    );
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    await repo.initialize();
    final site = (await repo.sites()).singleWhere((s) => s.id == old.id);
    expect(site.categoryId, stableWebId('legacy-category', '后添加分类'));
    expect((await repo.sites()).length, 4);
    final adoptedRevision = site.record.revision;
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    await repo.initialize();
    expect((await store.get(old.id))!.revision, adoptedRevision);
  });
  test('legacy post-delete category text is preserved without reviving a deleted category', () async {
    final hub = HubRepository(store);
    await hub.addFavorite(
      '原站点',
      const TargetAction('url', 'https://one.example.org/'),
      category: '后续删除分类',
    );
    await repo.initialize();
    final category = (await repo.categories()).singleWhere(
      (c) => c.name == '后续删除分类',
    );
    await repo.removeCategory(
      category,
      moveTo: uncategorizedId,
      confirmed: true,
    );
    final newSite = await hub.addFavorite(
      '后添加站点',
      const TargetAction('url', 'https://two.example.org/'),
      category: '后续删除分类',
    );
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    await repo.initialize();
    final adopted = (await repo.sites()).singleWhere((s) => s.id == newSite.id);
    expect(adopted.categoryId, uncategorizedId);
    expect(adopted.record.text('legacyCategoryName'), '后续删除分类');
    expect((await repo.categories()).any((c) => c.id == category.id), false);
    expect(
      (await WebLibrarySearchService(store).search('后续删除分类')).items
          .map((s) => s.id),
      contains(newSite.id),
    );
  });
  test('categories and websites above the generic 500-row default are not silently truncated', () async {
    await repo.initialize();
    await store.transaction(() async {
      for (var i = 0; i < 501; i++) {
        final id = stableWebId('large-category', '$i');
        await store.createWithId(
          id,
          'website_category',
          '分类$i',
          data: {'parentId': '', 'sortOrder': i},
        );
        final url = 'https://many.example.org/$i';
        await store.create(
          'favorite',
          '网站$i',
          data: {
            'categoryId': id,
            'action': {'type': 'url', 'target': url},
            'normalizedUrl': url,
            'order': i,
          },
        );
      }
    });
    expect((await repo.categories()).length, 503);
    expect((await repo.sites()).length, 504);
    expect(
      (await WebLibrarySearchService(
        store,
      ).search('many.example.org', limit: 100)).total,
      501,
    );
  });
  test('bundled catalogue is versioned, database driven and recommended rather than claimed personal usage', () async {
    final catalog = await WebCatalog.bundled();
    expect(catalog.categories.length, 16);
    expect(catalog.sites.length, 111);
    expect(catalog.sites.every((s) => s['sourceType'] == 'RECOMMENDED'), true);
    expect(catalog.sites.where((s) => s['featured'] == true).length, 20);
    final bundled = WebLibraryRepository(store);
    await bundled.initialize();
    expect((await bundled.sites()).length, 20);
    expect(
      (await bundled.sites()).every(
        (s) => !s.isPinned && !s.isFavorite && s.visitCount == 0,
      ),
      true,
    );
  });
  test('recommended websites do not become Hub personal favorites until explicitly starred', () async {
    await repo.initialize();
    final hub = HubRepository(store);
    expect(await hub.favorites(), isEmpty);
    final site = (await repo.sites()).first;
    await hub.addFavorite(site.title, TargetAction('url', site.url));
    expect((await hub.favorites()).single.id, site.id);
    expect((await repo.sites()).length, 3);
    await repo.updateWebsites([
      WebsiteBookmark((await store.get(site.id))!),
    ], favorite: false);
    expect(await hub.favorites(), isEmpty);
    final old = await hub.addFavorite(
      '旧Hub网址',
      const TargetAction('url', 'https://example.org/hub-direct'),
    );
    final fresh = WebLibraryRepository(
      store,
      catalog: () async => fixtureCatalog(),
    );
    await fresh.initialize();
    expect((await hub.favorites()).single.id, old.id);
  });
  test(
    'catalogue confirmation skips deleted IDs and preserves modified fields',
    () async {
      await repo.initialize();
      final before = await repo.sites();
      await repo.removeWebsites([before.first], confirmed: true);
      final kept = before[1];
      await repo.saveWebsite(
        WebsiteInput('我的修改', kept.url, categoryId: kept.categoryId),
        existing: kept,
      );
      final catalog = fixtureCatalog(version: 2, extra: true),
          result = await repo.mergeCatalog(
            catalog,
            catalog.sites.map((s) => s['id'] as String).toList(),
            confirmed: true,
          );
      expect(result.added, 1);
      expect(result.skipped, 3);
      expect((await store.get(kept.id))!.title, '我的修改');
      expect(await store.get(before.first.id), isNull);
      final added = (await repo.sites()).firstWhere(
        (s) => s.title == 'New version only',
      );
      expect(added.sourceType, 'RECOMMENDED');
      expect(added.isFavorite, isFalse);
    },
  );
  test('category moves and trash restores protect recommended rows as user changes', () async {
    await repo.initialize();
    final site = (await repo.sites()).first,
        category = (await repo.categories()).firstWhere(
          (c) => c.id == site.categoryId,
        );
    await repo.removeCategory(
      category,
      moveTo: uncategorizedId,
      confirmed: true,
    );
    var moved = WebsiteBookmark((await store.get(site.id))!);
    expect(moved.record.flag('userModified'), isTrue);
    expect(moved.categoryId, uncategorizedId);
    await repo.removeWebsites([moved], confirmed: true);
    final deleted = (await repo.watchTrash().first).firstWhere(
      (s) => s.id == site.id,
    );
    moved = await repo.restoreWebsite(deleted);
    expect(moved.record.flag('userModified'), isTrue);
    expect(
      (await WebLibrarySearchService(store).search(
        moved.title,
        view: 'personal',
      )).items.any((s) => s.id == moved.id),
      isTrue,
    );
  });
  test(
    'initialization failure can retry without a partially applied catalogue',
    () async {
      var attempts = 0;
      final retry = WebLibraryRepository(
        store,
        catalog: () async {
          if (attempts++ == 0) {
            throw const ToolFailure('temporary fixture failure');
          }
          return fixtureCatalog();
        },
      );
      await expectLater(retry.initialize(), throwsA(isA<ToolFailure>()));
      expect(await store.setting('webLibrary.dataVersion'), isNull);
      await retry.initialize();
      expect((await retry.sites()).length, 3);
      expect(attempts, 2);
    },
  );
}
