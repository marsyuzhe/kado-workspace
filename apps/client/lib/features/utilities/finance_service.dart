import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:drift/drift.dart';

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import '../archive/archive_service.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/data_mutation_gate.dart';
import '../../core/storage/utility_files.dart';
import 'bill_reader.dart';
import 'civil_time.dart';
import 'money.dart';

const financeTypes = {'income', 'expense', 'transfer', 'refund', 'void'};
const financeCategories = [
  '餐饮',
  '交通',
  '购物',
  '数码',
  '娱乐',
  '学习',
  '旅行',
  '住房',
  '其他',
];
const financeAliases = <String, List<String>>{
  'date': [
    '日期',
    '交易时间',
    '交易创建时间',
    '付款时间',
    '记账时间',
    'date',
    'transactiondate',
    'time',
  ],
  'amount': ['金额', '金额(元)', '交易金额', 'amount'],
  'type': ['收/支', '收支', '收入/支出', '收支类型', 'type', '交易类型'],
  'transactionId': ['交易单号', '交易订单号', '交易号', 'transactionid', '订单号'],
  'relatedTransactionId': ['原交易单号', '原交易号', '退款关联交易号', 'relatedtransactionid'],
  'merchant': ['交易对方', '商户名称', '商户', 'merchant'],
  'category': ['交易分类', '分类', 'category'],
  'paymentMethod': ['支付方式', '收/付款方式', '收付款方式', '付款方式', 'paymentmethod'],
  'description': ['商品', '商品名称', '商品说明', '备注', 'description'],
  'status': ['交易状态', '当前状态', 'status'],
  'currency': ['币种', 'currency'],
};
String _normalHeader(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'[\s\ufeff()（）元]'), '');

class FinanceMapping {
  const FinanceMapping(
    this.columns, {
    this.headerRow = 0,
    this.endRow,
    this.source = 'csv',
    this.currency = 'CNY',
    this.zone = 'Asia/Shanghai',
    this.typesByRow = const {},
    this.defaultType = '',
  });
  final Map<String, int> columns;
  final int headerRow;
  final int? endRow;
  final String source, currency, zone, defaultType;
  final Map<int, String> typesByRow;
  static Map<String, int> matchHeader(List<String> row) {
    final found = <String, int>{};
    for (final field in financeAliases.entries) {
      for (final alias in field.value) {
        final index = row.indexWhere(
          (s) => _normalHeader(s) == _normalHeader(alias),
        );
        if (index >= 0) {
          found[field.key] = index;
          break;
        }
      }
    }
    return found;
  }

  static FinanceMapping detect(BillTable table, {String source = 'csv'}) {
    var best = <String, int>{}, header = 0;
    for (var row = 0; row < table.rows.length && row < 50; row++) {
      final found = matchHeader(table.rows[row]);
      if (found.length > best.length) {
        best = found;
        header = row;
      }
    }
    return FinanceMapping(best, headerRow: header, source: source);
  }

  Map<String, dynamic> toJson() => {
    'columns': columns,
    'headerRow': headerRow,
    'endRow': endRow,
    'source': source,
    'currency': currency,
    'zone': zone,
    'defaultType': defaultType,
    'typesByRow': {for (final e in typesByRow.entries) '${e.key}': e.value},
  };
}

class FinanceService {
  FinanceService(this.store, this.files);
  final RecordStore store;
  final UtilityFileService files;
  static const ledgerLimit = 50000;
  SimpleSelectStatement<$LocalRecordsTable, LocalRecord> _query() =>
      store.db.select(store.db.localRecords)
        ..where(
          (t) => t.kind.equals('finance_transaction') & t.deletedAt.isNull(),
        )
        ..orderBy([
          (t) => OrderingTerm.desc(
            const CustomExpression<String>("json_extract(data, '\$.date')"),
          ),
          (t) => OrderingTerm.desc(t.updatedAt),
        ])
        ..limit(ledgerLimit + 1);
  List<ToolRecord> _rows(Iterable<LocalRecord> rows) {
    final list = rows.map((r) => ToolRecord.fromRow(r)).toList();
    if (list.length > ledgerLimit) {
      throw const ToolFailure('交易超过本版50000条统计上限，请先导出并分期管理。');
    }
    return list;
  }

