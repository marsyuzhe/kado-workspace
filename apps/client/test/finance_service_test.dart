import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/features/utilities/civil_time.dart';
import 'package:links_toolbox/features/utilities/finance_service.dart';

import 'bill_reader_test.dart' show billXlsx;

class PausingFinanceStore extends RecordStore {
  PausingFinanceStore(super.db);
  bool pause = false;
  final reached = Completer<void>(), release = Completer<void>();
  @override
  Future<ToolRecord> create(
    String kind,
    String title, {
    String body = '',
    Map<String, dynamic> data = const {},
  }) async {
    final row = await super.create(kind, title, body: body, data: data);
    if (kind == 'finance_transaction' && pause && !reached.isCompleted) {
      reached.complete();
      await release.future;
    }
    return row;
  }
}

const headers = [
  '交易时间',
  '收/支',
  '金额(元)',
  '交易对方',
  '交易单号',
  '当前状态',
  '分类',
  '原交易单号',
  '备注',
];
List<String> transaction(
  String date,
  String type,
  String amount,
  String merchant,
  String id, {
  String status = '交易成功',
  String category = '其他',
  String related = '',
  String note = '',
}) => [date, type, amount, merchant, id, status, category, related, note];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late PausingFinanceStore store;
  late UtilityJobEngine jobs;
  late FinanceService finance;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-finance-test-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = PausingFinanceStore(db);
    jobs = UtilityJobEngine(JobQueueRepository(store));
    finance = FinanceService(
      store,
      UtilityFileService(store, () async => OwnedFileStore(temp)),
    );
  });
  tearDown(() async {
    if (!store.release.isCompleted) store.release.complete();
    await jobs.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ToolRecord> execute(String operation, UtilityJobHandler action) async {
    final submitted = await jobs.submit(
      'finance',
      operation,
      operation,
      {},
      confirmed: true,
      run: action,
    );
    return jobs.waitFor(submitted.id);
  }

  Future<ToolRecord> output(ToolRecord job) async {
    expect(
      utilityJobStatus(job),
      UtilityJobStatus.succeeded,
      reason: job.text('errorMessage'),
    );
    return (await store.get(job.text('resultReference')))!;
  }

  Future<ToolRecord> preview(
    List<List<String>> records, {
    String source = 'wechat',
  }) async {
    final table = await finance.read(
      Uint8List.fromList(
        utf8.encode('本应用脱敏测试账单\n${csv.encode([headers, ...records])}'),
      ),
      'owned-bill.csv',
    );
    final mapping = FinanceMapping.detect(table, source: source);
    expect(mapping.headerRow, 1);
    return output(
      await execute(
        'preview',
        (ctx, _) async =>
            (await finance.preview(table, mapping, 'owned-bill.csv', ctx)).id,
      ),
    );
  }

  Future<ToolRecord> commit(ToolRecord plan) async => output(
    await execute(
      'import',
      (ctx, _) async =>
          (await finance.importPreview(plan, ctx, confirmed: true)).id,
    ),
  );
  test('fixed deidentified CSV imports atomically, deduplicates full IDs and calculates monthly/year totals without transfers or voids', () async {
    final sample = [
      transaction('2026-10-01 00:01', '收入', '1000.00', '测试工资', 'I1'),
      transaction(
        '2026-10-02 12:00',
        '支出',
        '30.10',
        '测试餐馆',
        'E1',
        category: '餐饮',
      ),
      transaction(
        '2026-10-03 12:00',
        '支出',
        '0.20',
        '测试交通',
        'E2',
        category: '交通',
      ),
      transaction(
        '2026-10-03 13:00',
        '支出',
        '0.10',
        '测试交通',
        'E3',
        category: '交通',
      ),
      transaction('2026-10-04 12:00', '不计收支', '500.00', '自己两个账户', 'T1'),
      transaction(
        '2026-10-05 12:00',
        '退款',
        '10.00',
        '测试餐馆',
        'R1',
        related: 'E1',
        category: '餐饮',
      ),
      transaction(
        '2026-10-06 12:00',
        '支出',
        '99.00',
        '撤销商户',
        'V1',
        status: '交易关闭',
      ),
      transaction(
        '2026-10-07 12:00',
        '支出',
        '30.10',
        '=2+2',
        'E4',
        category: '购物',
        note: '"保留逗号,和换行\n不执行公式"',
      ),
      transaction(
        '2026-11-01 12:00',
        '支出',
        '20.00',
        '测试娱乐',
        'E5',
        category: '娱乐',
      ),
      transaction(
        '2026-10-02 12:00',
        '支出',
        '30.10',
        '测试餐馆',
        'E1',
        category: '餐饮',
      ),
    ];
    final plan = await preview(sample);
    expect(plan.number('duplicates'), 1);
    final summaries = await finance.watchPreviewSummaries().first;
    expect(summaries.single.number('validCount'), 10);
    expect(summaries.single.data.containsKey('entries'), false);
    expect(plan.data['errors'], isEmpty);
    final batch = await commit(plan);
    expect(batch.number('imported'), 9);
    expect(batch.number('duplicates'), 1);
    var ledger = await finance.all();
    expect(ledger.length, 9);
    expect(
      ledger.every((r) => r.flag('isSensitive') && !r.flag('syncAllowed')),
      true,
    );
    final oct = FinanceReport.calculate(ledger, 'CNY', month: '2026-10');
    expect(oct.income, 100000);
    expect(oct.expense, 6050);
    expect(oct.refunds, 1000);
    expect(oct.netExpense, 5050);
    expect(oct.balance, 94950);
    expect(oct.categories['交通'], 30);
    expect(oct.categories['餐饮'], 2010);
    expect(oct.merchants['测试餐馆'], 2010);
    final annual = FinanceReport.calculate(ledger, 'CNY', year: 2026);
    expect(annual.netExpense, 7050);
    expect(annual.trends['2026-11']!.expense, 2000);
    final repeated = await commit(await preview(sample));
    expect(repeated.number('imported'), 0);
    expect(repeated.number('duplicates'), 10);
    final budget = await finance.budget('2026-10', 'CNY', '餐饮', 5000);
    expect(budget.number('amountMinor'), 5000);
    await finance.budget('2026-10', 'CNY', '餐饮', 6000);
    expect((await store.list('finance_budget')).length, 1);
    final report = await output(
      await execute(
        'export',
        (ctx, _) async => (await finance.exportRows(ledger, temp.path, ctx)).id,
      ),
    );
    final exported = await File(report.text('outputPath')).readAsString();
    expect(exported, contains("'=2+2"));
    expect(report.text('checksum'), hasLength(64));
    final portable = await output(
      await execute(
        'portable_export',
        (ctx, _) async => (await finance.preparePortableExport(ledger, ctx)).id,
      ),
    );
    expect(portable.text('status'), 'prepared');
    final portableText = await OwnedFileStore(temp)
        .resolve(portable.text('attachment'))
        .readAsString();
    expect(csv.decode(portableText.replaceFirst('\ufeff', '')).length, 10);

    expect(csv.decode(exported.replaceFirst('\ufeff', '')).length, 10);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    store = PausingFinanceStore(db);
    finance = FinanceService(
      store,
      UtilityFileService(store, () async => OwnedFileStore(temp)),
    );
    ledger = await finance.all();
    expect(
      FinanceReport.calculate(ledger, 'CNY', month: '2026-10').netExpense,
      5050,
    );
  });
  test('final void status updates an existing transaction once; an associated refund is not subtracted twice and stale exports cannot resurrect it', () async {
    final original = transaction(
      '2026-10-01 12:00',
      '支出',
      '10.00',
      '测试退款商户',
      'original',
    );
    await commit(await preview([original]));
    final change = await preview([
      transaction(
        '2026-10-01 12:00',
        '支出',
        '10.00',
        '测试退款商户',
        'original',
        status: '已全额退款',
      ),
      transaction(
        '2026-10-02 12:00',
        '退款',
        '10.00',
        '测试退款商户',
        'refund',
        related: 'original',
      ),
    ]);
    expect(change.number('statusUpdates'), 1);
    final batch = await commit(change);
    expect(batch.number('updated'), 1);
    final report = FinanceReport.calculate(
      await finance.all(),
      'CNY',
      month: '2026-10',
    );
    expect(report.expense, 0);
    expect(report.refunds, 1000);
    expect(report.netExpense, 0);
    await commit(await preview([original]));
    expect(
      (await finance.all())
          .firstWhere((r) => r.text('transactionId') == 'original')
          .text('type'),
      'void',
    );
  });
  test('ID amount conflicts roll back all new rows; ambiguous transfer types require review and currency totals stay separate', () async {
    await commit(
      await preview([
        transaction('2026-10-01', '支出', '10.00', 'existing', 'same-id'),
      ]),
    );
    final plan = await preview([
      transaction('2026-10-02', '支出', '5.00', 'new row', 'new-id'),
      transaction('2026-10-01', '支出', '11.00', 'existing', 'same-id'),
    ]);
    final failed = await execute(
      'import',
      (ctx, _) async =>
          (await finance.importPreview(plan, ctx, confirmed: true)).id,
    );
    expect(utilityJobStatus(failed), UtilityJobStatus.failed);
    expect((await finance.all()).length, 1);
    final ambiguous = await preview([
      transaction('2026-10-03', '转账', '100.00', 'unknown', 'ambiguous'),
    ]);
    expect(ambiguous.data['errors'], isNotEmpty);
    final refused = await execute(
      'import',
      (ctx, _) async =>
          (await finance.importPreview(ambiguous, ctx, confirmed: true)).id,
    );
    expect(utilityJobStatus(refused), UtilityJobStatus.failed);
    await finance.saveEntry(
      FinanceService.entry(
        date: '2026-10-01',
        amount: '2.30',
        type: 'income',
        currency: 'USD',
      ),
    );
    expect(FinanceReport.calculate(await finance.all(), 'USD').income, 230);
    expect(FinanceReport.calculate(await finance.all(), 'CNY').expense, 1000);
  });
  test('scientific transaction IDs and unlinked void updates are refused instead of silently merging or retaining wrong totals', () async {
    expect(
      () => FinanceService.entry(
        date: '2026-10-01',
        amount: '1.00',
        type: 'expense',
        transactionId: '1.23456E+19',
      ),
      throwsA(isA<ToolFailure>()),
    );
    await commit(
      await preview([transaction('2026-10-01', '支出', '10.00', '没有ID的商户', '')]),
    );
    final changed = await preview([
      transaction('2026-10-01', '支出', '10.00', '没有ID的商户', '', status: '交易关闭'),
    ]);
    expect(changed.data['errors'], isNotEmpty);
    final refused = await execute(
      'import',
      (ctx, _) async =>
          (await finance.importPreview(changed, ctx, confirmed: true)).id,
    );
    expect(utilityJobStatus(refused), UtilityJobStatus.failed);
    expect(FinanceReport.calculate(await finance.all(), 'CNY').expense, 1000);
  });
  test('real XLSX mapping retains order ID, exact numeric amount and Excel dates; IANA date parsing rejects nonexistent civil times', () async {
    final table = await finance.read(billXlsx(), 'owned.xlsx');
    final mapping = FinanceMapping(
      {'date': 0, 'type': 1, 'amount': 2, 'transactionId': 3},
      source: 'alipay',
      typesByRow: {1: 'expense'},
    );
    final plan = await output(
      await execute(
        'preview',
        (ctx, _) async =>
            (await finance.preview(table, mapping, 'owned.xlsx', ctx)).id,
      ),
    );
    expect(plan.data['errors'], isEmpty);
    await commit(plan);
    final row = (await finance.all()).single;
    expect(row.number('amountMinor'), 12300);
    expect(row.text('dateLocal'), '2024-01-01 12:00:00');
    expect(row.text('transactionId'), '00012345678901234567890');
    expect(
      () => CivilTime.parse('2026-02-30', 'Asia/Shanghai'),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => CivilTime.parse('2026-03-08 02:30', 'America/New_York'),
      throwsA(isA<ToolFailure>()),
    );
    final autumn = CivilTime.parse('2026-11-01 01:30', 'America/New_York');
    expect(CivilTime.format(autumn, 'America/New_York'), '2026-11-01 01:30:00');
  });
  test('cancel reaches the live token while SQLite transaction is held, rolls back all inserts and releases the mutation gate', () async {
    final plan = await preview(
      List.generate(
        100,
        (i) => transaction(
          '2026-10-01 12:00',
          '支出',
          '0.10',
          'cancel-fixture',
          'cancel-$i',
        ),
      ),
    );
    store.pause = true;
    UtilityJobContext? context;
    final submitted = await jobs.submit(
      'finance',
      'import',
      '原子导入取消',
      {},
      confirmed: true,
      run: (ctx, _) async {
        context = ctx;
        return (await finance.importPreview(plan, ctx, confirmed: true)).id;
      },
    );
    await store.reached.future.timeout(const Duration(seconds: 5));
    final cancellation = jobs.cancel(submitted.id);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(context!.cancellation.cancelled, true);
    store.release.complete();
    await cancellation.timeout(const Duration(seconds: 5));
    final done = await jobs
        .waitFor(submitted.id)
        .timeout(const Duration(seconds: 5));
    expect(utilityJobStatus(done), UtilityJobStatus.cancelled);
    expect(await finance.all(), isEmpty);
    expect(
      (await store.list('finance_batch')).single.text('status'),
      'cancelled',
    );
    expect((await store.get(plan.id))!.text('status'), 'preview');
    final manual = await finance.saveEntry(
      FinanceService.entry(date: '2026-10-01', amount: '1.00', type: 'expense'),
    );
    expect(manual.number('amountMinor'), 100);
  });
}
