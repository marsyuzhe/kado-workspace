import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:links_toolbox/core/backup/backup_service.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/archive/archive_service.dart';
import 'package:links_toolbox/features/hub/hub_repository.dart';
import 'package:links_toolbox/features/studio/studio_repository.dart';
import 'package:links_toolbox/features/utilities/image_service.dart';
import 'package:links_toolbox/features/utilities/personal_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late OwnedFileStore files;
  late ImageToolService images;
  late BookmarkService bookmarks;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-utilities-');
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    files = OwnedFileStore(temp);
    images = ImageToolService(store, () async => files);
    bookmarks = BookmarkService(HubRepository(store));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Uint8List fixture() {
    final im = img.Image(width: 80, height: 60, numChannels: 4);
    img.fillRect(
      im,
      x1: 0,
      y1: 0,
      x2: 39,
      y2: 59,
      color: img.ColorRgba8(180, 40, 80, 255),
    );
    im.exif.imageIfd['Make'] = 'Fixture Camera';
    return img.encodePng(im);
  }

  test('bookmarks share Hub records, persist metadata and reject dangerous schemes', () async {
    final bookmark = await bookmarks.save(
      const BookmarkInput(
        '仓库',
        'https://github.com/example/project',
        description: '中文资料',
        category: '代码',
        tags: ['Dart'],
      ),
    );
    expect((await HubRepository(store).favorites()).single.id, bookmark.id);
    expect(
      (await store.search('中文资料', kinds: ['favorite'])).single.id,
      bookmark.id,
    );
    await expectLater(
      bookmarks.save(const BookmarkInput('恶意', 'javascript:alert(1)')),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('browser bookmark preview is inert, escaping round trips and import needs confirmation', () async {
    final preview = bookmarks.previewImport(
      '<DL><DT><A HREF="https://example.invalid/?x=1&amp;y=2" TAGS="a,b">中文 &amp; 标签</A><DT><A HREF="javascript:alert(1)">bad</A><script>ignored()</script></DL>',
    );
    expect(preview.length, 1);
    expect(preview.single.url, 'https://example.invalid/?x=1&y=2');
    await expectLater(
      bookmarks.importConfirmed(preview, confirmed: false),
      throwsA(isA<ToolFailure>()),
    );
    await bookmarks.importConfirmed(preview, confirmed: true);
    final html = bookmarks.export(await HubRepository(store).favorites());
    expect(bookmarks.previewImport(html).single.title, '中文 & 标签');
    await bookmarks.importConfirmed(preview, confirmed: true);
    expect((await HubRepository(store).favorites()).length, 1);
  });
  test(
    'import deduplication preserves existing private descriptions',
    () async {
      final original = await bookmarks.save(
        const BookmarkInput(
          '原名称',
          'https://example.invalid',
          description: '保留说明',
        ),
      );
      final same = await bookmarks.save(
        const BookmarkInput('导入旧名称', 'https://example.invalid'),
      );
      expect(same.id, original.id);
      expect((await store.get(original.id))!.body, '保留说明');
    },
  );
  for (final format in ['png', 'jpg', 'webp']) {
    test(
      '$format transform produces decodable real bytes on an isolate with exact resize',
      () async {
        final photo = img.Image(width: 80, height: 60)
          ..clear(img.ColorRgb8(180, 40, 80));
        photo.exif.imageIfd['Make'] = 'Fixture Camera';
        final source = img.encodeJpg(photo), before = sha256.convert(source);
        expect(
          img.decodeJpg(source)!.exif.toString(),
          contains('Fixture Camera'),
        );
        final output = await images.preview(
          source,
          ImageOptions(
            format: format,
            width: 40,
            height: 30,
            whiteBackground: true,
            stripExif: true,
          ),
        );
        final decoded = img.decodeImage(output.bytes)!;
        expect(decoded.width, 40);
        expect(decoded.height, 30);
        expect(decoded.exif.imageIfd['Make'], isNull);
        expect(sha256.convert(source), before);
        expect(output.exif, contains('Fixture Camera'));
      },
    );
  }
  test('crop, white background and image watermark change real pixels without source overwrite', () async {
    final mark = img.Image(width: 5, height: 5, numChannels: 4)
      ..clear(img.ColorRgba8(0, 0, 255, 255));
    final output = await images.preview(
      fixture(),
      ImageOptions(
        cropX: 30,
        cropY: 0,
        cropWidth: 40,
        cropHeight: 30,
        whiteBackground: true,
        watermark: img.encodePng(mark),
      ),
    );
    final decoded = img.decodePng(output.bytes)!;
    expect(decoded.getPixel(20, 10).r, 255);
    expect(decoded.getPixel(39, 29).b, 255);
    expect(decoded.getPixel(39, 29).r, 0);
  });
  test(
    'oversize parameters, malformed images and outside crop are rejected',
    () async {
      await expectLater(
        images.preview(Uint8List.fromList([1, 2, 3]), const ImageOptions()),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        images.preview(fixture(), const ImageOptions(width: 50000)),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        images.preview(
          fixture(),
          const ImageOptions(cropX: 79, cropWidth: 20, cropHeight: 20),
        ),
        throwsA(isA<ToolFailure>()),
      );
    },
  );
  test('confirmed outputs persist owned attachments and participate in real complete backups', () async {
    await expectLater(
      images.process(
        'source.png',
        fixture(),
        const ImageOptions(),
        TaskCancellation(),
        confirmed: false,
      ),
      throwsA(isA<ToolFailure>()),
    );
    final record = await images.process(
      'source.png',
      fixture(),
      const ImageOptions(width: 20),
      TaskCancellation(),
      confirmed: true,
    );
    final bytes = await files.resolve(record.text('attachment')).readAsBytes();
    expect(record.text('checksum'), sha256.convert(bytes).toString());
    expect(img.decodePng(bytes)!.width, 20);
    final backup = BackupService(db, files, LocalDataHome(temp));
    final preview = await backup.inspect(await backup.create());
    expect(preview.counts['utility_output'], 1);
    expect(preview.files.length, 2);
  });
  test(
    'cancel before transform writes neither a record nor an attachment',
    () async {
      final cancel = TaskCancellation()..cancel();
      await expectLater(
        images.process(
          'cancel.png',
          fixture(),
          const ImageOptions(),
          cancel,
          confirmed: true,
        ),
        throwsA(isA<ToolFailure>()),
      );
      expect(await store.list('utility_output'), isEmpty);
      expect(await Directory('${temp.path}/attachments').exists(), isFalse);
    },
  );
  test('personal tasks validate dates, persist status and cannot enter Agent runtime', () async {
    final timeline = PersonalTimeline(store),
        date = PersonalTimeline.parseLocalDate('2026-10-23 13:20')!;
    expect(
      () => PersonalTimeline.parseLocalDate('2026-02-31 12:00'),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => PersonalTimeline.parseLocalDate('2026-10-23 25:00'),
      throwsA(isA<ToolFailure>()),
    );
    final todo = await timeline.save('个人事项', due: date, priority: 3);
    expect(
      PersonalTimeline.overdue(todo, date.add(const Duration(hours: 1))),
      isTrue,
    );
    await timeline.setState(todo, 'done');
    expect(
      PersonalTimeline.overdue(
        (await store.get(todo.id))!,
        date.add(const Duration(hours: 1)),
      ),
      isFalse,
    );
    await expectLater(
      StudioRepository(store).requireTask(todo.id),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('Archive enhanced rules protect extension, use capture/date/number and reject risky patterns', () {
    final file = ArchiveFile(
      'C:/fixture/report 12.JPG',
      10,
      DateTime(2026, 10, 23, 13, 20),
      '图片',
    );
    expect(
      const RenameRule(
        regex: true,
        find: r'(\d+)',
        replace: r'ID$1',
        sequence: true,
        sequenceStart: 10,
        sequenceWidth: 4,
        date: true,
        datePattern: 'yyyy-MM-dd',
      ).apply(file, 2),
      '2026-10-23_0012_report ID12.JPG',
    );
    expect(
      () => const RenameRule(
        regex: true,
        find: r'(a+)+$',
        replace: 'x',
      ).apply(file, 0),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => const RenameRule(
        regex: true,
        find: r'\d+',
        replace: r'$2',
      ).apply(file, 0),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('renaming still uses existing preview conflict and exclusive execution boundaries', () async {
    final source = File('${temp.path}/report 12.txt');
    await source.writeAsString('untouched');
    final scan = await ArchiveScanner().scan(temp.path, TaskCancellation());
    final service = ArchiveService(store, NativePlatformAdapter());
    final plan = await service.plan(
      scan.files.where((f) => f.name == 'report 12.txt').toList(),
      'rename',
      TaskCancellation(),
      rule: const RenameRule(regex: true, find: r'\d+', replace: '20'),
    );
    expect(plan.files.single.target, endsWith('report 20.txt'));
    expect(await source.readAsString(), 'untouched');
  });
}