  Future<List<ToolRecord>> all() async => _rows(await _query().get());
  Stream<List<ToolRecord>> watch() => _query().watch().map(_rows);
  static String typeLabel(String type) =>
      const {
        'income': '收入',
        'expense': '支出',
        'transfer': '内部转账/不计收支',
        'refund': '退款',
        'void': '撤销/未完成',
      }[type] ??
      type;
  static String direction(String raw, String status) {
    final value = raw.trim().toLowerCase(), state = status.trim();
    if ([
      '交易关闭',
      '已关闭',
      '已撤销',
      '已全额退款',
      '支付失败',
      '付款失败',
      '已退回',
      '待付款',
      '待收款',
      '退款中',
    ].any(state.contains)) {
      return 'void';
    }
    if ({'退款', '退货退款', 'refund'}.contains(value)) return 'refund';
    if (state.contains('退款')) {
      throw const ToolFailure('退款状态含义需复核，请为此行明确选择退款或撤销类型。');
    }
    if ({'收入', 'income', '入账'}.contains(value)) return 'income';
    if ({'支出', 'expense', '付款'}.contains(value)) return 'expense';
    if ({'内部转账', 'transfer', '不计收支', '中性交易', '/'}.contains(value)) {
      return 'transfer';
    }
    if ({'撤销', 'void', '取消'}.contains(value)) return 'void';
    throw const ToolFailure('收支方向不明确；不把所有“转账”自动当作内部互转。');
  }

  static Map<String, dynamic> entry({
    required String date,
    required String amount,
    required String type,
    String currency = 'CNY',
    String zone = 'Asia/Shanghai',
    String transactionId = '',
    String relatedTransactionId = '',
    String merchant = '',
    String category = '其他',
    String paymentMethod = '',
    String description = '',
    String source = 'manual',
    String status = '',
    bool excelDate = false,
    bool date1904 = false,
  }) {
    if (!financeTypes.contains(type) ||
        !{'manual', 'csv', 'alipay', 'wechat'}.contains(source)) {
      throw const ToolFailure('交易类型或来源无效。');
    }
    if (RegExp(r'^[+-]?\d+(?:\.\d+)?[eE][+-]?\d+$')
        .hasMatch(transactionId.trim())) {
      throw const ToolFailure('交易ID为科学计数法，可能已丢失精度；请用文本格式重新导出ID。');
    }
    final code = Money.currency(currency),
        instant = CivilTime.parse(
          date,
          zone,
          excel: excelDate,
          date1904: date1904,
        ),
        minor = Money.parse(amount, currency: code);
    if ([transactionId, relatedTransactionId].any((v) => v.length > 200) ||
        merchant.length > 300 ||
        category.length > 100 ||
        paymentMethod.length > 100 ||
        description.length > 4000 ||
        status.length > 200) {
      throw const ToolFailure('交易字段超出长度限制。');
    }
    return {
      'date': instant.toIso8601String(),
      'dateLocal': CivilTime.format(instant, zone),
      'zone': zone,
      'type': type,
      'amountMinor': minor,
      'currency': code,
      'transactionId': transactionId.trim(),
      'relatedTransactionId': relatedTransactionId.trim(),
      'merchant': merchant.trim(),
      'category': category.trim().isEmpty ? '其他' : category.trim(),
      'paymentMethod': paymentMethod.trim(),
      'description': description,
      'source': source,
      'sourceStatus': status,
      'isTransfer': type == 'transfer',
      'isRefund': type == 'refund',
      'payloadVersion': 1,
      'syncAllowed': false,
      'isSensitive': true,
    };
  }

  static String key(Map<String, dynamic> e) {
    final id = e['transactionId'] as String;
    final stable = id.isNotEmpty
        ? [
            e['source'],
            id,
            e['currency'],
            e['type'] == 'refund' ? 'refund' : 'primary',
          ]
        : [
            e['source'],
            e['dateLocal'],
            e['zone'],
            e['amountMinor'],
            e['currency'],
            e['type'],
            e['merchant'],
            e['paymentMethod'],
            e['description'],
          ];
    return sha256.convert(utf8.encode(jsonEncode(stable))).toString();
  }

