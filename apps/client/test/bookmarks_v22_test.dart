import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/features/hub/hub_repository.dart';
import 'package:links_toolbox/features/utilities/personal_tools.dart';
import 'package:links_toolbox/features/utilities/bookmark_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late BookmarkService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-bookmarks-v22-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    service = BookmarkService(HubRepository(store));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test('normal, GitHub, video bookmarks roundtrip JSON/CSV and exact URL dedup preserves distinct links', () async {
    for (final value in [
      const BookmarkInput(
        '网页中文',
        'https://example.invalid/?a=1&b=2',
        tags: ['文档', 'a|b'],
      ),
      const BookmarkInput(
        '仓库',
        'https://github.com/flutter/flutter',
        category: '开发',
        favorite: true,
      ),
      const BookmarkInput(
        '视频',
        'https://example.invalid/?b=2&a=1',
        description: '带,逗号\n"换行"',
      ),
    ]) {
      await service.save(value);
    }
    final records = await store.list('favorite');
    expect(records.length, 3);
    expect(
      records.firstWhere((r) => r.title == '仓库').text('repositoryOwner'),
      'flutter',
    );
    for (final format in ['json', 'csv']) {
      final preview = service.previewStructured(
        service.exportStructured(records, format),
        format,
      );
      expect(preview.length, 3);
      expect(preview.firstWhere((r) => r.title == '网页中文').tags, ['文档', 'a|b']);
      expect(preview.firstWhere((r) => r.title == '仓库').favorite, true);
      expect(
        preview.firstWhere((r) => r.title == '视频').description,
        '带,逗号\n"换行"',
      );
      await service.importConfirmed(preview, confirmed: true);
      expect((await store.list('favorite')).length, 3);
    }
    await service.recordOpened(records.first.id);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect(
      (await store.get(records.first.id))!.text('lastOpenedAt'),
      isNotEmpty,
    );
    expect((await store.list('favorite')).length, 3);
  });
  test(
    'CSV formula guard is reversible without mutating original fields',
    () async {
      await service.save(
        const BookmarkInput(
          '=HYPERLINK("bad")',
          'https://example.invalid',
          description: '  +123',
          tags: ["'tag"],
        ),
      );
      final encoded = service.exportStructured(
        await store.list('favorite'),
        'csv',
      );
      expect(encoded, contains("'=HYPERLINK"));
      final decoded = service.previewStructured(encoded, 'csv').single;
      expect(decoded.title, '=HYPERLINK("bad")');
      expect(decoded.description, '  +123');
      expect(decoded.tags, ["'tag"]);
    },
  );
  test('batch favorite and delete are atomic, validated and require delete confirmation', () async {
    final a = await service.save(const BookmarkInput('A', 'https://a.invalid'));
    final b = await service.save(const BookmarkInput('B', 'https://b.invalid'));
    await service.setFavorite([a.id, b.id], true);
    expect(
      (await store.list('favorite')).every((r) => r.flag('favorite')),
      true,
    );
    await expectLater(
      service.setFavorite([a.id, 'missing'], false),
      throwsA(isA<ToolFailure>()),
    );
    expect((await store.get(a.id))!.flag('favorite'), true);
    await expectLater(
      service.removeAll([a.id], confirmed: false),
      throwsA(isA<ToolFailure>()),
    );
    await service.removeAll([a.id, b.id], confirmed: true);
    expect(await store.list('favorite'), isEmpty);
  });
  test('metadata parser is inert and private/mapped/transition addresses are rejected', () async {
    final input = BookmarkMetadataService.parse(
      '<title>中文 &amp; 标题</title><meta name="description" content="内容"><script>bad()</script>',
      Uri.parse('https://example.invalid'),
    );
    expect(input.title, '中文 & 标题');
    expect(input.description, '内容');
    for (final host in [
      '127.0.0.1',
      '10.1.2.3',
      '192.168.1.1',
      '172.16.2.3',
      '169.254.1.1',
      '100.64.0.1',
      '0.0.0.0',
      '::1',
      'fc00::1',
      'fe80::1',
      '::ffff:192.168.1.1',
      '2002:c0a8:101::',
      '2001:db8::1',
    ]) {
      expect(
        BookmarkMetadataService.publicAddress(InternetAddress(host)),
        false,
        reason: host,
      );
    }
    expect(
      BookmarkMetadataService.publicAddress(InternetAddress('1.1.1.1')),
      true,
    );
    for (final url in [
      'http://127.0.0.1',
      'http://router.local',
      'http://10.0.0.1',
      'https://example.com:9000',
      'file:///x',
    ]) {
      await expectLater(
        BookmarkMetadataService().fetch(url),
        throwsA(isA<ToolFailure>()),
      );
    }
    await expectLater(
      service.save(
        const BookmarkInput('手动离线', 'https://never-resolve.invalid'),
      ),
      completes,
    );
    expect(service.previewStructured('{"bookmarks":[]}', 'json'), isEmpty);
    expect(
      () => service.previewStructured(
        '[{"title":"X","url":"javascript:alert(1)"}]',
        'json',
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => service.previewStructured('bad', 'json'),
      throwsA(isA<ToolFailure>()),
    );
  });
}
