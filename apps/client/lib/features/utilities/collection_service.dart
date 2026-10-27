import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/database/app_database.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/data_mutation_gate.dart';
import '../../core/storage/owned_file_store.dart';
import '../archive/archive_service.dart';
import 'image_service.dart';
import 'money.dart';
import 'civil_time.dart';

const collectionTypes = ['足球球星卡', '篮球球星卡', '动漫卡', '其他收藏卡'];
const memorabiliaTypes = ['来源未知', '普通物料', '比赛使用物料', '球员穿着物料'];
const collectionFaces = {'front': '正面', 'back': '背面', 'detail': '细节'};

class CollectionInput {
  const CollectionInput({
    required this.name,
    required this.playerOrCharacter,
    this.collectionType = '其他收藏卡',
    this.brand = '',
    this.series = '',
    this.year = '',
    this.cardNumber = '',
    this.serialNumber,
    this.serialTotal,
    this.serialNote = '',
    this.parallel = '',
    this.memorabiliaType = '来源未知',
    this.evidence = '',
    this.gradeCompany = '',
    this.grade = '',
    this.notes = '',
    this.tags = const [],
  });
  final String name,
      playerOrCharacter,
      collectionType,
      brand,
      series,
      year,
      cardNumber,
      serialNote,
      parallel,
      memorabiliaType,
      evidence,
      gradeCompany,
      grade,
      notes;
  final int? serialNumber, serialTotal;
  final List<String> tags;
  Map<String, dynamic> data() {
    if (name.trim().isEmpty ||
        playerOrCharacter.trim().isEmpty ||
        name.length > 200 ||
        playerOrCharacter.length > 200 ||
        collectionType.trim().isEmpty ||
        collectionType.length > 100 ||
        brand.length > 100 ||
        series.length > 200 ||
        year.length > 30 ||
        cardNumber.length > 100 ||
        serialNote.length > 500 ||
        parallel.length > 100 ||
        evidence.length > 4000 ||
        notes.length > 10000 ||
        gradeCompany.length > 100 ||
        grade.length > 100 ||
        tags.length > 30 ||
        tags.any((s) => s.length > 50)) {
      throw const ToolFailure('卡片名称、人物、分类必填，其他字段超出长度限制。');
    }
    if ((serialNumber == null) != (serialTotal == null) ||
        serialNumber != null &&
            (serialNumber! < 1 ||
                serialTotal! < 1 ||
                serialNumber! > serialTotal! ||
                serialTotal! > 1000000)) {
      throw const ToolFailure('编数需同时填写两个整数，且1≤序号≤总量≤1000000；特殊文字另记编数说明。');
    }
    if (!memorabiliaTypes.contains(memorabiliaType)) {
      throw const ToolFailure('物料来源请手动选择，不能从卡面推断比赛使用。');
    }
    if (grade.isNotEmpty && gradeCompany.trim().isEmpty) {
      throw const ToolFailure('填写评级时请注明评级公司或全部留空，不自动判定评级。');
    }
    return {
      'payloadVersion': 1,
      'collectionType': collectionType.trim(),
      'playerOrCharacter': playerOrCharacter.trim(),
      'brand': brand.trim(),
      'series': series.trim(),
      'year': year.trim(),
      'cardNumber': cardNumber.trim(),
      'serialNumber': serialNumber,
      'serialTotal': serialTotal,
      'serialNote': serialNote,
      'parallel': parallel,
      'memorabiliaType': memorabiliaType,
      'memorabiliaEvidence': evidence,
      'gradeCompany': gradeCompany.trim(),
      'grade': grade.trim(),
      'tags': tags
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
      'syncAllowed': false,
      'isSensitive': true,
    };
  }
}