  static bool _unlinkedVoid(
    Map<String, dynamic> entry,
    Map<String, ToolRecord> prior,
  ) =>
      entry['type'] == 'void' &&
      (entry['transactionId'] as String).isEmpty &&
      [
        'income',
        'expense',
        'transfer',
      ].any((type) => prior.containsKey(key({...entry, 'type': type})));

  Future<BillTable> read(
    Uint8List bytes,
    String name, {
    String? sheet,
    String encoding = 'auto',
  }) => Isolate.run(
    () => BillReader.read(bytes, name, sheet: sheet, encoding: encoding),
  );
  Stream<List<ToolRecord>> watchPreviewSummaries() => store.db
      .customSelect(
        "SELECT id,kind,title,body,json_remove(data,'\$.entries','\$.errors') AS data,created_at,updated_at,revision,device_id,deleted_at,sync_status FROM local_records WHERE kind='finance_preview' AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 30",
        readsFrom: {store.db.localRecords},
      )
      .watch()
      .map(
        (rows) => rows
            .map(
              (row) => ToolRecord.fromRow(store.db.localRecords.map(row.data)),
            )
            .toList(),
      );
  Future<ToolRecord> preview(
    BillTable table,
    FinanceMapping mapping,
    String fileName,
    UtilityJobContext job,
  ) async {
    if (mapping.headerRow < 0 ||
        mapping.headerRow >= table.rows.length ||
        !mapping.columns.keys.toSet().containsAll(['date', 'amount']) ||
        (!mapping.columns.containsKey('type') &&
            !financeTypes.contains(mapping.defaultType)) ||
        mapping.columns.values.any((v) => v < 0 || v >= 64)) {
      throw const ToolFailure('请映射日期、金额，并映射收支方向或明确选择固定类型。');
    }
    Money.currency(mapping.currency);
    CivilTime.location(mapping.zone);
    final end = mapping.endRow ?? table.rows.length;
    if (end <= mapping.headerRow ||
        end > table.rows.length ||
        end - mapping.headerRow > 10001) {
      throw const ToolFailure('数据起止范围无效，单次最多10000条交易。');
    }
    final entries = <Map<String, dynamic>>[], errors = <Map<String, dynamic>>[];
    var ignored = 0;
    for (var i = mapping.headerRow + 1; i < end; i++) {
      job.check();
      final row = table.rows[i];
      String value(String field) {
        final index = mapping.columns[field];
        return index == null || index >= row.length ? '' : row[index].trim();
      }

      if (row.every((v) => v.trim().isEmpty) ||
          row
              .where((v) => v.trim().isNotEmpty)
              .every((v) => RegExp(r'^[-=—]+$').hasMatch(v.trim()))) {
        ignored++;
        continue;
      }
      try {
        final type =
            mapping.typesByRow[i] ??
            direction(
              mapping.columns.containsKey('type')
                  ? value('type')
                  : mapping.defaultType,
              value('status'),
            );
        final parsed = entry(
          date: value('date'),
          amount: value('amount'),
          type: type,
          currency: value('currency').isEmpty
              ? mapping.currency
              : value('currency'),
          zone: mapping.zone,
          transactionId: value('transactionId'),
          relatedTransactionId: value('relatedTransactionId'),
          merchant: value('merchant'),
          category: value('category'),
          paymentMethod: value('paymentMethod'),
          description: value('description'),
          source: mapping.source,
          status: value('status'),
          excelDate: table.xlsx,
          date1904: table.excelDate1904,
        );
        entries.add({
          ...parsed,
          'sourceRow': i + 1,
          'dedupKey': key(parsed),
          'dedupMethod': value('transactionId').isEmpty
              ? 'stable-fields'
              : 'source-id',
        });
      } on ToolFailure catch (error) {
        errors.add({'row': i + 1, 'message': error.message});
      }
      if (i % 50 == 0) {
        await job.progress(
          i - mapping.headerRow,
          end - mapping.headerRow - 1,
          currentFile: '解析账单行（仅记录行号和数量）',
        );
      }
    }
    final existing = {for (final row in await all()) row.text('dedupKey'): row},
        seen = <String>{};
    var duplicates = 0, updates = 0;
    for (final e in entries) {
      if (_unlinkedVoid(e, existing)) {
        errors.add({
          'row': e['sourceRow'],
          'message': '撤销记录缺少交易ID，不能安全关联旧交易；请人工核对并修改原记录。',
        });
      }
      final k = e['dedupKey'] as String, old = existing[k];
      if (!seen.add(k)) {
        duplicates++;
        continue;
      }
      if (old != null) {
        if (old.text('type') != 'void' && e['type'] == 'void') {
          updates++;
        } else {
          duplicates++;
        }
      }
    }
    final result = await store.create(
      'finance_preview',
      '账单字段映射预览',
      data: {
        'fileName': fileName,
        'mapping': mapping.toJson(),
        'sheet': table.sheet,
        'payloadVersion': 1,
        'validCount': entries.length,
        'errorCount': errors.length,
        'entries': entries,
        'errors': errors,
        'ignoredRows': ignored,
        'duplicates': duplicates,
        'statusUpdates': updates,
        'status': 'preview',
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(result.id);
    return result;
  }

  Future<ToolRecord> importPreview(
    ToolRecord preview,
    UtilityJobContext job, {
    required bool confirmed,
  }) async {
    if (!confirmed || preview.kind != 'finance_preview') {
      throw const ToolFailure('账单导入必须先预览并确认。');
    }
    final current = await store.get(preview.id);
    if (current == null ||
        current.revision != preview.revision ||
        current.text('status') != 'preview') {
      throw const ToolFailure('预览已变化或已导入，请重新核对。');
    }
    final errors = preview.data['errors'] as List,
        entries = List<Map<String, dynamic>>.from(
          (preview.data['entries'] as List).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
    if (errors.isNotEmpty || entries.isEmpty || entries.length > 10000) {
      throw const ToolFailure('预览含错误行、为空或超过10000条；请修正映射/范围或逐行类型后重新预览。');
    }
    var batch = await store.create(
      'finance_batch',
      '账单导入批次',
      data: {
        'previewId': preview.id,
        'status': 'processing',
        'jobId': job.id,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
    await job.output(batch.id);
    await job.progress(
      0,
      entries.length,
      currentFile: '原子写入交易；取消会回滚本批未提交记录',
      force: true,
    );
    var imported = 0, duplicate = 0, updated = 0;
    try {
      await DataMutationGate.shared.run(
        () => store.transaction(() async {
          final prior = {
            for (final row in await all()) row.text('dedupKey'): row,
          };
          if (prior.length +
                  entries
                      .map(key)
                      .where((k) => !prior.containsKey(k))
                      .toSet()
                      .length >
              ledgerLimit) {
            throw const ToolFailure('本批加现有交易超过50000条上限，请拆分或先导出管理。');
          }
          for (final entry in entries) {
            job.check();
            if (_unlinkedVoid(entry, prior)) {
              throw const ToolFailure('撤销记录无法安全关联旧交易，请人工核对原记录。');
            }
            final dedup = key(entry);
            if (dedup != entry['dedupKey']) {
              throw const ToolFailure('预览数据变化，请重新解析。');
            }
            final old = prior[dedup];
            if (old != null) {
              if (old.text('type') != 'void' && entry['type'] == 'void') {
                if (old.flag('manuallyEdited')) {
                  throw const ToolFailure('已手工修改的交易遇到来源状态更新，未自动覆盖，请先核对。');
                }
                if (old.number('amountMinor') != entry['amountMinor'] ||
                    old.text('dateLocal') != entry['dateLocal']) {
                  throw const ToolFailure('相同交易ID的日期或金额冲突，未自动合并。');
                }
                final saved = await store.save(
                  old.copyWith(
                    data: {
                      ...old.data,
                      'type': 'void',
                      'isTransfer': false,
                      'isRefund': false,
                      'sourceStatus': entry['sourceStatus'],
                      'statusUpdatedByBatch': batch.id,
                    },
                  ),
                );
                prior[dedup] = saved;
                updated++;
              } else {
                if (old.text('type') != 'void' &&
                    old.text('type') != entry['type']) {
                  throw const ToolFailure('相同交易ID的收支方向冲突，请人工核对。');
                }
                if (old.number('amountMinor') != entry['amountMinor'] ||
                    old.text('dateLocal') != entry['dateLocal']) {
                  throw const ToolFailure('相同交易ID的金额或日期冲突；未按金额相同擅自去重。');
                }
                duplicate++;
              }
              continue;
            }
            final created = await store.create(
              'finance_transaction',
              (entry['merchant'] as String).isEmpty
                  ? '账单交易'
                  : entry['merchant'] as String,
              body: entry['description'] as String,
              data: {...entry, 'importBatchId': batch.id},
            );
            prior[dedup] = created;
            imported++;
          }
          job.check();
          batch = await store.save(
            batch.copyWith(
              data: {
                ...batch.data,
                'status': 'complete',
                'imported': imported,
                'duplicates': duplicate,
                'updated': updated,
              },
            ),
          );
          await store.save(
            current.copyWith(
              data: {
                ...current.data,
                'status': 'imported',
                'importBatchId': batch.id,
              },
            ),
          );
        }),
      );
      await job.progress(
        entries.length,
        entries.length,
        currentFile: '导入已提交；没有把完整交易写入日志',
        force: true,
      );
      return batch;
    } catch (error) {
      final latest = await store.get(batch.id);
      if (latest != null && latest.text('status') != 'complete') {
        await store.save(
          latest.copyWith(
            data: {
              ...latest.data,
              'status': job.cancellation.cancelled ? 'cancelled' : 'failed',
              'error': '本批未提交写入已回滚；原有交易保留。',
            },
          ),
        );
      }
      rethrow;
    }
  }

  Future<ToolRecord> saveEntry(
    Map<String, dynamic> data, {
    ToolRecord? existing,
  }) async {
    final valid = entry(
      date: data['dateLocal'] as String,
      amount: Money.format(
        data['amountMinor'] as int,
        currency: data['currency'] as String,
      ),
      type: data['type'] as String,
      currency: data['currency'] as String,
      zone: data['zone'] as String,
      transactionId: data['transactionId'] as String? ?? '',
      relatedTransactionId: data['relatedTransactionId'] as String? ?? '',
      merchant: data['merchant'] as String? ?? '',
      category: data['category'] as String? ?? '其他',
      paymentMethod: data['paymentMethod'] as String? ?? '',
      description: data['description'] as String? ?? '',
      source: data['source'] as String? ?? 'manual',
      status: data['sourceStatus'] as String? ?? '',
    );
    if (existing != null && existing.kind != 'finance_transaction') {
      throw const ToolFailure('交易记录无效。');
    }
    return DataMutationGate.shared.run(() async {
      if (existing == null && (await all()).length >= ledgerLimit) {
        throw const ToolFailure('已达到50000条交易上限。');
      }
      final payload = {
        ...existing?.data ?? {},
        ...valid,
        'dedupKey': existing?.text('dedupKey') ?? 'manual:${newId()}',
        'manuallyEdited': existing != null,
        'importBatchId': existing?.text('importBatchId') ?? '',
      };
      final title = (valid['merchant'] as String).isEmpty
          ? '手动交易'
          : valid['merchant'] as String;
      return existing == null
          ? store.create(
              'finance_transaction',
              title,
              body: valid['description'] as String,
              data: payload,
            )
          : store.save(
              existing.copyWith(
                title: title,
                body: valid['description'] as String,
                data: payload,
              ),
            );
    });
  }

  Future<void> remove(ToolRecord row, {required bool confirmed}) async {
    if (!confirmed || row.kind != 'finance_transaction') {
      throw const ToolFailure('删除交易需要确认。');
    }
    await store.delete(row);
  }

  Future<ToolRecord> budget(
    String month,
    String currency,
    String category,
    int amount,
  ) async {
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month) ||
        category.length > 100 ||
        amount < 0 ||
        amount > 900000000000000) {
      throw const ToolFailure('预算月份、分类或金额无效。');
    }
    final code = Money.currency(currency), key = '$month|$code|$category';
    return DataMutationGate.shared.run(() async {
      final old = await store.find('finance_budget', 'budgetKey', key),
          data = {
            'month': month,
            'currency': code,
            'category': category,
            'amountMinor': amount,
            'budgetKey': key,
            'syncAllowed': false,
            'isSensitive': true,
          };
      return old == null
          ? store.create('finance_budget', '$month预算', data: data)
          : store.save(old.copyWith(data: data));
    });
  }

  Future<ToolRecord> preparePortableExport(
    List<ToolRecord> rows,
    UtilityJobContext job,
  ) async {
    final estimate = rows.fold<int>(
      1024,
      (n, r) => n + (r.body.length + r.title.length + 1000) * 4,
    );
    if (estimate > 20 * 1024 * 1024) {
      throw const ToolFailure('移动报表安全上限20MiB，请按月份、币种或商户缩小筛选范围。');
    }
    final text = await Isolate.run(_FinanceCsvWork(rows).call);
    job.check();
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > 20 * 1024 * 1024) {
      throw const ToolFailure('移动报表超过20MiB，请缩小筛选范围。');
    }
    final owned = await files.files();
    return DataMutationGate.shared.run(() async {
      final attachment = await owned.write(
        'finance_exports',
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
          throw const ToolFailure('报表附件校验失败。');
        }
        row = await store.create(
          'finance_export',
          '待系统保存的本地CSV报表',
          data: {
            'payloadVersion': 1,
            'attachment': attachment,
            'checksum': hash,
            'size': bytes.length,
            'rowCount': rows.length,
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

  Future<ToolRecord> exportRows(
    List<ToolRecord> rows,
    String directory,
    UtilityJobContext job,
  ) async {
    final root = await files.selectedDirectory(directory);
    final estimate = rows.fold<int>(
      1024,
      (n, r) => n + (r.body.length + r.title.length + 1000) * 4,
    );
    await files.ensureSpace(root.path, estimate);
    final file = File(p.join(root.path, 'Links-finance-${newId()}.csv'));
    await file.create(exclusive: true);
    final sink = file.openWrite();
    var complete = false, closed = false;
    try {
      sink.add([0xef, 0xbb, 0xbf]);
      var count = 0;
      for (final row in _csvRows(rows)) {
        job.check();
        sink.add(utf8.encode('${csv.encode([row])}\r\n'));
        if (count++ % 100 == 0) {
          await sink.flush();
          await job.progress(
            (count - 1).clamp(0, rows.length),
            rows.length,
            currentFile: '写入本地CSV报表',
          );
        }
      }
      await sink.close();
      closed = true;
      job.check();
      final hash = await archiveHash(file, job.cancellation);
      final record = await store.create(
        'finance_export',
        '本地交易CSV报表',
        data: {
          'outputPath': file.path,
          'checksum': hash,
          'size': await file.length(),
          'rowCount': rows.length,
          'syncAllowed': false,
          'isSensitive': true,
        },
      );
      complete = true;
      await job.output(record.id);
      return record;
    } finally {
      if (!closed) await sink.close();
      if (!complete && await file.exists()) await file.delete();
    }
  }

  static Iterable<List<dynamic>> _csvRows(List<ToolRecord> rows) sync* {
    String safe(String value) =>
        RegExp(r'^[\s]*[=+@\-\t\r]').hasMatch(value) || value.startsWith("'")
        ? "'$value"
        : value;
    yield [
      'date',
      'type',
      'amount',
      'currency',
      'category',
      'merchant',
      'paymentMethod',
      'description',
      'source',
      'transactionId',
      'relatedTransactionId',
    ];
    for (final r in rows) {
      yield [
        r.text('dateLocal'),
        r.text('type'),
        Money.format(r.number('amountMinor'), currency: r.text('currency')),
        r.text('currency'),
        safe(r.text('category')),
        safe(r.text('merchant')),
        safe(r.text('paymentMethod')),
        safe(r.body),
        r.text('source'),
        safe(r.text('transactionId')),
        safe(r.text('relatedTransactionId')),
      ];
    }
  }

  static String exportTransactions(List<ToolRecord> rows) =>
      '\ufeff${csv.encode(_csvRows(rows).toList())}';
}

class FinanceReport {
  const FinanceReport(
    this.income,
    this.expense,
    this.refunds,
    this.netExpense,
    this.categories,
    this.merchants,
    this.trends,
    this.count,
  );
  final int income, expense, refunds, netExpense, count;
  final Map<String, int> categories, merchants;
  final Map<String, ({int income, int expense, int refunds})> trends;
  int get balance => income - netExpense;
  static int _add(int a, int b) {
    final value = a + b;
    if (value.abs() > 9000000000000000) {
      throw const ToolFailure('金额汇总超出安全范围，请缩小报表范围。');
    }
    return value;
  }

  static FinanceReport calculate(
    List<ToolRecord> ledger,
    String currency, {
    String month = '',
    int? year,
  }) {
    Money.currency(currency);
    if (month.isNotEmpty &&
        !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) {
      throw const ToolFailure('报表月份无效。');
    }
    final voidIds = ledger
        .where(
          (r) => r.text('type') == 'void' && r.text('transactionId').isNotEmpty,
        )
        .map(
          (r) =>
              '${r.text('source')}|${r.text('currency')}|${r.text('transactionId')}',
        )
        .toSet();
    var income = 0, expense = 0, refunds = 0, appliedRefunds = 0, count = 0;
    final categories = <String, int>{},
        merchants = <String, int>{},
        trends = <String, ({int income, int expense, int refunds})>{};
    for (final r in ledger) {
      final civil = r.text('dateLocal');
      if (r.text('currency') != currency ||
          civil.length < 10 ||
          (month.isNotEmpty && !civil.startsWith(month)) ||
          (year != null && !civil.startsWith('$year-'))) {
        continue;
      }
      count++;
      final amount = r.number('amountMinor'),
          type = r.text('type'),
          key = civil.substring(0, 7),
          trend = trends[key] ?? (income: 0, expense: 0, refunds: 0);
      if (type == 'income') {
        income = _add(income, amount);
        trends[key] = (
          income: _add(trend.income, amount),
          expense: trend.expense,
          refunds: trend.refunds,
        );
      }
      if (type == 'expense') {
        expense = _add(expense, amount);
        categories[r.text('category')] = _add(
          categories[r.text('category')] ?? 0,
          amount,
        );
        merchants[r.title] = _add(merchants[r.title] ?? 0, amount);
        trends[key] = (
          income: trend.income,
          expense: _add(trend.expense, amount),
          refunds: trend.refunds,
        );
      }
      if (type == 'refund') {
        refunds = _add(refunds, amount);
        final related = r.text('relatedTransactionId').isEmpty
                ? r.text('transactionId')
                : r.text('relatedTransactionId'),
            alreadyVoided =
                related.isNotEmpty &&
                voidIds.contains('${r.text('source')}|$currency|$related');
        if (!alreadyVoided) {
          appliedRefunds = _add(appliedRefunds, amount);
          categories[r.text('category')] = _add(
            categories[r.text('category')] ?? 0,
            -amount,
          );
          merchants[r.title] = _add(merchants[r.title] ?? 0, -amount);
          trends[key] = (
            income: trend.income,
            expense: trend.expense,
            refunds: _add(trend.refunds, amount),
          );
        }
      }
    }
    return FinanceReport(
      income,
      expense,
      refunds,
      expense - appliedRefunds,
      categories,
      merchants,
      trends,
      count,
    );
  }
}

// A sendable callable keeps the database/job context out of an isolate closure.
class _FinanceCsvWork {
  const _FinanceCsvWork(this.rows);
  final List<ToolRecord> rows;
  String call() => FinanceService.exportTransactions(rows);
}
