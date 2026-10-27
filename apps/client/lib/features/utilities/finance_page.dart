import 'dart:typed_data';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import 'bill_reader.dart';
import 'civil_time.dart';
import 'finance_service.dart';
import 'finance_chart.dart';
import 'money.dart';
import 'job_widgets.dart';
import 'utility_providers.dart';

const financeCurrencies = [
  'CNY',
  'USD',
  'EUR',
  'GBP',
  'HKD',
  'TWD',
  'AUD',
  'CAD',
  'SGD',
  'JPY',
  'KRW',
  'KWD',
  'BHD',
  'JOD',
];
const financeSources = {
  'manual': '手动',
  'csv': '通用CSV/XLSX',
  'alipay': '支付宝',
  'wechat': '微信支付',
};
const _fieldLabels = {
  'date': '日期 *',
  'amount': '金额 *',
  'type': '收支方向 *',
  'transactionId': '交易ID',
  'relatedTransactionId': '退款关联原交易ID',
  'merchant': '商户',
  'category': '分类',
  'paymentMethod': '支付方式',
  'description': '商品/备注',
  'status': '原交易状态',
  'currency': '币种',
};

class FinancePage extends ConsumerStatefulWidget {
  const FinancePage({super.key});
  @override
  ConsumerState<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends ConsumerState<FinancePage> {
  String currency = 'CNY',
      query = '',
      type = '全部',
      month = '',
      source = 'wechat',
      encoding = 'auto',
      name = '',
      selectedPreview = '',
      editablePreview = '',
      defaultType = '';
  int year = DateTime.now().year;
  final header = TextEditingController(text: '1'),
      end = TextEditingController(),
      zone = TextEditingController(text: 'Asia/Shanghai');
  final columns = <String, int>{}, overrides = <int, String>{};
  BillTable? table;
  Uint8List? sourceBytes;
  bool reading = false;
  @override
  void dispose() {
    header.dispose();
    end.dispose();
    zone.dispose();
    super.dispose();
  }

  Future<void> edit([ToolRecord? row]) async => runUi(context, () async {
    final values = await ltEditForm(
      context,
      title: row == null ? '手动添加交易' : '编辑交易',
      fields: [
        LTField(
          'date',
          '交易日期 YYYY-MM-DD HH:MM[:SS]',
          initial:
              row?.text('dateLocal') ??
              CivilTime.format(DateTime.now().toUtc(), zone.text),
          required: true,
        ),
        LTField(
          'zone',
          'IANA时区',
          initial: row?.text('zone') ?? zone.text,
          required: true,
        ),
        LTField(
          'type',
          '交易类型',
          initial: row?.text('type') ?? 'expense',
          options: {
            for (final t in financeTypes) t: FinanceService.typeLabel(t),
          },
        ),
        LTField(
          'currency',
          '币种（不同币种分别统计）',
          initial: row?.text('currency') ?? currency,
          options: {for (final c in financeCurrencies) c: c},
        ),
        LTField(
          'amount',
          '金额（正数，按币种精度）',
          initial: row == null
              ? ''
              : Money.format(
                  row.number('amountMinor'),
                  currency: row.text('currency'),
                ),
          required: true,
        ),
        LTField('merchant', '商户/对方', initial: row?.text('merchant') ?? ''),
        LTField('category', '分类（可自定义）', initial: row?.text('category') ?? '其他'),
        LTField('method', '支付方式', initial: row?.text('paymentMethod') ?? ''),
        if (row == null)
          LTField('source', '来源', initial: 'manual', options: financeSources),
        LTField(
          'id',
          '交易ID（可空，按来源区分）',
          initial: row?.text('transactionId') ?? '',
        ),
        LTField(
          'related',
          '退款关联原交易ID（可空）',
          initial: row?.text('relatedTransactionId') ?? '',
        ),
        LTField('note', '说明/备注', initial: row?.body ?? '', multiline: true),
      ],
    );
    if (values == null || !mounted) return;
    final data = FinanceService.entry(
      date: values['date']!,
      amount: values['amount']!,
      type: values['type']!,
      currency: values['currency']!,
      zone: values['zone']!,
      merchant: values['merchant']!,
      category: values['category']!,
      paymentMethod: values['method']!,
      description: values['note']!,
      source: row?.text('source') ?? values['source']!,
      transactionId: values['id']!,
      relatedTransactionId: values['related']!,
      status: row?.text('sourceStatus') ?? '',
    );
    await ref.read(financeProvider).saveEntry(data, existing: row);
  });
  Future<void> pick() async => runUi(context, () async {
    final file = await FilePicker.pickFile(
      dialogTitle: '选择主动导入的脱敏或个人账单CSV/XLSX',
    );
    if (file == null) return;
    final length = await file.length();
    if (length != null && length > BillReader.inputLimit) {
      throw const ToolFailure('单次账单最多10MiB。');
    }
    final builder = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in file.readAsByteStream()) {
      size += chunk.length;
      if (size > BillReader.inputLimit) {
        throw const ToolFailure('账单超过10MiB，已停止读取。');
      }
      builder.add(chunk);
    }
    if (!mounted) return;
    sourceBytes = builder.takeBytes();
    name = file.name;
    await load();
  });
  Future<void> load({String? sheet}) async => runUi(context, () async {
    final bytes = sourceBytes;
    if (bytes == null) return;
    final service = ref.read(financeProvider),
        jobs = ref.read(utilityJobsProvider),
        fileName = name,
        chosenEncoding = encoding;
    setState(() {
      reading = true;
      editablePreview = '';
    });
    BillTable? parsed;
    try {
      final submitted = await jobs.submit(
        'finance',
        'read',
        '读取账单表格（不执行公式）',
        {'name': fileName, 'encoding': chosenEncoding, 'sheet': sheet},
        confirmed: true,
        retainedBytes: bytes.length,
        run: (job, _) async {
          parsed = await service.read(
            bytes,
            fileName,
            sheet: sheet,
            encoding: chosenEncoding,
          );
          job.check();
          final row = await service.store.create(
            'finance_read',
            '账单表格读取结果',
            data: {
              'fileName': fileName,
              'rows': parsed!.rows.length,
              'sheet': parsed!.sheet,
              'sheets': parsed!.sheets,
              'encoding': chosenEncoding,
              'syncAllowed': false,
              'isSensitive': true,
            },
          );
          await job.output(row.id);
          return row.id;
        },
      );
      final done = await jobs.waitFor(submitted.id);
      if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
        throw ToolFailure(done.text('errorMessage'));
      }
      if (mounted && parsed != null) {
        final mapping = FinanceMapping.detect(parsed!, source: source);
        setState(() {
          table = parsed;
          columns
            ..clear()
            ..addAll(mapping.columns);
          header.text = '${mapping.headerRow + 1}';
          end.text = '${parsed!.rows.length}';
          overrides.clear();
        });
      }
    } finally {
      if (mounted) setState(() => reading = false);
    }
  });
  Future<void> preview() async => runUi(context, () async {
    final input = table;
    if (input == null) {
      throw const ToolFailure('请先读取账单并核对字段映射。');
    }
    final mapping = FinanceMapping(
          Map.of(columns),
          headerRow: (int.tryParse(header.text) ?? 0) - 1,
          endRow: int.tryParse(end.text),
          source: source,
          currency: currency,
          zone: zone.text.trim(),
          typesByRow: Map.of(overrides),
          defaultType: defaultType,
        ),
        service = ref.read(financeProvider),
        jobs = ref.read(utilityJobsProvider),
        fileName = name;
    final retained = input.rows.fold<int>(
      0,
      (n, r) => n + 128 + r.fold<int>(0, (s, c) => s + 64 + c.length * 2),
    );
    final submitted = await jobs.submit(
      'finance',
      'preview',
      '生成账单核对预览',
      {'name': fileName, 'mapping': mapping.toJson()},
      confirmed: true,
      retainedBytes: retained,
      run: (job, _) async =>
          (await service.preview(input, mapping, fileName, job)).id,
    );
    final done = await jobs.waitFor(submitted.id);
    if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
      throw ToolFailure(done.text('errorMessage'));
    }
    if (mounted) {
      setState(() {
        selectedPreview = done.text('resultReference');
        editablePreview = selectedPreview;
      });
    }
  });
  Future<void> commit(ToolRecord row) async => runUi(context, () async {
    final entries = row.data['entries'] as List;
    if (!await ltConfirm(
      context,
      title: '确认将这些交易写入本地账本？',
      message:
          '${row.text('fileName')}\n有效${entries.length}行；预估重复${row.number('duplicates')}行、原交易状态更新${row.number('statusUpdates')}行。\n相同来源与交易ID优先去重，无ID时按日期/金额/商户等稳定字段识别；相同金额不代表重复。请核对转账、退款、撤销和类型覆盖。所有数据只保存在本机，不连接银行或发送给模型。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(financeProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'finance',
          'import',
          '确认导入本地账单',
          {'previewId': row.id},
          confirmed: true,
          run: (job, _) async =>
              (await service.importPreview(row, job, confirmed: true)).id,
        );
  });
  Future<void> export(List<ToolRecord> rows) async => runUi(context, () async {
    if (!Platform.isWindows) {
      final service = ref.read(financeProvider),
          jobs = ref.read(utilityJobsProvider);
      final submitted = await jobs.submit(
        'finance',
        'portable_export',
        '准备系统保存的CSV报表',
        {'count': rows.length},
        confirmed: true,
        retainedBytes: rows.fold<int>(
          0,
          (n, r) => n + (r.body.length + r.title.length + 1000) * 2,
        ),
        run: (job, _) async =>
            (await service.preparePortableExport(rows, job)).id,
      );
      final done = await jobs.waitFor(submitted.id);
      if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
        throw ToolFailure(done.text('errorMessage'));
      }
      if (!mounted) return;
      final record = (await service.store.get(done.text('resultReference')))!;
      final owned = await ref.read(ownedFilesProvider.future),
          bytes = await owned.resolve(record.text('attachment')).readAsBytes();
      final saved = await FilePicker.saveFile(
        fileName: 'Links-finance-${record.id}.csv',
        bytes: bytes,
        mimeType: 'text/csv',
      );
      if (saved != null) {
        await service.store.save(
          record.copyWith(
            data: {
              ...record.data,
              'status': 'saved',
              'savedAt': DateTime.now().toUtc().toIso8601String(),
            },
          ),
        );
      }
      return;
    }
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择本地账单CSV报表输出目录',
    );
    if (directory == null || !mounted) return;
    final service = ref.read(financeProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'finance',
          'export',
          '导出筛选交易CSV',
          {'directory': directory, 'count': rows.length},
          confirmed: true,
          retainedBytes: rows.fold<int>(
            0,
            (n, r) => n + (r.body.length + r.title.length + 500) * 2,
          ),
          run: (job, _) async =>
              (await service.exportRows(rows, directory, job)).id,
        );
  });
  Future<void> editBudget([ToolRecord? row]) async => runUi(context, () async {
    final values = await ltEditForm(
      context,
      title: '月度预算',
      fields: [
        LTField(
          'month',
          '月份 YYYY-MM',
          initial:
              row?.text('month') ??
              '$year-${DateTime.now().month.toString().padLeft(2, '0')}',
          required: true,
        ),
        LTField(
          'currency',
          '币种',
          initial: row?.text('currency') ?? currency,
          options: {for (final c in financeCurrencies) c: c},
        ),
        LTField('category', '分类（留空为总预算）', initial: row?.text('category') ?? ''),
        LTField(
          'amount',
          '预算金额',
          initial: row == null
              ? ''
              : Money.format(
                  row.number('amountMinor'),
                  currency: row.text('currency'),
                ),
          required: true,
        ),
      ],
    );
    if (values == null || !mounted) return;
    await ref
        .read(financeProvider)
        .budget(
          values['month']!,
          values['currency']!,
          values['category']!,
          Money.parse(values['amount']!, currency: values['currency']!),
        );
  });
  List<ToolRecord> filtered(List<ToolRecord> rows) => rows
      .where(
        (r) =>
            r.text('currency') == currency &&
            (month.isEmpty || r.text('dateLocal').startsWith(month)) &&
            (type == '全部' || r.text('type') == type) &&
            '${r.title} ${r.body} ${r.text('category')} ${r.text('transactionId')}'
                .toLowerCase()
                .contains(query),
      )
      .toList();
  Widget filters() => Wrap(
    spacing: 12,
    runSpacing: 4,
    children: [
      DropdownButton<String>(
        value: currency,
        items: [
          for (final c in financeCurrencies)
            DropdownMenuItem(value: c, child: Text(c)),
        ],
        onChanged: (v) => setState(() => currency = v!),
      ),
      DropdownButton<String>(
        value: month.isEmpty ? '全部' : month.substring(5),
        items: [
          const DropdownMenuItem(value: '全部', child: Text('全部月份')),
          for (var m = 1; m <= 12; m++)
            DropdownMenuItem(
              value: m.toString().padLeft(2, '0'),
              child: Text('$year年$m月'),
            ),
        ],
        onChanged: (v) => setState(() => month = v == '全部' ? '' : '$year-$v'),
      ),
      DropdownButton<String>(
        value: type,
        items: [
          for (final t in ['全部', ...financeTypes])
            DropdownMenuItem(
              value: t,
              child: Text(t == '全部' ? '全部类型' : FinanceService.typeLabel(t)),
            ),
        ],
        onChanged: (v) => setState(() => type = v!),
      ),
    ],
  );
  Widget ledger(List<ToolRecord> rows) {
    final items = filtered(rows);
    return LTScrollPage(
      title: '本地交易明细',
      description: '只处理你主动输入或导入的数据。不同币种分别统计；内部转账/不计收支与撤销不计为消费，退款减少净支出。',
      header: [
        LTToolbar(
          children: [
            LTButton(label: '手动添加交易', onPressed: () => edit()),
            TextButton(
              onPressed: () => export(items),
              child: const Text('导出筛选明细CSV'),
            ),
          ],
        ),
        filters(),
        LTTextField(
          label: '搜索商户、分类、备注或交易ID',
          onChanged: (v) => setState(() => query = v.toLowerCase()),
        ),
        Text(
          '显示${items.length}笔 / 本地共${rows.length}笔（最多${FinanceService.ledgerLimit}笔）',
        ),
        const UtilityJobSummary(moduleId: 'finance'),
      ],
      itemCount: items.length,
      empty: const LTEmptyState(
        title: '暂无匹配交易',
        message: '手动记一笔，或在导入页选择CSV/XLSX并预览确认。没有默认的示例账单。',
      ),
      itemBuilder: (context, i) {
        final row = items[i];
        return LTCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${row.title} · ${FinanceService.typeLabel(row.text('type'))}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${row.text('currency')} ${Money.format(row.number('amountMinor'), currency: row.text('currency'))} · ${row.text('category')}',
              ),
              Text(
                '${row.text('dateLocal')} · ${row.text('zone')}\n${financeSources[row.text('source')] ?? row.text('source')} · ${row.text('paymentMethod')}',
              ),
              if (row.body.isNotEmpty) Text(row.body),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => edit(row),
                    child: const Text('编辑交易'),
                  ),
                  TextButton(
                    onPressed: () => runUi(context, () async {
                      if (!await ltConfirm(
                        context,
                        title: '删除这笔交易？',
                        message:
                            '${row.title}\n${row.text('dateLocal')}\n${row.text('currency')} ${Money.format(row.number('amountMinor'), currency: row.text('currency'))}',
                      )) {
                        return;
                      }
                      await ref
                          .read(financeProvider)
                          .remove(row, confirmed: true);
                    }),
                    child: const Text('删除交易'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget stats(List<ToolRecord> rows) {
    final period = FinanceReport.calculate(
          rows,
          currency,
          month: month,
          year: month.isEmpty ? year : null,
        ),
        annual = FinanceReport.calculate(rows, currency, year: year);
    List<MapEntry<String, int>> ranked(Map<String, int> values) =>
        values.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final cats = ranked(period.categories),
        merchants = ranked(period.merchants).take(20).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '收支统计',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        Wrap(
          spacing: 12,
          children: [
            DropdownButton<int>(
              value: year,
              items: [
                for (final y in {
                  DateTime.now().year,
                  ...rows
                      .map(
                        (r) =>
                            int.tryParse(r.text('dateLocal').split('-').first),
                      )
                      .whereType<int>(),
                }.toList()..sort())
                  DropdownMenuItem(value: y, child: Text('$y年')),
              ],
              onChanged: (v) => setState(() {
                year = v!;
                if (month.isNotEmpty) month = '$year-${month.substring(5)}';
              }),
            ),
            filters(),
          ],
        ),
        Text(month.isEmpty ? '本年统计（$year）' : '月份：$month'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final metric in [
              ('收入', period.income),
              ('支出原额', period.expense),
              ('退款', period.refunds),
              ('净支出', period.netExpense),
              ('收支结余', period.balance),
            ])
              SizedBox(
                width: 210,
                child: LTCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(metric.$1),
                      SelectableText(
                        '$currency ${Money.format(metric.$2, currency: currency)}',
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Text(
          '期内${period.count}笔（包括转账/撤销）。全额退款原交易已撤销且关联ID明确时，不再次扣除同一退款。没有关联ID的退款按独立退款计算，请人工核对。',
        ),
        LTCard(
          child: FinanceTrendChart(
            report: annual,
            year: year,
            currency: currency,
          ),
        ),
        const Text('分类净支出', style: TextStyle(fontSize: 20)),
        if (cats.isEmpty) const Text('当前范围没有消费记录。'),
        for (final entry in cats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${entry.key} · $currency ${Money.format(entry.value, currency: currency)}',
                ),
                LinearProgressIndicator(
                  value: cats.every((e) => e.value == 0)
                      ? 0
                      : (entry.value.abs() /
                                cats
                                    .map((e) => e.value.abs())
                                    .reduce((a, b) => a > b ? a : b))
                            .clamp(0, 1),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        const Text('商户排行（净支出）', style: TextStyle(fontSize: 20)),
        for (final entry in merchants)
          ListTile(
            title: Text(entry.key),
            subtitle: Text(
              '$currency ${Money.format(entry.value, currency: currency)}',
            ),
          ),
      ],
    );
  }

  Widget importer() {
    final input = table, headerIndex = (int.tryParse(header.text) ?? 1) - 1;
    final heads =
        input == null || headerIndex < 0 || headerIndex >= input.rows.length
        ? <String>[]
        : input.rows[headerIndex];
    final summaries =
        ref.watch(financePreviewSummariesProvider).asData?.value ?? [];
    final selected = summaries.any((r) => r.id == selectedPreview)
        ? selectedPreview
        : summaries.firstOrNull?.id;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '账单导入与核对',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
        ),
        const Text(
          '主动选择文件；原始账单不会自动同步或发给模型。最多10MiB/10000交易。Unicode默认支持UTF-8和UTF-16LE BOM；支付宝GBK需明确选择。XLSX只读已保存的单元格值，不执行公式或访问外部链接。',
        ),
        Wrap(
          spacing: 12,
          children: [
            DropdownButton<String>(
              value: source,
              items: [
                for (final item in financeSources.entries.where(
                  (e) => e.key != 'manual',
                ))
                  DropdownMenuItem(value: item.key, child: Text(item.value)),
              ],
              onChanged: (v) => setState(() => source = v!),
            ),
            SizedBox(
              width: 240,
              child: DropdownButton<String>(
                isExpanded: true,
                value: encoding,
                items: const [
                  DropdownMenuItem(
                    value: 'auto',
                    child: Text(
                      'UTF-8 / UTF-16 BOM',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(value: 'gbk', child: Text('明确使用GBK')),
                ],
                onChanged: (v) => setState(() => encoding = v!),
              ),
            ),
            LTButton(label: '选择CSV / XLSX', onPressed: reading ? null : pick),
            if (sourceBytes != null)
              TextButton(
                onPressed: reading ? null : () => load(),
                child: const Text('按当前编码重新读取'),
              ),
          ],
        ),
        const UtilityJobSummary(moduleId: 'finance'),
        if (input != null) ...[
          Text(
            '$name · ${input.rows.length}行 · ${input.sheet.isEmpty ? 'CSV' : input.sheet}',
          ),
          if (input.sheets.length > 1)
            DropdownButton<String>(
              isExpanded: true,
              value: input.sheet,
              items: [
                for (final s in input.sheets)
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: reading ? null : (v) => load(sheet: v),
            ),
          TextField(
            controller: header,
            decoration: const InputDecoration(labelText: '表头行号（从1开始）'),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: end,
            decoration: const InputDecoration(
              labelText: '最后数据行号（含该行，排除尾部统计说明）',
            ),
          ),
          TextButton(
            onPressed: heads.isEmpty
                ? null
                : () => setState(() {
                    columns
                      ..clear()
                      ..addAll(FinanceMapping.matchHeader(heads));
                    overrides.clear();
                  }),
            child: const Text('按所选表头匹配字段'),
          ),
          LTCard(
            child: Column(
              children: [
                for (final field in _fieldLabels.entries)
                  DropdownButtonFormField<int>(
                    key: ValueKey(
                      '${field.key}:$headerIndex:${columns[field.key]}',
                    ),
                    initialValue:
                        columns[field.key] != null &&
                            columns[field.key]! < heads.length
                        ? columns[field.key]
                        : -1,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: field.value),
                    items: [
                      const DropdownMenuItem(value: -1, child: Text('不映射')),
                      for (var i = 0; i < heads.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            '${i + 1} · ${heads[i].isEmpty ? '空表头' : heads[i]}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      if (v == -1) {
                        columns.remove(field.key);
                      } else {
                        columns[field.key] = v!;
                      }
                    }),
                  ),
              ],
            ),
          ),
          DropdownButton<String>(
            isExpanded: true,
            value: defaultType,
            items: [
              const DropdownMenuItem(value: '', child: Text('缺少收支列：请明确选择固定类型')),
              for (final t in financeTypes)
                DropdownMenuItem(
                  value: t,
                  child: Text('缺少方向列时统一为：${FinanceService.typeLabel(t)}'),
                ),
            ],
            onChanged: (v) => setState(() => defaultType = v!),
          ),
          TextField(
            controller: zone,
            decoration: const InputDecoration(labelText: '账单时间所属IANA时区'),
          ),
          filters(),
          LTButton(label: '生成预览，不写入账本', onPressed: preview),
          ExpansionTile(
            title: const Text('核对所选表头后的原始前5行'),
            children: [
              for (final row
                  in input.rows
                      .skip((headerIndex + 1).clamp(0, input.rows.length))
                      .take(5))
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(row.join(' | ')),
                ),
            ],
          ),
        ],
        if (summaries.isNotEmpty) ...[
          const SizedBox(height: 16),
          DropdownButton<String>(
            isExpanded: true,
            value: selected,
            items: [
              for (final row in summaries)
                DropdownMenuItem(
                  value: row.id,
                  child: Text(
                    '${row.createdAt.toLocal()} · ${row.text('fileName')} · ${row.text('status')}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => selectedPreview = v!),
          ),
          if (selected != null)
            ref
                .watch(financePreviewProvider(selected))
                .when(
                  loading: () => const LTLoadingState(),
                  error: (_, _) => const LTErrorState(),
                  data: (row) {
                    if (row == null) return const SizedBox.shrink();
                    final entries = row.data['entries'] as List,
                        errors = row.data['errors'] as List;
                    return LTCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '有效${entries.length}行 · 错误${errors.length}行 · 预估重复${row.number('duplicates')} · 状态更新${row.number('statusUpdates')}',
                          ),
                          const Text(
                            '先核对金额、币种、时区、退款与内部转账。无ID的稳定字段去重有可能合并相同秒内的相似交易，请核对后补录。全部错误需处理后才能导入；可修改映射、缩小范围，或在下方明确覆盖异常行类型后重新生成。',
                          ),
                          LTButton(
                            label: row.text('status') == 'imported'
                                ? '该预览已导入'
                                : '确认导入这些交易',
                            onPressed:
                                errors.isEmpty &&
                                    entries.isNotEmpty &&
                                    row.text('status') == 'preview'
                                ? () => commit(row)
                                : null,
                          ),
                          for (final raw in errors.take(30))
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '第${(raw as Map)['row']}行：${raw['message']}',
                                ),
                                if (table != null && row.id == editablePreview)
                                  DropdownButton<String>(
                                    isExpanded: true,
                                    value: overrides[(raw['row'] as int) - 1],
                                    hint: const Text('明确覆盖该行交易类型（仅当前读取的文件）'),
                                    items: [
                                      for (final t in financeTypes)
                                        DropdownMenuItem(
                                          value: t,
                                          child: Text(
                                            FinanceService.typeLabel(t),
                                          ),
                                        ),
                                    ],
                                    onChanged: (v) => setState(
                                      () => overrides[(raw['row'] as int) - 1] =
                                          v!,
                                    ),
                                  ),
                              ],
                            ),
                          if (errors.length > 30)
                            Text('另有${errors.length - 30}条错误，请修正源数据或范围后重新预览。'),
                          ExpansionTile(
                            title: const Text('预览前20笔有效交易'),
                            children: [
                              for (final raw in entries.take(20))
                                ListTile(
                                  title: Text(
                                    '${(raw as Map)['merchant']} · ${FinanceService.typeLabel(raw['type'] as String)}',
                                  ),
                                  subtitle: Text(
                                    '${raw['dateLocal']} · ${raw['currency']} ${Money.format(raw['amountMinor'] as int, currency: raw['currency'] as String)} · ${raw['category']}',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ],
      ],
    );
  }

  Widget budgets(List<ToolRecord> rows) => ref
      .watch(recordsProvider('finance_budget'))
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(),
        data: (values) => LTScrollPage(
          title: '月度预算',
          description: '按币种和分类分别保存。净支出为支出减去可应用退款，内部转账/撤销不计入；不自动连接银行账户。',
          header: [LTButton(label: '设置月度预算', onPressed: () => editBudget())],
          itemCount: values.length,
          empty: const LTEmptyState(
            title: '尚未设置预算',
            message: '可设置总预算，或按餐饮、交通等自定义分类设置。',
          ),
          itemBuilder: (context, i) {
            final row = values[i],
                report = FinanceReport.calculate(
                  rows,
                  row.text('currency'),
                  month: row.text('month'),
                ),
                spent = row.text('category').isEmpty
                    ? report.netExpense
                    : report.categories[row.text('category')] ?? 0,
                limit = row.number('amountMinor');
            return LTCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${row.text('month')} · ${row.text('category').isEmpty ? '总预算' : row.text('category')} · ${row.text('currency')}',
                  ),
                  Text(
                    '${Money.format(spent, currency: row.text('currency'))} / ${Money.format(limit, currency: row.text('currency'))}',
                  ),
                  LinearProgressIndicator(
                    value: limit == 0
                        ? (spent > 0 ? 1 : 0)
                        : (spent / limit).clamp(0, 1),
                  ),
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: () => editBudget(row),
                        child: const Text('编辑预算'),
                      ),
                      TextButton(
                        onPressed: () => runUi(context, () async {
                          if (!await ltConfirm(
                            context,
                            title: '移除这项预算？',
                            message: row.title,
                          )) {
                            return;
                          }
                          await ref.read(recordStoreProvider).delete(row);
                        }),
                        child: const Text('移除预算'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
  @override
  Widget build(BuildContext context) => ref
      .watch(financeRowsProvider)
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(message: '本地账本读取失败或超出安全范围，原数据保留。'),
        data: (rows) => DefaultTabController(
          length: 4,
          child: Column(
            children: [
              const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: '交易明细'),
                  Tab(text: '收支统计'),
                  Tab(text: '导入预览'),
                  Tab(text: '月度预算'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    ledger(rows),
                    stats(rows),
                    importer(),
                    budgets(rows),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
