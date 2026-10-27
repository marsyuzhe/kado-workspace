import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import 'archive_service.dart';

class ArchivePage extends ConsumerStatefulWidget {
  const ArchivePage({super.key});
  @override
  ConsumerState<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends ConsumerState<ArchivePage> {
  ScanResult? result;
  ToolRecord? root;
  List<List<ArchiveFile>> duplicates = [];
  final selected = <String>{};
  TaskCancellation? cancel;
  bool busy = false;
  String status = '', filter = '全部', sort = '路径';
  int shown = 100;
  Map<String, String> rules = {...defaultArchiveRules};
  ArchiveService get service => ref.read(archiveServiceProvider);
  @override
  void initState() {
    super.initState();
    loadRules();
  }

  Future<void> loadRules() async {
    final saved = await ref.read(recordStoreProvider).setting('archive.rules');
    if (saved != null) {
      // Rules are stored as one category=comma-separated-extensions per line.
      final parsed = <String, String>{};
      for (final line in saved.split('\n')) {
        final at = line.indexOf('=');
        if (at > 0) parsed[line.substring(0, at)] = line.substring(at + 1);
      }
      if (mounted && parsed.isNotEmpty) setState(() => rules = parsed);
    }
  }

  @override
  void dispose() {
    cancel?.cancel();
    super.dispose();
  }

  Future<void> task(Future<void> Function(TaskCancellation) action) async {
    if (busy) return;
    final token = TaskCancellation();
    cancel = token;
    setState(() => busy = true);
    await runUi(context, () => action(token));
    if (mounted) setState(() => busy = false);
  }

  Future<void> pickRoot() async {
    await runUi(context, () async {
      if (Platform.isWindows) {
        final path = await FilePicker.getDirectoryPath(
          dialogTitle: '选择并授权扫描目录',
        );
        if (path == null) return;
        final granted = await service.grant(path);
        if (mounted) {
          setState(() => root = granted);
          await scan();
        }
      } else {
        final files = await FilePicker.pickFiles();
        if (files.isEmpty) return;
        // Mobile document providers may expose content URIs. Stream selected
        // documents into app-owned copies without inventing filesystem grants.
        final app = await ref.read(appDirectoryProvider.future);
        final dir = Directory(p.join(app.path, 'imports', newId()));
        await dir.create(recursive: true);
        for (final file in files) {
          if (!validArchiveName(file.name)) {
            throw const ToolFailure('文件名无效，未导入。');
          }
          if ((await file.length() ?? 0) > 100 * 1024 * 1024) {
            throw const ToolFailure('移动端单个导入文件上限100MB。');
          }
          final destination = File(p.join(dir.path, file.name));
          await destination.create(exclusive: true);
          var bytes = 0;
          final out = await destination.open(mode: FileMode.writeOnly);
          try {
            await for (final chunk in file.readAsByteStream()) {
              bytes += chunk.length;
              if (bytes > 100 * 1024 * 1024) {
                throw const ToolFailure('导入大小超过100MB。');
              }
              await out.writeFrom(chunk);
            }
            await out.flush();
          } catch (_) {
            await out.close();
            await destination.delete();
            rethrow;
          }
          await out.close();
        }
        final granted = await service.grant(dir.path);
        if (mounted) {
          setState(() => root = granted);
          await scan();
        }
      }
    });
  }

  Future<void> scan() async {
    if (root == null) return;
    await task((token) async {
      setState(() {
        status = '正在扫描授权目录';
        result = null;
        duplicates = [];
        selected.clear();
        shown = 100;
      });
      final value = await ArchiveScanner().scan(
        root!.text('path'),
        token,
        rules: rules,
        onProgress: (count, bytes) {
          if (mounted) {
            setState(() => status = '已扫描$count个文件 · ${readableBytes(bytes)}');
          }
        },
      );
      if (mounted) setState(() => result = value);
      await service.index(root!, value);
      if (mounted) {
        setState(
          () => status = value.cancelled
              ? '扫描已取消，显示已读取的部分'
              : value.limited
              ? '达到50000文件上限，请选择较小目录'
              : '扫描完成 · ${value.elapsed.inMilliseconds} ms',
        );
      }
    });
  }

  Future<void> detect() async {
    if (result == null) return;
    await task((token) async {
      final groups = await DuplicateDetector().find(
        result!.files,
        token,
        onProgress: (n, total) {
          if (mounted) {
            setState(() => status = '重复检测 $n / $total（大小→快速指纹→SHA-256）');
          }
        },
      );
      if (mounted) {
        setState(() {
          duplicates = groups;
          status = '检测完成，${groups.length}组内容完全相同';
          filter = '重复';
        });
      }
    });
  }

  Future<void> editRules() async {
    final response = await ltEditForm(
      context,
      title: '分类扩展名规则',
      description: '每行：分类=扩展名,扩展名。只影响统计和显式生成的归档计划。',
      fields: [
        LTField(
          'rules',
          '分类规则',
          multiline: true,
          initial: rules.entries.map((e) => '${e.key}=${e.value}').join('\n'),
          required: true,
        ),
      ],
    );
    if (response == null || !mounted) return;
    await runUi(context, () async {
      final next = <String, String>{};
      for (final line
          in response['rules']!.split('\n').where((s) => s.trim().isNotEmpty)) {
        final at = line.indexOf('=');
        if (at < 1) throw const ToolFailure('请按“分类=扩展名,扩展名”填写。');
        final name = line.substring(0, at).trim();
        if (!validArchiveName(name)) {
          throw const ToolFailure('分类名称不能包含路径或保留字符。');
        }
        next[name] = line.substring(at + 1).trim();
      }
      await ref
          .read(recordStoreProvider)
          .setSetting(
            'archive.rules',
            next.entries.map((e) => '${e.key}=${e.value}').join('\n'),
          );
      if (mounted) setState(() => rules = next);
      if (root != null) await scan();
    });
  }

  Future<void> makePlan(String operation) async {
    final files =
        result?.files.where((f) => selected.contains(f.path)).toList() ?? [];
    if (files.isEmpty) {
      ltMessage(context, '先选择要处理的文件。');
      return;
    }
    RenameRule rule = const RenameRule();
    String? destination;
    var byCategory = false;
    if (operation == 'rename') {
      final input = await ltEditForm(
        context,
        title: '批量重命名规则',
        description: '日期使用文件修改日期；序号按当前选择顺序生成。所有文件在执行前预览并检查冲突。开关填写1启用、0关闭。',
        fields: const [
          LTField('prefix', '前缀'),
          LTField('suffix', '后缀'),
          LTField('find', '查找'),
          LTField('replace', '替换为'),
          LTField('regex', '受限正则：1/0（替换支持\$1）', initial: '0'),
          LTField('date', '日期：1/0', initial: '0'),
          LTField(
            'datePattern',
            '日期模板 yyyy/MM/dd/HH/mm（禁止路径分隔符）',
            initial: 'yyyyMMdd',
          ),
          LTField('seq', '序号：1/0', initial: '0'),
          LTField('start', '编号起点', initial: '1'),
          LTField('digits', '编号位数', initial: '3'),
          LTField('clean', '清理空格与非法字符：1/0', initial: '1'),
        ],
      );
      if (input == null) return;
      rule = RenameRule(
        prefix: input['prefix']!,
        suffix: input['suffix']!,
        find: input['find']!,
        replace: input['replace']!,
        regex: input['regex'] == '1',
        datePattern: input['datePattern']!,
        sequenceStart: int.tryParse(input['start']!) ?? -1,
        sequenceWidth: int.tryParse(input['digits']!) ?? -1,
        date: input['date'] == '1',
        sequence: input['seq'] == '1',
        clean: input['clean'] == '1',
      );
    } else {
      if (Platform.isWindows) {
        destination = await FilePicker.getDirectoryPath(
          dialogTitle: '选择${operation == 'copy' ? '复制' : '移动'}目标目录',
        );
      } else {
        final app = await ref.read(appDirectoryProvider.future);
        final directory = Directory(p.join(app.path, 'archive', newId()));
        await directory.create(recursive: true);
        destination = directory.path;
      }
      if (destination == null || !mounted) return;
      byCategory = await ltConfirm(
        context,
        title: '按分类创建子目录？',
        message: '选择“按分类”会在目标目录下创建图片、文档等子目录；选择取消则直接使用目标目录。',
        confirmLabel: '按分类',
      );
    }
    if (!mounted) return;
    ArchivePlan? plan;
    await task((token) async {
      setState(() => status = '计算内容校验并生成操作预览');
      plan = await service.plan(
        files,
        operation,
        token,
        rule: rule,
        destination: destination,
        byCategory: byCategory,
      );
    });
    if (plan == null || !mounted) return;
    final actual = plan!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '确认${{'rename': '重命名', 'copy': '复制', 'move': '移动'}[operation]} ${actual.files.length}个文件',
        ),
        content: SizedBox(
          width: 680,
          height: 400,
          child: ListView.builder(
            itemCount: actual.files.length,
            itemBuilder: (_, i) {
              final f = actual.files[i];
              return ListTile(
                isThreeLine: true,
                title: Text(
                  '${p.basename(f.source)} → ${p.basename(f.target)}',
                ),
                subtitle: Text(
                  '${f.target}\n${f.error.isEmpty ? '校验完成，目标不存在' : f.error}',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          LTButton(
            label: '确认执行',
            onPressed: actual.valid ? () => Navigator.pop(ctx, true) : null,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await task((token) async {
      final journal = await service.execute(
        actual,
        token,
        confirmed: true,
        onProgress: (n, total) {
          if (mounted) setState(() => status = '执行 $n / $total');
        },
      );
      final logs = (journal.data['items'] as List).cast<Map>();
      if (mounted) {
        setState(
          () => status =
              '已完成${logs.where((e) => e['status'] == 'done').length}项；失败${logs.where((e) => e['status'] == 'failed').length}项。结果已保存到操作日志。',
        );
      }
    });
    if (mounted) {
      selected.clear();
      await scan();
    }
  }

  Future<void> showLog(ToolRecord journal) async {
    final items = (journal.data['items'] as List? ?? []).cast<Map>();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${journal.title} · ${journal.text('status')}'),
        content: SizedBox(
          width: 680,
          height: 400,
          child: ListView(
            children: [
              const Text(
                '移动/重命名仅在目标内容未变且原路径空闲时撤销。复制撤销会将副本移入目标旁的 .links-toolbox-recovery 目录，保留内容。',
              ),
              for (final item in items)
                ListTile(
                  title: Text('${item['source']} → ${item['target']}'),
                  subtitle: Text(
                    '${item['status']} ${item['message'] ?? ''} ${item['undoError'] ?? ''}',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          LTButton(
            label: '条件撤销',
            onPressed: items.any((e) => e['status'] == 'done')
                ? () async {
                    Navigator.pop(ctx);
                    if (!await ltConfirm(
                          context,
                          title: '撤销已成功的操作？',
                          message: '逐个校验内容，不覆盖已有路径；失败项会保留原因。',
                          confirmLabel: '确认撤销',
                        ) ||
                        !mounted) {
                      return;
                    }
                    await task((_) async {
                      await service.undo(journal, confirmed: true);
                    });
                    if (mounted) await scan();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roots = ref.watch(recordsProvider('archive_root')).value ?? [];
    final logs = ref.watch(recordsProvider('archive_operation')).value ?? [];
    final duplicatePaths = duplicates
        .expand((g) => g)
        .map((f) => f.path)
        .toSet();
    final files = (result?.files ?? [])
        .where(
          (f) =>
              filter == '全部' ||
              filter == '重复' && duplicatePaths.contains(f.path) ||
              filter == f.category,
        )
        .toList();
    if (sort == '大小') files.sort((a, b) => b.size.compareTo(a.size));
    if (sort == '最近') files.sort((a, b) => b.modified.compareTo(a.modified));
    if (sort == '路径') files.sort((a, b) => a.path.compareTo(b.path));
    return LTScrollPage(
      title: '文件管理',
      description: Platform.isWindows
          ? '选择授权目录后扫描。文件操作先预览、确认；不会自动删除或覆盖文件。'
          : '通过系统选择文件，导入本机副本后进行统计和整理。原始文档不被修改。',
      header: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LTButton(
              label: Platform.isWindows ? '添加授权目录' : '选择并导入文件',
              onPressed: busy ? null : pickRoot,
              icon: Icons.create_new_folder_outlined,
            ),
            LTButton(
              label: '重新扫描',
              onPressed: busy || root == null ? null : scan,
              style: LTButtonStyle.secondary,
            ),
            LTButton(
              label: '重复检测',
              onPressed: busy || result == null ? null : detect,
              style: LTButtonStyle.secondary,
            ),
            LTButton(
              label: '分类规则',
              onPressed: busy ? null : editRules,
              style: LTButtonStyle.ghost,
            ),
            if (busy)
              LTButton(
                label: '取消任务',
                onPressed: () => cancel?.cancel(),
                style: LTButtonStyle.danger,
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final granted in roots)
          ListTile(
            contentPadding: EdgeInsets.zero,
            selected: granted.id == root?.id,
            title: Text(granted.title),
            subtitle: Text(granted.text('path')),
            onTap: busy
                ? null
                : () {
                    setState(() => root = granted);
                    scan();
                  },
            trailing: IconButton(
              tooltip: '移除授权（不删除文件）',
              icon: const Icon(Icons.close),
              onPressed: busy
                  ? null
                  : () async {
                      if (await ltConfirm(
                            context,
                            title: '移除目录授权？',
                            message: '停止在本应用中使用此目录；文件保持原样。',
                            confirmLabel: '移除',
                          ) &&
                          context.mounted) {
                        await runUi(context, () async {
                          await ref.read(recordStoreProvider).delete(granted);
                          final records = await ref
                              .read(recordStoreProvider)
                              .list('archive_file', limit: 10000);
                          for (final r in records.where(
                            (r) => r.text('rootId') == granted.id,
                          )) {
                            await ref.read(recordStoreProvider).delete(r);
                          }
                          if (mounted && root?.id == granted.id) {
                            setState(() {
                              root = null;
                              result = null;
                              selected.clear();
                            });
                          }
                        });
                      }
                    },
            ),
          ),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(status),
          ),
        if (result != null) ...[
          Text(
            '${result!.files.length}个文件 · ${readableBytes(result!.bytes)} · ${duplicates.length}组重复 · ${result!.errors.length}项读取错误',
          ),
          if (result!.largest.isNotEmpty)
            Text(
              '最大：${result!.largest.first.name}（${readableBytes(result!.largest.first.size)}）\n最近修改：${result!.recent.first.name}',
            ),
          if (result!.errors.isNotEmpty)
            ExpansionTile(
              title: const Text('读取错误'),
              children: [
                for (final e in result!.errors)
                  ListTile(title: SelectableText(e)),
              ],
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in ['全部', '重复', ...result!.categories.keys])
                ChoiceChip(
                  label: Text(
                    value == '全部' || value == '重复'
                        ? value
                        : '$value ${result!.categories[value]}',
                  ),
                  selected: filter == value,
                  onSelected: (_) => setState(() {
                    filter = value;
                    shown = 100;
                  }),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('已选择${selected.length}项'),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(
                        () => selected.addAll(files.map((f) => f.path)),
                      ),
                child: const Text('选择筛选结果'),
              ),
              TextButton(
                onPressed: () => setState(selected.clear),
                child: const Text('取消选择'),
              ),
              for (final op in {
                'rename': '重命名预览',
                'copy': '复制预览',
                'move': '移动预览',
              }.entries)
                LTButton(
                  label: op.value,
                  onPressed: busy || selected.isEmpty
                      ? null
                      : () => makePlan(op.key),
                  style: LTButtonStyle.secondary,
                ),
              DropdownButton<String>(
                value: sort,
                items: [
                  for (final v in ['路径', '大小', '最近'])
                    DropdownMenuItem(value: v, child: Text(v)),
                ],
                onChanged: (v) => setState(() => sort = v!),
              ),
            ],
          ),
          if (files.length > shown)
            TextButton(
              onPressed: () => setState(() => shown += 100),
              child: Text('再显示100项（共${files.length}项）'),
            ),
        ],
        if (logs.isNotEmpty)
          ExpansionTile(
            title: const Text('操作日志与条件撤销'),
            children: [
              for (final log in logs.take(30))
                ListTile(
                  title: Text(log.title),
                  subtitle: Text(
                    '${readableTime(log.createdAt)} · ${log.text('status')}',
                  ),
                  onTap: () => showLog(log),
                ),
            ],
          ),
      ],
      itemCount: files.length.clamp(0, shown),
      itemBuilder: (_, i) {
        final f = files[i];
        return CheckboxListTile(
          value: selected.contains(f.path),
          onChanged: busy
              ? null
              : (v) => setState(
                  () => v == true
                      ? selected.add(f.path)
                      : selected.remove(f.path),
                ),
          title: Text(f.name),
          subtitle: Text(
            '${f.path}\n${f.category} · ${readableBytes(f.size)} · ${readableTime(f.modified)}',
          ),
          isThreeLine: true,
        );
      },
      empty: const LTEmptyState(
        title: '选择目录或文件开始',
        message: '只读取明确选择的内容，扫描结果保存在本机。',
        icon: Icons.folder_outlined,
      ),
    );
  }
}
