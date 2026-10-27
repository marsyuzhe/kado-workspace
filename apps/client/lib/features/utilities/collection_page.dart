import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/owned_file_store.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import 'collection_service.dart';
import 'money.dart';
import 'job_widgets.dart';
import 'utility_providers.dart';

Widget _photo(
  OwnedFileStore? files,
  String attachment, {
  double width = 82,
  double height = 112,
}) {
  if (files == null || attachment.isEmpty) {
    return SizedBox(
      width: width,
      height: height,
      child: const Icon(Icons.photo_outlined),
    );
  }
  try {
    return Image.file(
      files.resolve(attachment),
      width: width,
      height: height,
      fit: BoxFit.contain,
      cacheWidth: 320,
      errorBuilder: (_, _, _) => SizedBox(
        width: width,
        height: height,
        child: const Center(child: Text('图片缺失')),
      ),
    );
  } on ToolFailure {
    return const Text('图片路径无效');
  }
}

class CollectionPage extends ConsumerStatefulWidget {
  const CollectionPage({super.key});
  @override
  ConsumerState<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends ConsumerState<CollectionPage> {
  String query = '', type = '', state = 'all';
  bool favorites = false;
  int? optionalInt(String text) {
    if (text.trim().isEmpty) return null;
    final number = int.tryParse(text.trim());
    if (number == null) {
      throw const ToolFailure('编数请输入整数，特殊文字请写入编数说明。');
    }
    return number;
  }

  Future<void> edit([ToolRecord? row]) async => runUi(context, () async {
    final currentType = row?.text('collectionType') ?? '其他收藏卡';
    final values = await ltEditForm(
      context,
      title: row == null ? '添加收藏卡' : '编辑收藏卡资料',
      description: '每条记录代表一张实体卡。编数分开保存序号与总量；物料和评级仅记录你明确填写的信息，不根据图片推断。',
      fields: [
        LTField('name', '卡片名称', initial: row?.title ?? '', required: true),
        LTField(
          'person',
          '球员/角色',
          initial: row?.text('playerOrCharacter') ?? '',
          required: true,
        ),
        LTField(
          'type',
          '分类',
          initial: collectionTypes.contains(currentType)
              ? currentType
              : 'custom',
          options: {for (final t in collectionTypes) t: t, 'custom': '自定义分类'},
        ),
        LTField(
          'custom',
          '自定义分类名称',
          initial: collectionTypes.contains(currentType) ? '' : currentType,
        ),
        LTField('brand', '品牌', initial: row?.text('brand') ?? ''),
        LTField('series', '系列', initial: row?.text('series') ?? ''),
        LTField('year', '发行年/赛季', initial: row?.text('year') ?? ''),
        LTField(
          'cardNumber',
          '卡号（保留原始文字）',
          initial: row?.text('cardNumber') ?? '',
        ),
        LTField(
          'serial',
          '编数序号（可空）',
          initial: row?.data['serialNumber']?.toString() ?? '',
        ),
        LTField(
          'total',
          '编数总量（可空）',
          initial: row?.data['serialTotal']?.toString() ?? '',
        ),
        LTField(
          'serialNote',
          '编数原文/特殊说明',
          initial: row?.text('serialNote') ?? '',
        ),
        LTField('parallel', '平行版本/折射', initial: row?.text('parallel') ?? ''),
        LTField(
          'material',
          '物料来源（手动）',
          initial: row?.text('memorabiliaType') ?? '来源未知',
          options: {for (final t in memorabiliaTypes) t: t},
        ),
        LTField(
          'evidence',
          '背面官方说明/凭证备注',
          initial: row?.text('memorabiliaEvidence') ?? '',
          multiline: true,
        ),
        LTField(
          'gradeCompany',
          '评级公司（手动）',
          initial: row?.text('gradeCompany') ?? '',
        ),
        LTField('grade', '评级（手动，可空）', initial: row?.text('grade') ?? ''),
        LTField(
          'tags',
          '标签（逗号分隔）',
          initial: row?.strings('tags').join(',') ?? '',
        ),
        LTField('notes', '收藏备注', initial: row?.body ?? '', multiline: true),
      ],
    );
    if (values == null || !mounted) return;
    await ref
        .read(collectionProvider)
        .save(
          CollectionInput(
            name: values['name']!,
            playerOrCharacter: values['person']!,
            collectionType: values['type'] == 'custom'
                ? values['custom']!
                : values['type']!,
            brand: values['brand']!,
            series: values['series']!,
            year: values['year']!,
            cardNumber: values['cardNumber']!,
            serialNumber: optionalInt(values['serial']!),
            serialTotal: optionalInt(values['total']!),
            serialNote: values['serialNote']!,
            parallel: values['parallel']!,
            memorabiliaType: values['material']!,
            evidence: values['evidence']!,
            gradeCompany: values['gradeCompany']!,
            grade: values['grade']!,
            notes: values['notes']!,
            tags: values['tags']!.split(','),
          ),
          existing: row,
        );
  });
  Future<void> costs(ToolRecord row) async => runUi(context, () async {
    final code = row.text('currency', 'CNY');
    String amount(String field) => row.data[field] is int
        ? Money.format(row.number(field), currency: code)
        : '';
    final values = await ltEditForm(
      context,
      title: '成本、手动估值与出售',
      description:
          '购价、运费、购入手续费合计为成本。已出售差额再扣售出手续费。未录入成本的卡片不当作零成本；估值始终标为手动输入，不抓取市场价格。',
      fields: [
        LTField(
          'currency',
          '币种',
          initial: code,
          options: {for (final c in Money.currencies) c: c},
        ),
        LTField(
          'purchase',
          '购买价（赠送可填0）',
          initial: amount('purchaseMinor'),
          required: true,
        ),
        LTField(
          'shipping',
          '运费',
          initial: amount('shippingMinor').isEmpty
              ? '0'
              : amount('shippingMinor'),
        ),
        LTField(
          'buyFee',
          '购入平台手续费',
          initial: amount('buyFeeMinor').isEmpty ? '0' : amount('buyFeeMinor'),
        ),
        LTField(
          'date',
          '购买日期 YYYY-MM-DD（可空）',
          initial: row.text('purchaseDate'),
        ),
        LTField('source', '购买来源/订单备注', initial: row.text('purchaseSource')),
        LTField('value', '手动估值（可空）', initial: amount('manualValueMinor')),
        LTField(
          'valueSource',
          '手动估值来源说明',
          initial: row.text('manualValueSource', '用户手动输入'),
        ),
        LTField(
          'sold',
          '拥有状态',
          initial: row.flag('sold') ? 'true' : 'false',
          options: const {'false': '仍拥有', 'true': '已出售'},
        ),
        LTField('sale', '成交价（已出售时必填）', initial: amount('saleMinor')),
        LTField(
          'sellingFee',
          '售出平台手续费',
          initial: amount('sellingFeeMinor').isEmpty
              ? '0'
              : amount('sellingFeeMinor'),
        ),
        LTField(
          'saleDate',
          '成交日期 YYYY-MM-DD（可空）',
          initial: row.text('saleDate'),
        ),
      ],
    );
    if (values == null || !mounted) return;
    await ref
        .read(collectionProvider)
        .setCosts(
          row,
          currency: values['currency']!,
          purchase: values['purchase']!,
          shipping: values['shipping']!,
          buyFee: values['buyFee']!,
          purchaseDate: values['date']!,
          purchaseSource: values['source']!,
          manualValue: values['value']!,
          manualValueSource: values['valueSource']!,
          sold: values['sold'] == 'true',
          sale: values['sale']!,
          sellingFee: values['sellingFee']!,
          saleDate: values['saleDate']!,
        );
  });
  Future<void> export(List<ToolRecord> cards) async => runUi(context, () async {
    final service = ref.read(collectionProvider),
        jobs = ref.read(utilityJobsProvider);
    final submitted = await jobs.submit(
      'collection_cards',
      'export',
      '生成收藏卡CSV报表',
      {'cardCount': cards.length},
      confirmed: true,
      retainedBytes: cards.fold<int>(
        0,
        (n, r) => n + (r.title.length + r.body.length + 1000) * 2,
      ),
      run: (job, _) async => (await service.prepareExport(cards, job)).id,
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
      fileName: 'Links-collection-${record.id}.csv',
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
  });
  @override
  Widget build(BuildContext context) => ref
      .watch(collectionRowsProvider)
      .when(
        loading: () => const LTLoadingState(),
        error: (_, _) => const LTErrorState(message: '收藏记录读取失败或超出安全范围，原数据保留。'),
        data: (rows) {
          final cards = rows
                  .where(
                    (r) => CollectionService.matches(
                      r,
                      query,
                      type: type,
                      favoritesOnly: favorites,
                      state: state,
                    ),
                  )
                  .toList(),
              summary = CollectionSummary(cards),
              owned = ref.watch(ownedFilesProvider).asData?.value;
          return LTScrollPage(
            title: '收藏卡管理',
            description:
                '登记球星卡、动漫卡及物料卡。每张卡的编数、购入费用、手动估值、出售记录和图片分别持久保存；不生成实时市场价格。',
            header: [
              LTToolbar(
                children: [
                  LTButton(label: '添加收藏卡', onPressed: () => edit()),
                  TextButton(
                    onPressed: () => export(cards),
                    child: const Text('导出筛选卡片CSV'),
                  ),
                ],
              ),
              LTTextField(
                label: '搜索人物、品牌、系列、卡号、编数或备注',
                onChanged: (v) => setState(() => query = v),
              ),
              Wrap(
                spacing: 12,
                children: [
                  SizedBox(
                    width: 220,
                    child: DropdownButton<String>(
                      value: type,
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem(value: '', child: Text('所有分类')),
                        for (final t in {
                          ...collectionTypes,
                          ...rows.map((r) => r.text('collectionType')),
                        })
                          DropdownMenuItem(
                            value: t,
                            child: Text(t, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) => setState(() => type = v!),
                    ),
                  ),
                  DropdownButton<String>(
                    value: state,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部状态')),
                      DropdownMenuItem(value: 'owned', child: Text('仍拥有')),
                      DropdownMenuItem(value: 'sold', child: Text('已出售')),
                    ],
                    onChanged: (v) => setState(() => state = v!),
                  ),
                  FilterChip(
                    label: const Text('只看喜爱'),
                    selected: favorites,
                    onSelected: (v) => setState(() => favorites = v),
                  ),
                ],
              ),
              LTCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '当前筛选${cards.length}张 · 拥有${summary.owned}张 · 已出售${summary.sold}张 · 已录入成本${summary.priced}张',
                    ),
                    for (final e in summary.costs.entries)
                      Text(
                        '${e.key} 总购入成本 ${Money.format(e.value, currency: e.key)} · 仍拥有成本 ${Money.format(summary.ownedCosts[e.key] ?? 0, currency: e.key)}',
                      ),
                    for (final e in summary.realized.entries)
                      Text(
                        '${e.key} 已出售实现差额 ${Money.format(e.value, currency: e.key)}',
                      ),
                  ],
                ),
              ),
              const UtilityJobSummary(moduleId: 'collection_cards'),
            ],
            itemCount: cards.length,
            empty: const LTEmptyState(
              title: '登记自己的收藏卡',
              message: '先填写卡片资料，再录入成本或添加正面、背面和细节照片。没有默认的虚构收藏。',
            ),
            itemBuilder: (context, i) {
              final row = cards[i],
                  code = row.text('currency', 'CNY'),
                  profit = CollectionService.profit(row);
              return LTCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _photo(owned, row.text('coverThumbnail')),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                row.title,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${row.text('playerOrCharacter')} · ${row.text('collectionType')}',
                              ),
                              Text(
                                '${row.text('brand')} ${row.text('series')} ${row.text('year')}',
                              ),
                              Text(
                                '${CollectionService.serial(row)} · ${row.text('parallel')}',
                              ),
                              Text(row.text('memorabiliaType')),
                              Text(row.flag('sold') ? '已出售' : '仍拥有'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Text(
                      row.flag('costRecorded')
                          ? '$code 购入总成本 ${Money.format(CollectionService.cost(row), currency: code)}'
                          : '成本未录入',
                    ),
                    if (row.data['manualValueMinor'] is int)
                      Text(
                        '$code 手动估值 ${Money.format(row.number('manualValueMinor'), currency: code)} · ${row.text('manualValueSource')}',
                      ),
                    if (profit != null)
                      Text(
                        '$code 已出售实现差额 ${Money.format(profit, currency: code)}',
                      ),
                    Wrap(
                      children: [
                        IconButton(
                          tooltip: row.flag('favorite') ? '取消喜爱' : '设为喜爱',
                          onPressed: () => runUi(
                            context,
                            () => ref
                                .read(collectionProvider)
                                .favorite(row, !row.flag('favorite')),
                          ),
                          icon: Icon(
                            row.flag('favorite')
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                        ),
                        TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => CollectionGallery(cardId: row.id),
                          ),
                          child: Text('资料与图片（${row.number('imageCount')}）'),
                        ),
                        TextButton(
                          onPressed: () => edit(row),
                          child: const Text('编辑资料'),
                        ),
                        TextButton(
                          onPressed: () => costs(row),
                          child: const Text('成本/出售'),
                        ),
                        TextButton(
                          onPressed: () => runUi(context, () async {
                            if (!await ltConfirm(
                              context,
                              title: '移除这张卡片及应用内图片副本？',
                              message:
                                  '${row.title}\n${row.number('imageCount')}张应用内原图与缩略图副本将一并移除。最初通过系统选择的源文件不修改。',
                              dangerous: true,
                            )) {
                              return;
                            }
                            await ref
                                .read(collectionProvider)
                                .remove(row, confirmed: true);
                          }),
                          child: const Text('移除卡片'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
}

class CollectionGallery extends ConsumerStatefulWidget {
  const CollectionGallery({super.key, required this.cardId});
  final String cardId;
  @override
  ConsumerState<CollectionGallery> createState() => _CollectionGalleryState();
}

class _CollectionGalleryState extends ConsumerState<CollectionGallery> {
  String face = 'front';
  bool picking = false;
  Future<void> add(ToolRecord card) async => runUi(context, () async {
    setState(() => picking = true);
    try {
      final selected = await FilePicker.pickFiles();
      if (selected.isEmpty) return;
      if (selected.length > 12) {
        throw const ToolFailure('单次最多选择12张图片。');
      }
      if (!mounted) return;
      final service = ref.read(collectionProvider),
          jobs = ref.read(utilityJobsProvider),
          slot = face;
      for (final file in selected) {
        final length = await file.length();
        if (length != null && length > CollectionService.imageLimit) {
          throw const ToolFailure('单张图片最多15MiB。');
        }
        final builder = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in file.readAsByteStream()) {
          total += chunk.length;
          if (total > CollectionService.imageLimit) {
            throw const ToolFailure('图片超过15MiB，已停止读取。');
          }
          builder.add(chunk);
        }
        final bytes = builder.takeBytes(), name = file.name;
        await jobs.submit(
          'collection_cards',
          'image',
          '保存${collectionFaces[slot]}图片副本',
          {'cardId': card.id, 'face': slot, 'name': name},
          confirmed: true,
          retainedBytes: bytes.length,
          run: (job, _) async =>
              (await service.addImage(card, name, bytes, slot, job)).id,
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  });
  Future<void> exportOriginal(
    ToolRecord image,
  ) async => runUi(context, () async {
    final owned = await ref.read(ownedFilesProvider.future),
        file = owned.resolve(image.text('attachment'));
    if (await file.length() > CollectionService.imageLimit ||
        await archiveHash(file, TaskCancellation()) != image.text('checksum')) {
      throw const ToolFailure('原图变化或过大，未导出。');
    }
    await FilePicker.saveFile(
      fileName: 'Links-card-${image.id}.${image.text('format')}',
      bytes: await file.readAsBytes(),
      mimeType:
          'image/${image.text('format') == 'jpg' ? 'jpeg' : image.text('format')}',
    );
  });
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 860,
      height: MediaQuery.sizeOf(context).height * .84,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ref
            .watch(collectionCardProvider(widget.cardId))
            .when(
              loading: () => const LTLoadingState(),
              error: (_, _) => const LTErrorState(),
              data: (card) {
                if (card == null) return const Center(child: Text('收藏卡已不存在'));
                final owned = ref.watch(ownedFilesProvider).asData?.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            card.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 20,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭图片窗口',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        DropdownButton<String>(
                          value: face,
                          items: [
                            for (final e in collectionFaces.entries)
                              DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                          ],
                          onChanged: (v) => setState(() => face = v!),
                        ),
                        LTButton(
                          label: '选择图片保存副本',
                          onPressed: picking ? null : () => add(card),
                        ),
                      ],
                    ),
                    const Text(
                      'PNG/JPEG/WebP，每张≤15MiB、每卡≤12张。原图字节保留；缩略图单独生成并去除EXIF。关闭窗口后可查看任务进度和失败原因。',
                    ),
                    Expanded(
                      child: ref
                          .watch(collectionImagesProvider(card.id))
                          .when(
                            loading: () => const LTLoadingState(),
                            error: (_, _) => const LTErrorState(),
                            data: (photos) => ListView(
                              children: [
                                ExpansionTile(
                                  title: const Text('卡片资料与手动来源说明'),
                                  children: [
                                    SelectableText(
                                      '${card.text('playerOrCharacter')}\n${card.text('brand')} ${card.text('series')} ${card.text('year')}\n卡号：${card.text('cardNumber')} · ${CollectionService.serial(card)}\n编数说明：${card.text('serialNote')}\n物料：${card.text('memorabiliaType')}\n背面/凭证：${card.text('memorabiliaEvidence')}\n评级：${card.text('gradeCompany')} ${card.text('grade')}（手动记录）\n${card.body}',
                                    ),
                                  ],
                                ),
                                if (photos.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Text('尚未添加图片；可分别选择正面、背面和细节。'),
                                  ),
                                for (final image in photos)
                                  LTCard(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _photo(
                                          owned,
                                          image.text('thumbnailAttachment'),
                                          width: 320,
                                          height: 220,
                                        ),
                                        Text(
                                          '${collectionFaces[image.text('face')]} · ${image.title}',
                                        ),
                                        SelectableText(
                                          '原图SHA256：${image.text('checksum')}',
                                        ),
                                        Wrap(
                                          children: [
                                            TextButton(
                                              onPressed: owned == null
                                                  ? null
                                                  : () => showDialog<void>(
                                                      context: context,
                                                      builder: (_) => Dialog(
                                                        child: SizedBox(
                                                          width: 760,
                                                          height:
                                                              MediaQuery.sizeOf(
                                                                context,
                                                              ).height *
                                                              .7,
                                                          child: InteractiveViewer(
                                                            child: Image.file(
                                                              owned.resolve(
                                                                image.text(
                                                                  'attachment',
                                                                ),
                                                              ),
                                                              cacheWidth: 1600,
                                                              fit: BoxFit
                                                                  .contain,
                                                              errorBuilder:
                                                                  (_, _, _) =>
                                                                      const Center(
                                                                        child:
                                                                            Text(
                                                                              '原图缺失或不可解码',
                                                                            ),
                                                                      ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                              child: const Text('大图预览'),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  exportOriginal(image),
                                              child: const Text('导出原图'),
                                            ),
                                            TextButton(
                                              onPressed: () => runUi(context, () async {
                                                if (!await ltConfirm(
                                                  context,
                                                  title: '移除此图片副本？',
                                                  message:
                                                      '${image.title}\n删除应用内原图与缩略图副本，系统选择的源文件不修改。',
                                                  dangerous: true,
                                                )) {
                                                  return;
                                                }
                                                await ref
                                                    .read(collectionProvider)
                                                    .removeImage(
                                                      image,
                                                      confirmed: true,
                                                    );
                                              }),
                                              child: const Text('移除副本'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                    ),
                  ],
                );
              },
            ),
      ),
    ),
  );
}
