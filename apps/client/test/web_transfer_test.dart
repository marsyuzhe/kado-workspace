import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/web_library/web_icons.dart';
import 'package:links_toolbox/features/web_library/web_import_reader.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_repository.dart';
import 'package:links_toolbox/features/web_library/web_transfer.dart';

import 'web_library_test.dart' show fixtureCatalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late WebLibraryRepository repo;
  late WebTransferService service;
  late UtilityJobEngine jobs;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kado-web-transfer-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    service = WebTransferService(repo, () async => OwnedFileStore(temp));
    jobs = UtilityJobEngine(JobQueueRepository(store));
    await repo.initialize();
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<WebImportDraft> read(String text, String format) =>
      WebImportReader.read(Uint8List.fromList(utf8.encode(text)), format);
  Future<String> commit(dynamic preview, {bool skipInvalid = false}) async {
    final submitted = await jobs.submit(
      'bookmarks',
      'import',
      '测试实际写入',
      {'previewId': preview.id},
      confirmed: true,
      run: (ctx, _) async => (await service.commit(
        preview,
        ctx,
        confirmed: true,
        skipInvalid: skipInvalid,
      )).id,
    );
    return (await jobs.waitFor(submitted.id)).text('status');
  }

  test(
    'Netscape nested folders, script URLs and inert content are previewed',
    () async {
      final draft = await read(
        '<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p><DT><H3>开发</H3><DL><p><DT><A HREF="https://example.org/a">A &amp; B</A><DD>描述<DT><H3>文档</H3><DL><p><DT><A HREF="https://example.org/b">B</A></DL><p></DL><p><DT><A HREF="javascript:alert(1)">unsafe</A></DL><script>throw 1</script>',
        'html',
      );
      expect(draft.sites.length, 2);
      expect(draft.errors.length, 1);
      final a = draft.sites.firstWhere((s) => s.input.title == 'A & B'),
          b = draft.sites.firstWhere((s) => s.input.title == 'B');
      expect(
        draft.categories
            .firstWhere((c) => c.id == a.input.categoryId)
            .input
            .name,
        '开发',
      );
      final child = draft.categories.firstWhere(
        (c) => c.id == b.input.categoryId,
      );
      expect(child.input.name, '文档');
      expect(child.input.parentId, a.input.categoryId);
      expect(a.input.description, '描述');
      final preview = await service.preview(draft, '浏览器');
      expect(await commit(preview), 'failed');
      expect(await commit(preview, skipInvalid: true), 'succeeded');
      expect((await repo.sites()).length, 5);
    },
  );
  test(
    'HTML export roundtrip preserves IDs folders flags tags and escapes',
    () async {
      final root = await repo.saveCategory(
        const WebsiteCategoryInput('父 & <分类>'),
      );
      final child = await repo.saveCategory(
        WebsiteCategoryInput('子分类', parentId: root.id),
      );
      final site = await repo.saveWebsite(
        WebsiteInput(
          '标题 <script>',
          'https://example.org/?a=1&b=2',
          description: '描述 " 与 &',
          categoryId: child.id,
          tags: ['中文', 'a,b'],
          isFavorite: true,
          isPinned: true,
        ),
      );
      final bytes = await service.export('html'),
          draft = await WebImportReader.read(bytes, 'html');
      expect(draft.errors, isEmpty);
      expect(draft.sites.length, 4);
      final restored = draft.sites.firstWhere((s) => s.id == site.id);
      expect(restored.input.title, site.title);
      expect(restored.input.description, site.description);
      expect(restored.input.url, site.url);
      expect(restored.input.categoryId, child.id);
      expect(restored.input.isFavorite, isTrue);
      expect(restored.input.isPinned, isTrue);
      expect(restored.input.tags, site.tags);
      expect(
        draft.categories.firstWhere((c) => c.id == child.id).input.parentId,
        root.id,
      );
    },
  );
  test('JSON full snapshot reconstructs custom categories icons visits and deletion of untouched defaults', () async {
    await repo.removeWebsites([(await repo.sites()).first], confirmed: true);
    final c = await repo.saveCategory(
      const WebsiteCategoryInput(
        '自定义',
        iconKey: 'code',
        color: '#123456',
        isHidden: true,
      ),
    );
    var s = await repo.saveWebsite(
      WebsiteInput(
        '我的网址',
        'https://example.org/own',
        categoryId: c.id,
        isFavorite: true,
        isPinned: true,
        tags: ['私有'],
      ),
    );
    s = WebsiteBookmark(
      await store.save(
        s.record.copyWith(
          data: {
            ...s.record.data,
            'visitCount': 7,
            'lastVisitedAt': '2026-10-01T01:02:03.000Z',
          },
        ),
      ),
    );
    s = await WebIconService(store, () async => OwnedFileStore(temp)).setIcon(
      s,
      Uint8List.fromList(img.encodePng(img.Image(width: 12, height: 12))),
    );
    final bytes = await service.export('json'),
        draft = await WebImportReader.read(bytes, 'json');
    expect(draft.errors, isEmpty);
    expect(draft.fullSnapshot, isTrue);
    final target = await Directory.systemTemp.createTemp('kado-roundtrip-'),
        other = AppDatabase.file(File('${target.path}/target.sqlite'));
    await other.initialize();
    final secondStore = RecordStore(other),
        secondRepo = WebLibraryRepository(
          secondStore,
          catalog: () async => fixtureCatalog(),
        );
    final second = WebTransferService(
          secondRepo,
          () async => OwnedFileStore(target),
        ),
        engine = UtilityJobEngine(JobQueueRepository(secondStore));
    try {
      final p = await second.preview(draft, '完整JSON', replaceDefaults: true);
      expect(p.number('replaceDefaultsCount'), 1);
      final j = await engine.submit(
        'bookmarks',
        'import',
        '完整JSON',
        {},
        confirmed: true,
        run: (ctx, _) async =>
            (await second.commit(p, ctx, confirmed: true)).id,
      );
      expect((await engine.waitFor(j.id)).text('status'), 'succeeded');
      expect(
        (await secondRepo.sites()).map((s) => s.id).toSet(),
        (await repo.sites()).map((s) => s.id).toSet(),
      );
      final restored = WebsiteBookmark((await secondStore.get(s.id))!);
      expect(restored.categoryId, c.id);
      expect(restored.isFavorite, isTrue);
      expect(restored.visitCount, 7);
      expect(restored.lastVisitedAt, s.lastVisitedAt);
      expect(restored.record.createdAt, s.record.createdAt);
      expect(
        await OwnedFileStore(target).resolve(restored.customIconPath).exists(),
        isTrue,
      );
      expect(
        (await secondRepo.categories())
            .firstWhere((v) => v.id == c.id)
            .isHidden,
        isTrue,
      );
      final again = await second.preview(draft, '重复');
      expect(again.number('toWrite'), 0);
    } finally {
      await engine.dispose();
      await other.close();
      await target.delete(recursive: true);
    }
  });
  test(
    'stale preview refuses all writes and import never overwrites user changes',
    () async {
      final draft = await read(
        '[{"title":"新网站","url":"https://example.org/new"}]',
        'json',
      );
      final p = await service.preview(draft, 'snapshot');
      await repo.saveWebsite(
        const WebsiteInput('并发修改', 'https://example.org/other'),
      );
      expect(await commit(p), 'failed');
      expect((await repo.sites()).any((s) => s.url.contains('/new')), isFalse);
      final existing = (await repo.sites()).first;
      final changed = await read(
        jsonEncode({
          'schemaVersion': 2,
          'scope': 'all',
          'categories': [],
          'websites': [
            {'id': existing.id, 'title': '恶意覆盖', 'url': existing.url},
          ],
        }),
        'json',
      );
      await repo.updateWebsites([existing], favorite: true);
      final preview = await service.preview(
        changed,
        '保留用户修改',
        replaceDefaults: true,
      );
      expect(preview.number('toWrite'), 0);
      expect(await commit(preview), 'succeeded');
      expect((await store.get(existing.id))!.title, existing.title);
    },
  );
  test(
    'CSV supports quoted multiline descriptions and rejects malformed types',
    () async {
      final draft = await read(
        'title,url,description,tags,isFavorite\n"中文,标题",https://example.org/csv,"第一行\n第二行",a|b,true\n',
        'csv',
      );
      expect(draft.errors, isEmpty);
      expect(draft.sites.single.input.description, '第一行\n第二行');
      expect(draft.sites.single.input.tags, ['a', 'b']);
      expect(draft.sites.single.input.isFavorite, isTrue);
      final invalid = await read(
        '[{"title":"非法","url":"file:///C:/x"},{"title":"日期","url":"https://example.org/date","createdAt":"2026-02-31T00:00:00Z"}]',
        'json',
      );
      expect(invalid.sites, isEmpty);
      expect(invalid.errors.length, 2);
      await repo.saveWebsite(
        const WebsiteInput(
          '=SUM(1)',
          'https://example.org/formula',
          description: '@cmd',
        ),
      );
      expect(utf8.decode(await service.export('csv')), contains("'=SUM(1)"));
    },
  );
  test(
    'cancelled transaction leaves no rows or imported icon or successful batch',
    () async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 16, height: 16)),
      );
      final draft = await read(
        jsonEncode({
          'schemaVersion': 2,
          'categories': [],
          'websites': [
            {
              'title': '取消测试',
              'url': 'https://example.org/cancel',
              'customIcon': {'base64': base64.encode(bytes)},
            },
          ],
        }),
        'json',
      );
      final preview = await service.preview(draft, '取消');
      final ctx = UtilityJobContext(newId(), JobQueueRepository(store));
      await ctx.cancel();
      await expectLater(
        service.commit(preview, ctx, confirmed: true),
        throwsA(anything),
      );
      expect((await repo.sites()).any((s) => s.title == '取消测试'), isFalse);
      expect(await store.list('web_import_batch'), isEmpty);
      final dir = Directory('${temp.path}/attachments/web_icons');
      expect(await dir.exists() ? await dir.list().length : 0, 0);
    },
  );
  test(
    'duplicate browser entries are counted separately from invalid rows',
    () async {
      final draft = await read(
        '<DL><DT><A HREF="https://example.org/repeated">first</A><DT><A HREF="https://example.org/repeated">second</A></DL>',
        'html',
      );
      expect(draft.sites.length, 1);
      expect(draft.duplicates, 1);
      expect(draft.errors, isEmpty);
      final preview = await service.preview(draft, '重复书签');
      expect(preview.number('duplicates'), 1);
      expect(await commit(preview), 'succeeded');
      expect(
        (await store.list('web_import_batch')).single.number('duplicates'),
        1,
      );
    },
  );
}
