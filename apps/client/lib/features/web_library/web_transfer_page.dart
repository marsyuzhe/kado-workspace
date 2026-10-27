import '../../core/storage/selected_input.dart';

import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../shared/record_ui.dart';
import '../utilities/job_widgets.dart';
import '../utilities/utility_providers.dart';
import 'web_import_reader.dart';
import 'web_providers.dart';

class WebTransferDialog extends ConsumerStatefulWidget {
  const WebTransferDialog({super.key, this.selection = const []});
  final List<String> selection;
  @override
  ConsumerState<WebTransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<WebTransferDialog> {
  WebImportDraft? draft;
  ToolRecord? preview;
  String name = '', mode = 'merge', format = 'json';
  bool replaceDefaults = false, skipInvalid = false, all = true, busy = false;
  String? result;
  Future<void> reopen(String id) async => runUi(context, () async {
    final row = await ref.read(recordStoreProvider).get(id);
    if (row?.kind != 'web_import_preview' || row!.text('status') != 'preview') {
      throw const ToolFailure('此预览已完成或删除，请重新选择文件。');
    }
    final parsed = await WebImportReader.read(
      Uint8List.fromList(utf8.encode(jsonEncode(row.data['payload']))),
      'json',
    );
    if (parsed.errors.isNotEmpty) {
      throw const ToolFailure('已保存的预览无法读取，请重新选择原文件。');
    }
    if (mounted) {
      setState(() {
        draft = WebImportDraft(
          parsed.categories,
          parsed.sites,
          row.strings('errors'),
          row.strings('warnings'),
          fullSnapshot: parsed.fullSnapshot,
          duplicates: row.number('sourceDuplicates'),
        );
        preview = row;
        name = row.title;
        mode = row.text('mode');
        replaceDefaults = row.flag('replaceDefaults');
        skipInvalid = false;
      });
    }
  });
  Future<void> select() async => runUi(context, () async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'html', 'htm', 'csv'],
    );
    if (picked.isEmpty) return;
    final file = picked.single;
    if ((await file.length() ?? 0) > WebImportReader.byteLimit) {
      throw const ToolFailure('文件限20MiB。');
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final bytes = await readToolFile(file, WebImportReader.byteLimit);
      final extension = file.name.split('.').last.toLowerCase(),
          data = await WebImportReader.read(
            bytes,
            extension == 'htm' ? 'html' : extension,
          );
      if (mounted) {
        setState(() {
          draft = data;
          preview = null;
          name = file.name;
          replaceDefaults = false;
          result = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> makePreview() async => runUi(context, () async {
    final input = draft;
    if (input == null) return;
    setState(() => busy = true);
    try {
      final row = await ref
          .read(webTransferProvider)
          .preview(input, name, mode: mode, replaceDefaults: replaceDefaults);
      if (mounted) setState(() => preview = row);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> commit() async => runUi(context, () async {
    final row = preview;
    if (row == null) return;
    setState(() => busy = true);
    try {
      final service = ref.read(webTransferProvider),
          jobs = ref.read(utilityJobsProvider);
      final submitted = await jobs.submit(
        'bookmarks',
        'import',
        '确认导入网站',
        {'previewId': row.id},
        confirmed: true,
        run: (ctx, _) async => (await service.commit(
          row,
          ctx,
          confirmed: true,
          skipInvalid: skipInvalid,
        )).id,
      );
      final done = await jobs.waitFor(submitted.id);
      if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
        throw ToolFailure(done.text('errorMessage'));
      }
      final batch = await service.store.get(done.text('resultReference'));
      if (mounted) {
        setState(() {
          preview = null;
          draft = null;
          result =
              '已导入${batch?.number('imported')}项；重复${batch?.number('duplicates')}项，身份冲突${batch?.number('conflicts')}项，无效${batch?.number('invalid')}项。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> export() async => runUi(context, () async {
    if (!all && widget.selection.isEmpty) {
      throw const ToolFailure('请先在导航页面选择网站，或选择导出全部。');
    }
    final selected = all ? null : widget.selection,
        service = ref.read(webTransferProvider),
        jobs = ref.read(utilityJobsProvider),
        owned = await ref.read(ownedFilesProvider.future),
        chosen = format;
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final submitted = await jobs.submit(
        'bookmarks',
        'export',
        '准备网站导出文件',
        {
          'format': chosen,
          'scope': all ? 'all' : 'selection',
          'count': selected?.length,
        },
        confirmed: true,
        run: (ctx, _) async {
          ctx.check();
          final bytes = await service.export(chosen, ids: selected);
          ctx.check();
          final path = await owned.write(
            'web_exports',
            bytes,
            extension: chosen,
          );
          try {
            final row = await service.store.transaction(() async {
              ctx.check();
              final output = await service.store.create(
                'web_export',
                '网站$chosen导出',
                data: {
                  'attachment': path,
                  'format': chosen,
                  'size': bytes.length,
                  'checksum': sha256.convert(bytes).toString(),
                  'status': 'prepared',
                  'jobId': ctx.id,
                  'syncAllowed': false,
                },
              );
              await ctx.output(output.id);
              ctx.check();
              return output;
            });
            return row.id;
          } catch (_) {
            await owned.remove(path);
            rethrow;
          }
        },
      );
      final done = await jobs.waitFor(submitted.id);
      if (utilityJobStatus(done) != UtilityJobStatus.succeeded) {
        throw ToolFailure(done.text('errorMessage'));
      }
      final row = (await service.store.get(done.text('resultReference')))!;
      final bytes = await owned.resolve(row.text('attachment')).readAsBytes();
      if (!mounted) return;
      final saved = await FilePicker.saveFile(
        fileName: 'KADO-Desk-websites-${row.id}.$chosen',
        bytes: bytes,
        mimeType: chosen == 'json'
            ? 'application/json'
            : chosen == 'csv'
            ? 'text/csv'
            : 'text/html',
      );
      if (saved != null) {
        await service.store.save(
          row.copyWith(
            data: {
              ...row.data,
              'status': 'saved',
              'savedAt': DateTime.now().toUtc().toIso8601String(),
            },
          ),
        );
      }
      if (mounted) {
        setState(
          () => result = saved == null
              ? '已准备导出文件；系统保存已取消，可从任务记录再次保存。'
              : '网站文件已保存。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('网站导入 / 导出'),
    content: SizedBox(
      width: 720,
      height: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if ((ref.watch(webPreviewSummariesProvider).asData?.value ?? [])
                .isNotEmpty)
              ExpansionTile(
                title: const Text('未完成的导入预览'),
                subtitle: const Text('只保存本地预览；不会自动导入或重放。'),
                children: [
                  for (final item
                      in ref.watch(webPreviewSummariesProvider).asData!.value)
                    ListTile(
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('待写入${item.count}项 · 错误${item.errors}项'),
                      onTap: busy ? null : () => reopen(item.id),
                      trailing: IconButton(
                        tooltip: '删除此预览副本',
                        onPressed: busy
                            ? null
                            : () => runUi(context, () async {
                                final row = await ref
                                    .read(recordStoreProvider)
                                    .get(item.id);
                                if (row != null) {
                                  await ref
                                      .read(recordStoreProvider)
                                      .delete(row);
                                }
                                if (mounted && preview?.id == item.id) {
                                  setState(() {
                                    preview = null;
                                    draft = null;
                                  });
                                }
                              }),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              ),
            const Text(
              '支持浏览器 Netscape HTML、JSON、CSV，最多20MiB / 10000个网站。仅解析本地文件，不访问导入的网址。',
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: busy ? null : select,
              icon: const Icon(Icons.upload_file),
              label: Text(name.isEmpty ? '选择书签文件' : name),
            ),
            if (draft != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: '导入方式'),
                items: const [
                  DropdownMenuItem(value: 'merge', child: Text('合并分类并跳过重复网址')),
                  DropdownMenuItem(value: 'skip', child: Text('保留已有记录，跳过身份冲突')),
                  DropdownMenuItem(
                    value: 'folder',
                    child: Text('归入新建导入分类（深层目录合并）'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        mode = v!;
                        preview = null;
                        replaceDefaults = false;
                      }),
              ),
              if (draft!.fullSnapshot && mode != 'folder')
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: replaceDefaults,
                  title: const Text('按完整JSON快照替换未修改的默认推荐'),
                  subtitle: const Text('保留用户修改、收藏、固定及访问过的记录。可移除快照中没有的未修改默认项。'),
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          replaceDefaults = v!;
                          preview = null;
                        }),
                ),
              Text(
                '有效网站${draft!.sites.length}项，分类${draft!.categories.length}项，错误${draft!.errors.length}项。',
              ),
              for (final error in draft!.errors.take(12))
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (draft!.errors.length > 12)
                Text('其余${draft!.errors.length - 12}条错误请修正原文件后重试。'),
              for (final warning in draft!.warnings.take(8))
                Text(warning, style: Theme.of(context).textTheme.bodySmall),
              if (draft!.errors.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: skipInvalid,
                  title: const Text('明确跳过无效条目，仅导入有效网站'),
                  onChanged: busy
                      ? null
                      : (v) => setState(() => skipInvalid = v!),
                ),
              OutlinedButton(
                onPressed: busy ? null : makePreview,
                child: const Text('生成写入预览'),
              ),
            ],
            if (preview != null) ...[
              const SizedBox(height: 8),
              Text(
                '将写入${preview!.number('toWrite')}个网站；新增分类${preview!.number('newCategories')}个；跳过重复${preview!.number('duplicates')}项、冲突${preview!.number('conflicts')}项；移除未修改默认推荐${preview!.number('replaceDefaultsCount')}项。',
              ),
              const Text(
                '确认后整批写入本机数据库。若数据已变化，将要求重新预览。',
                style: TextStyle(fontSize: 12),
              ),
              FilledButton(
                onPressed: busy || draft!.errors.isNotEmpty && !skipInvalid
                    ? null
                    : commit,
                child: const Text('确认导入预览内容'),
              ),
            ],
            const Divider(height: 32),
            Text('导出', style: Theme.of(context).textTheme.titleMedium),
            const Text(
              'JSON保留UUID、分类关系、顺序、日期、访问次数和自定义图标。HTML用于浏览器书签，CSV用于表格；网页图标缓存不导出。',
              style: TextStyle(fontSize: 12),
            ),
            DropdownButton<String>(
              value: format,
              items: ['json', 'html', 'csv']
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(v.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: busy ? null : (v) => setState(() => format = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(all ? '导出全部网站' : '导出当前选择${widget.selection.length}项'),
              value: all,
              onChanged: busy ? null : (v) => setState(() => all = v!),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : export,
              icon: const Icon(Icons.download_outlined),
              label: const Text('准备并保存导出文件'),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              ),
            if (result != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(result!)),
            const Divider(height: 24),
            const UtilityJobHistory(moduleId: 'bookmarks'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