class CollectionService {
  CollectionService(this.store, this.files, this.images);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  final ImageToolService images;
  static const limit = 10000, imageLimit = 15 * 1024 * 1024;
  SimpleSelectStatement<$LocalRecordsTable, LocalRecord> _cards() =>
      store.db.select(store.db.localRecords)
        ..where((t) => t.kind.equals('collection_card') & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
        ..limit(limit + 1);
  List<ToolRecord> _convert(Iterable<LocalRecord> raw) {
    final rows = raw.map(ToolRecord.fromRow).toList();
    if (rows.length > limit) {
      throw const ToolFailure('收藏记录超过10000张安全上限。');
    }
    return rows;
  }

  Future<List<ToolRecord>> all() async => _convert(await _cards().get());
  Stream<List<ToolRecord>> watch() => _cards().watch().map(_convert);
  Stream<List<ToolRecord>> watchImages(String cardId) => store.db
      .customSelect(
        "SELECT * FROM local_records WHERE kind='collection_image' AND deleted_at IS NULL AND json_extract(data,'\$.cardId')=? ORDER BY created_at LIMIT 13",
        variables: [Variable(cardId)],
        readsFrom: {store.db.localRecords},
      )
      .watch()
      .map(
        (rows) => rows
            .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
            .toList(),
      );
  Future<List<ToolRecord>> imageRows(String cardId) =>
      watchImages(cardId).first;
  Future<ToolRecord> _card(String id) async {
    final row = await store.get(id);
    if (row?.kind != 'collection_card') {
      throw const ToolFailure('收藏卡已不存在。');
    }
    return row!;
  }

  static String serial(ToolRecord row) {
    if (row.data['serialNumber'] is! int || row.data['serialTotal'] is! int) {
      return '未记录编数';
    }
    return '${row.number('serialNumber').toString().padLeft(row.number('serialTotal').toString().length, '0')}/${row.number('serialTotal')}';
  }

  static int cost(ToolRecord row) =>
      row.number('purchaseMinor') +
      row.number('shippingMinor') +
      row.number('buyFeeMinor');
  static int? profit(ToolRecord row) =>
      row.flag('sold') &&
          row.flag('costRecorded') &&
          row.data['saleMinor'] is int
      ? row.number('saleMinor') - row.number('sellingFeeMinor') - cost(row)
      : null;
  Future<ToolRecord> save(CollectionInput input, {ToolRecord? existing}) =>
      DataMutationGate.shared.run(() async {
        final data = input.data();
        if (existing != null && existing.kind != 'collection_card') {
          throw const ToolFailure('收藏卡类型无效。');
        }
        if (existing == null && (await all()).length >= limit) {
          throw const ToolFailure('收藏卡已达到10000张上限。');
        }
        final values = {
          ...existing?.data ??
              {
                'currency': 'CNY',
                'costRecorded': false,
                'favorite': false,
                'sold': false,
                'imageCount': 0,
              },
          ...data,
        };
        return existing == null
            ? store.create(
                'collection_card',
                input.name,
                body: input.notes,
                data: values,
              )
            : store.save(
                existing.copyWith(
                  title: input.name,
                  body: input.notes,
                  data: values,
                ),
              );
      });
  Future<ToolRecord> setCosts(
    ToolRecord row, {
    required String currency,
    required String purchase,
    String shipping = '0',
    String buyFee = '0',
    String purchaseDate = '',
    String purchaseSource = '',
    String manualValue = '',
    String manualValueSource = '用户手动输入',
    bool sold = false,
    String sale = '',
    String sellingFee = '0',
    String saleDate = '',
  }) async {
    if (row.kind != 'collection_card' ||
        purchaseSource.length > 1000 ||
        manualValueSource.length > 1000) {
      throw const ToolFailure('收藏卡或费用说明无效。');
    }
    final code = Money.currency(currency),
        price = Money.parse(purchase, currency: code),
        delivery = Money.parse(shipping, currency: code),
        fee = Money.parse(buyFee, currency: code),
        valuation = manualValue.trim().isEmpty
            ? null
            : Money.parse(manualValue, currency: code);
    if (purchaseDate.isNotEmpty) CivilTime.parse(purchaseDate, 'Asia/Shanghai');
    if (saleDate.isNotEmpty) CivilTime.parse(saleDate, 'Asia/Shanghai');
    if (sold && sale.trim().isEmpty) {
      throw const ToolFailure('标记已出售时需明确填写成交价，赠送可填0。');
    }
    final saleMinor = sold
            ? Money.parse(sale, currency: code)
            : row.data['saleMinor'],
        sellingFeeMinor = sold
            ? Money.parse(sellingFee, currency: code)
            : row.number('sellingFeeMinor');
    return store.save(
      row.copyWith(
        data: {
          ...row.data,
          'currency': code,
          'costRecorded': true,
          'purchaseMinor': price,
          'shippingMinor': delivery,
          'buyFeeMinor': fee,
          'purchaseDate': purchaseDate,
          'purchaseSource': purchaseSource,
          'manualValueMinor': valuation,
          'manualValueSource': valuation == null
              ? ''
              : manualValueSource.trim().isEmpty
              ? '用户手动输入'
              : manualValueSource,
          'manualValueAt': valuation == null
              ? ''
              : DateTime.now().toUtc().toIso8601String(),
          'sold': sold,
          'saleMinor': saleMinor,
          'sellingFeeMinor': sellingFeeMinor,
          'saleDate': saleDate,
        },
      ),
    );
  }

  Future<void> favorite(ToolRecord row, bool value) async {
    if (row.kind != 'collection_card') {
      throw const ToolFailure('收藏记录无效。');
    }
    await store.save(row.copyWith(data: {...row.data, 'favorite': value}));
  }

  Future<ToolRecord> addImage(
    ToolRecord card,
    String name,
    Uint8List bytes,
    String face,
    UtilityJobContext job,
  ) async {
    if (!collectionFaces.containsKey(face) ||
        bytes.isEmpty ||
        bytes.length > imageLimit ||
        name.length > 300) {
      throw const ToolFailure('请选择正面/背面/细节静态图片，单张最多15MiB。');
    }
    await _card(card.id);
    job.check();
    final decoder = img.findDecoderForData(bytes),
        extension = decoder is img.PngDecoder
            ? 'png'
            : decoder is img.JpegDecoder
            ? 'jpg'
            : decoder is img.WebPDecoder
            ? 'webp'
            : '';
    if (extension.isEmpty) {
      throw const ToolFailure('目前保留PNG/JPEG/WebP原图；HEIC请先通过系统另存为JPEG。');
    }
    await job.progress(0, 1, currentFile: '生成缩略图，原图字节不改写', force: true);
    final thumb = await images.preview(
      bytes,
      const ImageOptions(
        format: 'png',
        width: 320,
        height: 320,
        maintainAspect: true,
        noUpscale: true,
        stripExif: true,
      ),
    );
    job.check();
    final image = await DataMutationGate.shared.run(() async {
      final latest = await _card(card.id), prior = await imageRows(card.id);
      if (prior.length >= 12) {
        throw const ToolFailure('每张收藏卡最多12张图片，请先导出或移除不需要的副本。');
      }
      final owned = await files();
      String? originalRef, thumbRef;
      var committed = false;
      try {
        originalRef = await owned.write(
          'collection_originals',
          bytes,
          extension: extension,
        );
        job.check();
        thumbRef = await owned.write(
          'collection_thumbnails',
          thumb.bytes,
          extension: 'png',
        );
        job.check();
        final hash = await archiveHash(
              owned.resolve(originalRef),
              job.cancellation,
            ),
            thumbHash = await archiveHash(
              owned.resolve(thumbRef),
              job.cancellation,
            );
        if (hash != sha256.convert(bytes).toString() ||
            thumbHash != sha256.convert(thumb.bytes).toString()) {
          throw const ToolFailure('收藏图片写入校验失败。');
        }
        late ToolRecord result;
        await store.transaction(() async {
          var row = await store.create(
            'collection_image',
            name,
            data: {
              'payloadVersion': 1,
              'cardId': card.id,
              'face': face,
              'attachment': originalRef,
              'format': extension,
              'checksum': hash,
              'size': bytes.length,
              'thumbnailAttachment': thumbRef,
              'thumbnailWidth': thumb.width,
              'thumbnailHeight': thumb.height,
              'syncAllowed': false,
              'isSensitive': true,
            },
          );
          final thumbnail = await store.create(
            'collection_thumbnail',
            '${card.title}缩略图',
            data: {
              'payloadVersion': 1,
              'cardId': card.id,
              'imageId': row.id,
              'attachment': thumbRef,
              'checksum': thumbHash,
              'syncAllowed': false,
              'isSensitive': true,
            },
          );
          row = await store.save(
            row.copyWith(
              data: {...row.data, 'thumbnailRecordId': thumbnail.id},
            ),
          );
          result = row;
          await store.save(
            latest.copyWith(
              data: {
                ...latest.data,
                'imageCount': prior.length + 1,
                if (latest.text('coverImageId').isEmpty || face == 'front')
                  'coverImageId': row.id,
                if (latest.text('coverImageId').isEmpty || face == 'front')
                  'coverThumbnail': thumbRef,
              },
            ),
          );
        });
        committed = true;
        return result;
      } finally {
        if (!committed) {
          if (originalRef != null) await owned.remove(originalRef);
          if (thumbRef != null) await owned.remove(thumbRef);
        }
      }
    });
    await job.output(image.id);
    await job.progress(1, 1, currentFile: name, force: true);
    return image;
  }

  Future<void> _idle(String cardId) async {
    for (final job in await store.list('utility_job', limit: 10000)) {
      if (!utilityJobStatus(job).terminal &&
          (job.data['inputReferences'] as Map?)?['cardId'] == cardId) {
        throw const ToolFailure('此卡片仍有图片任务，请先等待或取消。');
      }
    }
  }

  Future<void> removeImage(ToolRecord image, {required bool confirmed}) async {
    if (!confirmed || image.kind != 'collection_image') {
      throw const ToolFailure('移除图片副本需要确认。');
    }
    await _idle(image.text('cardId'));
    await DataMutationGate.shared.run(() async {
      final latest = await store.get(image.id);
      if (latest?.kind != 'collection_image') {
        throw const ToolFailure('图片已不存在。');
      }
      final card = await _card(latest!.text('cardId')),
          thumb = await store.get(latest.text('thumbnailRecordId')),
          remaining = (await imageRows(card.id))
              .where((r) => r.id != latest.id)
              .toList();
      if (thumb != null &&
          (thumb.kind != 'collection_thumbnail' ||
              thumb.text('imageId') != latest.id ||
              thumb.text('cardId') != card.id)) {
        throw const ToolFailure('缩略图关联异常，未移除文件。');
      }
      await store.transaction(() async {
        if (thumb != null) await store.delete(thumb);
        await store.delete(latest);
        final cover =
            remaining.where((r) => r.text('face') == 'front').firstOrNull ??
            remaining.firstOrNull;
        await store.save(
          card.copyWith(
            data: {
              ...card.data,
              'imageCount': remaining.length,
              'coverImageId': cover?.id ?? '',
              'coverThumbnail': cover?.text('thumbnailAttachment') ?? '',
            },
          ),
        );
      });
      final owned = await files();
      await owned.remove(latest.text('attachment'));
      if (thumb != null) await owned.remove(thumb.text('attachment'));
    });
  }

  Future<void> remove(ToolRecord card, {required bool confirmed}) async {
    if (!confirmed || card.kind != 'collection_card') {
      throw const ToolFailure('移除卡片及其应用内图片副本需要确认。');
    }
    await _idle(card.id);
    await DataMutationGate.shared.run(() async {
      final latest = await _card(card.id),
          photos = await imageRows(card.id),
          thumbs = <ToolRecord>[];
      for (final photo in photos) {
        final thumb = await store.get(photo.text('thumbnailRecordId'));
        if (thumb != null) {
          if (thumb.kind != 'collection_thumbnail' ||
              thumb.text('imageId') != photo.id ||
              thumb.text('cardId') != card.id) {
            throw const ToolFailure('图片关联异常，未移除卡片。');
          }
          thumbs.add(thumb);
        }
      }
      await store.transaction(() async {
        for (final row in [...photos, ...thumbs]) {
          await store.delete(row);
        }
        await store.delete(latest);
      });
      final owned = await files();
      for (final row in [...photos, ...thumbs]) {
        await owned.remove(row.text('attachment'));
      }
    });
  }

  static bool matches(
    ToolRecord card,
    String query, {
    String type = '',
    bool favoritesOnly = false,
    String state = 'all',
  }) {
    if (type.isNotEmpty && card.text('collectionType') != type ||
        favoritesOnly && !card.flag('favorite') ||
        state == 'owned' && card.flag('sold') ||
        state == 'sold' && !card.flag('sold')) {
      return false;
    }
    return '${card.title} ${card.body} ${card.text('playerOrCharacter')} ${card.text('brand')} ${card.text('series')} ${card.text('year')} ${card.text('cardNumber')} ${serial(card)} ${card.text('parallel')} ${card.text('memorabiliaType')} ${card.strings('tags').join(' ')}'
        .toLowerCase()
        .contains(query.toLowerCase());
  }

  Future<ToolRecord> prepareExport(
    List<ToolRecord> cards,
    UtilityJobContext job,
  ) async {
    final estimate = cards.fold<int>(
      1024,
      (n, r) =>
          n +
          (r.title.length +
                  r.body.length +
                  r.data.values.whereType<String>().fold<int>(
                    0,
                    (s, v) => s + v.length,
                  )) *
              3 +
          1000,
    );
    if (estimate > 20 * 1024 * 1024) {
      throw const ToolFailure('本次CSV报表超过20MiB安全上限，请按分类或状态缩小范围。');
    }
    final text = await Isolate.run(_CollectionCsvWork(cards).call);
    job.check();
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > 20 * 1024 * 1024) {
      throw const ToolFailure('CSV报表超过20MiB，请缩小筛选范围。');
    }
    return DataMutationGate.shared.run(() async {
      final owned = await files(),
          attachment = await (await files()).write(
            'collection_exports',
            bytes,
            extension: 'csv',
          );
      ToolRecord? row;
      try {
        job.check();
        final hash = await archiveHash(
          owned.resolve(attachment),
          job.cancellation,
        );
        if (hash != sha256.convert(bytes).toString()) {
          throw const ToolFailure('CSV附件校验失败。');
        }
        row = await store.create(
          'collection_export',
          '收藏卡CSV报表',
          data: {
            'payloadVersion': 1,
            'attachment': attachment,
            'checksum': hash,
            'size': bytes.length,
            'cardCount': cards.length,
            'status': 'prepared',
            'syncAllowed': false,
            'isSensitive': true,
          },
        );
        await job.output(row.id);
        return row;
      } catch (_) {
        if (row == null) await owned.remove(attachment);
        rethrow;
      }
    });
  }

