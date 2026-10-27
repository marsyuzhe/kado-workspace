import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:links_toolbox/core/backup/backup_service.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/utilities/bookmark_metadata.dart';
import 'package:links_toolbox/features/web_library/web_favicons.dart';
import 'package:links_toolbox/features/web_library/web_icons.dart';
import 'package:links_toolbox/features/web_library/web_import_reader.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_repository.dart';
import 'package:links_toolbox/features/web_library/web_transfer.dart';

import 'web_library_test.dart' show fixtureCatalog;

class _CancelAfterRow extends UtilityJobContext {
  _CancelAfterRow(super.id, super.repository);
  @override
  Future<void> progress(
    int processed,
    int total, {
    String currentFile = '',
    double? fraction,
    bool force = false,
  }) async {
    await cancel();
    check();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late WebLibraryRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kado-web-safety-');
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    repo = WebLibraryRepository(store, catalog: () async => fixtureCatalog());
    await repo.initialize();
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test('proxy policy refusal happens before DNS, private redirect targets are invalid', () async {
    var calls = 0;
    final network = BookmarkMetadataService(
      directNetworkAllowed: (uri) async {
        calls++;
        return false;
      },
    );
    await expectLater(
      network.fetch('https://does-not-exist.example/'),
      throwsA(isA<ToolFailure>()),
    );
    expect(calls, 1);
    for (final address in [
      'http://127.0.0.1/',
      'http://10.1.2.3/',
      'https://host.internal/',
      'https://example.org:8443/',
    ]) {
      expect(
        () => BookmarkMetadataService.validateUri(Uri.parse(address)),
        throwsA(isA<ToolFailure>()),
      );
    }
  });
  test(
    'cache cleanup preserves custom icons and unrelated cache files',
    () async {
      final owned = OwnedFileStore(temp),
          icons = WebIconService(store, () async => owned),
          site = (await repo.sites()).first;
      final saved = await icons.setIcon(
        site,
        Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 16))),
      );
      final cache = WebFaviconService(store, () async => owned),
          file = WebFaviconService.cacheFile(owned, '${'a' * 64}.png');
      await file.parent.create(recursive: true);
      await file.writeAsString('owned cache fixture');
      final other = File('${file.parent.path}/keep.txt');
      await other.writeAsString('unrelated');
      expect(await cache.clear(), 1);
      expect(await other.readAsString(), 'unrelated');
      expect(await owned.resolve(saved.customIconPath).exists(), isTrue);
    },
  );
  test(
    'cancel after first SQLite row rolls back category and site writes',
    () async {
      final draft = WebImportDraft(
        [WebImportCategory(newId(), const WebsiteCategoryInput('未提交分类'))],
        [
          WebImportSite(
            newId(),
            const WebsiteInput('未提交网站', 'https://example.org/rollback'),
          ),
        ],
        [],
        [],
      );
      final service = WebTransferService(
            repo,
            () async => OwnedFileStore(temp),
          ),
          preview = await service.preview(draft, '中途取消');
      final context = _CancelAfterRow(newId(), JobQueueRepository(store));
      await expectLater(
        service.commit(preview, context, confirmed: true),
        throwsA(anything),
      );
      expect(context.cancellation.cancelled, isTrue);
      expect((await repo.categories()).any((c) => c.name == '未提交分类'), isFalse);
      expect((await repo.sites()).any((s) => s.title == '未提交网站'), isFalse);
      expect((await store.get(preview.id))!.text('status'), 'preview');
      expect(await store.list('web_import_batch'), isEmpty);
    },
  );
  test('full database backup restores categories live and trash sites plus user icon attachments', () async {
    final icon = Uint8List.fromList(
          img.encodePng(img.Image(width: 16, height: 16)),
        ),
        owned = OwnedFileStore(temp);
    final category = await repo.saveCategory(
      const WebsiteCategoryInput('全备份分类'),
    );
    var site = await repo.saveWebsite(
      WebsiteInput(
        '全备份网站',
        'https://example.org/backup',
        categoryId: category.id,
      ),
    );
    site = await WebIconService(store, () async => owned).setIcon(site, icon);
    final deleted = (await repo.sites()).firstWhere((s) => s.id != site.id);
    await repo.removeWebsites([deleted], confirmed: true);
    final backup = BackupService(db, owned, LocalDataHome(temp)),
        zip = await backup.create(),
        preview = await backup.inspect(zip);
    expect(preview.counts['web_icon'], 1);
    expect(preview.files.keys.any((key) => key.contains('web_icons')), isTrue);
    await backup.home.schedule(preview, confirmed: true);
    await db.close();
    expect(await backup.home.applyPending(), isTrue);
    final active = await backup.home.active();
    db = AppDatabase.file(File('${active.path}/links_toolbox.sqlite'));
    await db.initialize();
    final restored = RecordStore(db),
        restoredRepo = WebLibraryRepository(
          restored,
          catalog: () async => fixtureCatalog(),
        );
    expect(
      (await restoredRepo.sites()).any(
        (s) => s.id == site.id && s.categoryId == category.id,
      ),
      isTrue,
    );
    expect(
      (await restoredRepo.watchTrash().first).any((s) => s.id == deleted.id),
      isTrue,
    );
    expect(
      await OwnedFileStore(active)
          .resolve((await restored.get(site.id))!.text('customIconPath'))
          .readAsBytes(),
      await owned.resolve(site.customIconPath).readAsBytes(),
    );
    expect(
      (await restoredRepo.categories()).any((c) => c.id == category.id),
      isTrue,
    );
  });
  test('attachment junction refuses both writes and removal outside managed namespace', () async {
    if (!Platform.isWindows) return;
    final outside = Directory('${temp.path}/owned-outside-fixture');
    await outside.create();
    final attachments = Directory('${temp.path}/managed/attachments');
    await attachments.create(recursive: true);
    final link = '${attachments.path}/web_icons',
        sentinel = File('${outside.path}/keep.png');
    await sentinel.writeAsString('preserve');
    final command =
        "New-Item -ItemType Junction -Path '${link.replaceAll("'", "''")}' -Target '${outside.path.replaceAll("'", "''")}' | Out-Null";
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      command,
    ]);
    expect(result.exitCode, 0);
    try {
      final managed = OwnedFileStore(Directory('${temp.path}/managed'));
      await expectLater(
        managed.write('web_icons', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ToolFailure>()),
      );
      await expectLater(
        managed.remove('attachments/web_icons/keep.png'),
        throwsA(isA<ToolFailure>()),
      );
      expect(await sentinel.readAsString(), 'preserve');
      expect(await outside.list().length, 1);
    } finally {
      await Link(link).delete();
    }
  });
}
