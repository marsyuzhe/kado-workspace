import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:links_toolbox/core/backup/backup_service.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/utilities/collection_service.dart';
import 'package:links_toolbox/features/utilities/image_service.dart';

Uint8List collectionFixture({bool jpeg = false}) {
  final image = img.Image(width: 640, height: 320);
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: 319,
    y2: 319,
    color: img.ColorRgb8(65, 100, 180),
  );
  img.fillRect(
    image,
    x1: 320,
    y1: 0,
    x2: 639,
    y2: 319,
    color: img.ColorRgb8(190, 70, 110),
  );
  return Uint8List.fromList(jpeg ? img.encodeJpg(image) : img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  late OwnedFileStore files;
  late UtilityJobEngine jobs;
  late CollectionService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-collection-test-');
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    files = OwnedFileStore(temp);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    service = CollectionService(
      store,
      () async => files,
      ImageToolService(store, () async => files),
    );
  });
  tearDown(() async {
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> execute(String type, UtilityJobHandler action) async {
    final row = await jobs.submit(
      'collection_cards',
      type,
      type,
      {},
      confirmed: true,
      run: action,
    );
    return jobs.waitFor(row.id);
  }

  Future<ToolRecord> result(ToolRecord done) async {
    expect(
      utilityJobStatus(done),
      UtilityJobStatus.succeeded,
      reason: done.text('errorMessage'),
    );
    return (await store.get(done.text('resultReference')))!;
  }

  test('anime, Ronaldo material and numbered cards retain structured serials, exact costs, manual estimates and realized profit across reopen', () async {
    var anime = await service.save(
      const CollectionInput(
        name: '合成测试动漫卡',
        playerOrCharacter: '测试角色',
        collectionType: '动漫卡',
        brand: '自有测试品牌',
        series: '合成测试系列',
        notes: '=HYPERLINK("unsafe")',
      ),
    );
    anime = await service.setCosts(
      anime,
      currency: 'CNY',
      purchase: '10.00',
      shipping: '2.00',
      manualValue: '20.00',
      manualValueSource: '用户手动估值，不是实时市场报价',
      purchaseDate: '2026-10-01',
      purchaseSource: '测试订单',
    );
    var cr7 = await service.save(
      const CollectionInput(
        name: 'C罗物料卡测试登记',
        playerOrCharacter: 'Cristiano Ronaldo',
        collectionType: '足球球星卡',
        serialNumber: 8,
        serialTotal: 49,
        memorabiliaType: '球员穿着物料',
        evidence: '测试：仅记录用户填写的背面说明，不由卡面图片推断',
        gradeCompany: '手工测试评级',
        grade: '9.5',
      ),
    );
    cr7 = await service.setCosts(
      cr7,
      currency: 'CNY',
      purchase: '100.00',
      shipping: '10.00',
      buyFee: '5.00',
      sold: true,
      sale: '200.00',
      sellingFee: '10.00',
      saleDate: '2026-10-02',
    );
    final numbered = await service.save(
      const CollectionInput(
        name: '普通编数卡',
        playerOrCharacter: '测试球员',
        serialNumber: 66,
        serialTotal: 99,
      ),
    );
    expect(CollectionService.serial(cr7), '08/49');
    expect(CollectionService.serial(numbered), '66/99');
    expect(CollectionService.profit(cr7), 7500);
    expect(CollectionService.profit(anime), null);
    expect(CollectionService.cost(anime), 1200);
    expect(anime.number('manualValueMinor'), 2000);
    expect(numbered.text('memorabiliaType'), '来源未知');
    expect(numbered.flag('costRecorded'), false);
    await service.favorite(anime, true);
    anime = (await store.get(anime.id))!;
    expect(
      CollectionService.matches(
        anime,
        '测试角色',
        type: '动漫卡',
        favoritesOnly: true,
        state: 'owned',
      ),
      true,
    );
    expect(CollectionService.matches(cr7, 'Ronaldo', state: 'owned'), false);
    final summary = CollectionSummary(await service.all());
    expect(summary.owned, 2);
    expect(summary.sold, 1);
    expect(summary.priced, 2);
    expect(summary.ownedCosts['CNY'], 1200);
    expect(summary.realized['CNY'], 7500);
    final csvText = CollectionService.exportCsv(await service.all());
    expect(csvText, contains("'=HYPERLINK"));
    final rows = csv.decode(csvText.replaceFirst('\ufeff', ''));
    expect(rows.length, 4);
    expect(
      rows.first,
      containsAll([
        'serialNumber',
        'serialTotal',
        'totalCost',
        'manualValueSource',
        'realizedProfit',
      ]),
    );
    final exported = await result(
      await execute(
        'export',
        (ctx, _) async =>
            (await service.prepareExport(await service.all(), ctx)).id,
      ),
    );
    expect(
      await files.resolve(exported.text('attachment')).readAsBytes(),
      utf8.encode(csvText),
    );
    await db.close();
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    service = CollectionService(
      store,
      () async => files,
      ImageToolService(store, () async => files),
    );
    final saved = (await store.get(cr7.id))!;
    expect(CollectionService.serial(saved), '08/49');
    expect(CollectionService.profit(saved), 7500);
  });
  test('real PNG/JPEG originals and PNG thumbnails are independent owned attachments, backed up and removed without touching selected source files', () async {
    var card = await service.save(
      const CollectionInput(name: '图片持久化测试卡', playerOrCharacter: '测试人物'),
    );
    final source = await File('${temp.path}/selected-original.png')
            .writeAsBytes(collectionFixture()),
        originalBytes = await source.readAsBytes();
    final front = await result(
      await execute(
        'image',
        (ctx, _) async => (await service.addImage(
          card,
          'front.png',
          originalBytes,
          'front',
          ctx,
        )).id,
      ),
    );
    card = (await store.get(card.id))!;
    final back = await result(
      await execute(
        'image',
        (ctx, _) async => (await service.addImage(
          card,
          'back.jpg',
          collectionFixture(jpeg: true),
          'back',
          ctx,
        )).id,
      ),
    );
    expect(
      await files.resolve(front.text('attachment')).readAsBytes(),
      originalBytes,
    );
    expect(front.text('checksum'), sha256.convert(originalBytes).toString());
    final thumbnail = img.decodePng(
      await files.resolve(front.text('thumbnailAttachment')).readAsBytes(),
    )!;
    expect(thumbnail.width, 320);
    expect(thumbnail.height, 160);
    final photos = await service.imageRows(card.id);
    expect(photos.length, 2);
    expect((await store.list('collection_thumbnail')).length, 2);
    expect((await store.get(card.id))!.number('imageCount'), 2);
    final backup = BackupService(db, files, LocalDataHome(temp)),
        inspection = await backup.inspect(await backup.create());
    expect(inspection.counts['collection_image'], 2);
    expect(inspection.counts['collection_thumbnail'], 2);
    expect(inspection.files.length, 5);
    await service.removeImage(front, confirmed: true);
    expect(await files.resolve(front.text('attachment')).exists(), false);
    expect(
      await files.resolve(front.text('thumbnailAttachment')).exists(),
      false,
    );
    expect(await files.resolve(back.text('attachment')).exists(), true);
    expect(await source.readAsBytes(), originalBytes);
    card = (await store.get(card.id))!;
    expect(card.text('coverImageId'), back.id);
    expect(card.number('imageCount'), 1);
    await service.remove(card, confirmed: true);
    expect(await service.all(), isEmpty);
    expect(await service.imageRows(card.id), isEmpty);
    expect(await files.resolve(back.text('attachment')).exists(), false);
    expect(await source.readAsBytes(), originalBytes);
  });
  test('invalid numbering, inferred material, bad images and unconfirmed removal fail without creating photos or mutating existing cards', () async {
    for (final input in [
      const CollectionInput(name: 'x', playerOrCharacter: 'x', serialNumber: 8),
      const CollectionInput(
        name: 'x',
        playerOrCharacter: 'x',
        serialNumber: 50,
        serialTotal: 49,
      ),
      const CollectionInput(
        name: 'x',
        playerOrCharacter: 'x',
        memorabiliaType: '看到球衣就猜比赛使用',
      ),
      const CollectionInput(name: 'x', playerOrCharacter: 'x', grade: '10'),
    ]) {
      await expectLater(service.save(input), throwsA(isA<ToolFailure>()));
    }
    final card = await service.save(
      const CollectionInput(name: '原卡', playerOrCharacter: '保留'),
    );
    expect(card.text('memorabiliaType'), '来源未知');
    await expectLater(
      service.setCosts(card, currency: 'CNY', purchase: '1.001'),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      service.setCosts(card, currency: 'CNY', purchase: '1', sold: true),
      throwsA(isA<ToolFailure>()),
    );
    final bad = await execute(
      'image',
      (ctx, _) async => (await service.addImage(
        card,
        'bad.png',
        Uint8List.fromList([137, 80, 78, 71]),
        'front',
        ctx,
      )).id,
    );
    expect(utilityJobStatus(bad), UtilityJobStatus.failed);
    expect(await store.list('collection_image'), isEmpty);
    expect(await store.list('collection_thumbnail'), isEmpty);
    await expectLater(
      service.remove(card, confirmed: false),
      throwsA(isA<ToolFailure>()),
    );
    expect((await service.all()).single.id, card.id);
  });
}