  static String exportCsv(List<ToolRecord> cards) {
    String safe(String value) =>
        RegExp(r'^[\s]*[=+@\-\t\r]').hasMatch(value) || value.startsWith("'")
        ? "'$value"
        : value;
    String amount(ToolRecord r, String field) => r.data[field] is int
        ? Money.format(r.number(field), currency: r.text('currency', 'CNY'))
        : '';
    return '\ufeff${csv.encode([
      ['name', 'collectionType', 'playerOrCharacter', 'brand', 'series', 'year', 'cardNumber', 'serialNumber', 'serialTotal', 'serialNote', 'parallel', 'memorabiliaType', 'memorabiliaEvidence', 'gradeCompany', 'grade', 'currency', 'purchasePrice', 'shipping', 'buyFee', 'totalCost', 'manualValue', 'manualValueSource', 'sold', 'salePrice', 'sellingFee', 'realizedProfit', 'purchaseDate', 'purchaseSource', 'notes', 'imageCount'],
      for (final r in cards) [safe(r.title), safe(r.text('collectionType')), safe(r.text('playerOrCharacter')), safe(r.text('brand')), safe(r.text('series')), safe(r.text('year')), safe(r.text('cardNumber')), r.data['serialNumber'] ?? '', r.data['serialTotal'] ?? '', safe(r.text('serialNote')), safe(r.text('parallel')), r.text('memorabiliaType'), safe(r.text('memorabiliaEvidence')), safe(r.text('gradeCompany')), safe(r.text('grade')), r.text('currency', 'CNY'), amount(r, 'purchaseMinor'), amount(r, 'shippingMinor'), amount(r, 'buyFeeMinor'), r.flag('costRecorded') ? Money.format(cost(r), currency: r.text('currency')) : '', amount(r, 'manualValueMinor'), safe(r.text('manualValueSource')), r.flag('sold'), amount(r, 'saleMinor'), amount(r, 'sellingFeeMinor'), profit(r) == null ? '' : Money.format(profit(r)!, currency: r.text('currency')), r.text('purchaseDate'), safe(r.text('purchaseSource')), safe(r.body), r.number('imageCount')],
    ])}';
  }
}

class CollectionSummary {
  CollectionSummary(List<ToolRecord> cards) {
    for (final card in cards) {
      if (card.flag('sold')) {
        sold++;
      } else {
        owned++;
      }
      final code = card.text('currency', 'CNY');
      if (card.flag('costRecorded')) {
        priced++;
        costs[code] = _add(costs[code] ?? 0, CollectionService.cost(card));
        if (!card.flag('sold')) {
          ownedCosts[code] = _add(
            ownedCosts[code] ?? 0,
            CollectionService.cost(card),
          );
        }
      }
      final profit = CollectionService.profit(card);
      if (profit != null) realized[code] = _add(realized[code] ?? 0, profit);
    }
  }
  int owned = 0, sold = 0, priced = 0;
  final costs = <String, int>{},
      ownedCosts = <String, int>{},
      realized = <String, int>{};
  static int _add(int a, int b) {
    final sum = a + b;
    if (sum.abs() > 9000000000000000) {
      throw const ToolFailure('收藏金额汇总超出安全范围，请缩小筛选范围。');
    }
    return sum;
  }
}

class _CollectionCsvWork {
  const _CollectionCsvWork(this.cards);
  final List<ToolRecord> cards;
  String call() => CollectionService.exportCsv(cards);
}
