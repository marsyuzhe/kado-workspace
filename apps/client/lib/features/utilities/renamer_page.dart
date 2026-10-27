import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import 'job_widgets.dart';
import 'utility_providers.dart';

class RenamerPage extends ConsumerStatefulWidget {
  const RenamerPage({super.key});
  @override
  ConsumerState<RenamerPage> createState() => _RenamerPageState();
}

class _RenamerPageState extends ConsumerState<RenamerPage> {
  final inputs = <ArchiveFile>[];
  final selected = <String>{};
  final prefix = TextEditingController(),
      suffix = TextEditingController(),
      find = TextEditingController(),
      replace = TextEditingController();
  final start = TextEditingController(text: '1'),
      width = TextEditingController(text: '3'),
      step = TextEditingController(text: '1');
  final datePattern = TextEditingController(text: 'yyyyMMdd'),
      extension = TextEditingController();
  bool sequence = true,
      keepOriginal = true,
      regex = false,
      clean = true,
      date = false,
      busy = false;
  ArchivePlan? preview;
  TaskCancellation? preparing;
  @override
  void dispose() {
    preparing?.cancel();
    for (final c in [
      prefix,
      suffix,
      find,
      replace,
      start,
      width,
      step,
      datePattern,
      extension,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool folder) async => runUi(context, () async {
    if (!Platform.isWindows) {
      throw const ToolFailure('移动端请在 Archive 导入文件副本后整理；这里暂只重命名 Windows 授权原文件。');
    }
    setState(() => busy = true);
    final token = TaskCancellation();
    preparing = token;
    try {
      final added = <ArchiveFile>[];
      if (folder) {
        final path = await FilePicker.getDirectoryPath(
          dialogTitle: '授权读取目录内文件（含子目录，不处理链接）',
        );
        if (path == null) return;
        await ref.read(archiveServiceProvider).grant(path);
        final result = await ArchiveScanner().scan(path, token, limit: 1001);
        if (result.limited || result.files.length > 1000) {
          throw const ToolFailure('目录超过1000文件，请改选较小目录。');
        }
        if (result.errors.isNotEmpty) {
          throw const ToolFailure('部分目录不可读，未添加。请单独选择可访问的文件。');
        }
        added.addAll(result.files);
      } else {
        for (final chosen in await FilePicker.pickFiles()) {
          final path = chosen.path;
          if (path == null) throw const ToolFailure('此文件没有可授权的本地路径。');
          if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw const ToolFailure('文件无效或是链接。');
          }
          final stat = await File(path).stat();
          added.add(
            ArchiveFile(
              path,
              stat.size,
              stat.modified,
              classifyFile(path, defaultArchiveRules),
            ),
          );
        }
      }
      if (inputs.length + added.length > 1000) {
        throw const ToolFailure('单次最多1000文件。');
      }
      if (mounted) {
        setState(() {
          final keys = inputs.map((f) => archivePathKey(f.path)).toSet();
          for (final f in added) {
            if (keys.add(archivePathKey(f.path))) {
              inputs.add(f);
              selected.add(f.path);
            }
          }
          inputs.sort((a, b) => a.path.compareTo(b.path));
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  List<ArchiveFile> get chosen => inputs
      .where(
        (f) =>
            selected.contains(f.path) &&
            (extension.text.trim().isEmpty ||
                f.name.toLowerCase().endsWith(
                  '.${extension.text.trim().replaceFirst('.', '').toLowerCase()}',
                )),
      )
      .toList();
  Future<void> plan() async => runUi(context, () async {
    setState(() => busy = true);
    final token = TaskCancellation();
    preparing = token;
    try {
      final planned = await ref
          .read(archiveServiceProvider)
          .plan(
            chosen,
            'rename',
            token,
            stagedRename: true,
            rule: RenameRule(
              prefix: prefix.text,
              suffix: suffix.text,
              find: find.text,
              replace: replace.text,
              sequence: sequence,
              sequenceStart: int.tryParse(start.text) ?? -1,
              sequenceWidth: int.tryParse(width.text) ?? 0,
              sequenceStep: int.tryParse(step.text) ?? 0,
              keepOriginal: keepOriginal,
              regex: regex,
              clean: clean,
              date: date,
              datePattern: datePattern.text,
            ),
          );
      if (mounted) setState(() => preview = planned);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> execute() async {
    final plan = preview;
    if (plan == null ||
        !plan.valid ||
        !await ltConfirm(
          context,
          title: '执行${plan.files.length}项重命名？',
          message: '请核对原名称与新名称。使用同目录临时名分两阶段执行，目标不覆盖。异常或取消后可在操作记录中条件撤销。',
          confirmLabel: '确认执行',
        ) ||
        !mounted) {
      return;
    }
    final service = ref.read(archiveServiceProvider);
    await runUi(context, () async {
      await ref
          .read(utilityJobsProvider)
          .submit(
            'renamer',
            'rename',
            '重命名${plan.files.length}文件',
            {'files': plan.files.map((f) => f.toJson()).toList()},
            confirmed: true,
            run: (job, _) async {
              await job.progress(0, plan.files.length, force: true);
              final journal = await service.execute(
                plan,
                job.cancellation,
                confirmed: true,
                onProgress: (done, total) =>
                    job.progress(done, total, force: true),
              );
              await job.output(journal.id);
              if (journal.text('status') != 'finished') {
                throw ToolFailure(
                  journal.text('error').isEmpty
                      ? '任务未完成，请查看操作记录。'
                      : journal.text('error'),
                );
              }
              return journal.id;
            },
          );
      if (mounted) {
        setState(() {
          preview = null;
          inputs.clear();
          selected.clear();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text(
        '批量重命名',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      const Text('直接修改授权文件名。扩展名始终保留；请先预览。最多1000项，Windows优先。'),
      LTToolbar(
        children: [
          LTButton(label: '添加文件', onPressed: busy ? null : () => pick(false)),
          LTButton(label: '添加文件夹', onPressed: busy ? null : () => pick(true)),
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    inputs.clear();
                    selected.clear();
                    preview = null;
                  }),
            child: const Text('清空'),
          ),
        ],
      ),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in [
            (prefix, '前缀'),
            (suffix, '后缀'),
            (find, '查找'),
            (replace, '替换'),
            (start, '编号起点'),
            (width, '编号位数'),
            (step, '编号增量'),
            (datePattern, '日期模板'),
            (extension, '扩展名筛选'),
          ])
            SizedBox(
              width: 180,
              child: TextField(
                controller: item.$1,
                onChanged: (_) => setState(() => preview = null),
                decoration: InputDecoration(labelText: item.$2),
              ),
            ),
        ],
      ),
      Wrap(
        children: [
          for (final item in <(String, bool, void Function(bool))>[
            ('编号', sequence, (v) => sequence = v),
            ('保留原名称', keepOriginal, (v) => keepOriginal = v),
            ('正则替换', regex, (v) => regex = v),
            ('清理非法字符', clean, (v) => clean = v),
            ('添加修改日期', date, (v) => date = v),
          ])
            SizedBox(
              width: 190,
              child: CheckboxListTile(
                title: Text(item.$1),
                value: item.$2,
                onChanged: (v) => setState(() {
                  item.$3(v ?? false);
                  preview = null;
                }),
              ),
            ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      Text('已添加${inputs.length}项 · 当前选择${chosen.length}项'),
      if (inputs.isNotEmpty)
        SizedBox(
          height: 220,
          child: ListView.builder(
            itemCount: inputs.length,
            itemBuilder: (_, i) {
              final f = inputs[i];
              return CheckboxListTile(
                dense: true,
                title: Text(f.name),
                subtitle: Text(
                  f.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: selected.contains(f.path),
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        v == true
                            ? selected.add(f.path)
                            : selected.remove(f.path);
                        preview = null;
                      }),
              );
            },
          ),
        ),
      LTToolbar(
        children: [
          LTButton(
            label: '生成双列预览',
            onPressed: busy || chosen.isEmpty ? null : plan,
          ),
          LTButton(
            label: '确认并执行',
            onPressed: busy || preview?.valid != true ? null : execute,
          ),
        ],
      ),
      if (preview != null) ...[
        const Text('原名称 → 新名称'),
        for (final f in preview!.files)
          ListTile(
            dense: true,
            title: Text(
              '${File(f.source).uri.pathSegments.last} → ${File(f.target).uri.pathSegments.last}',
              style: TextStyle(
                color: f.error.isEmpty
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            subtitle: f.error.isEmpty ? null : Text(f.error),
          ),
      ],
      const UtilityJobHistory(moduleId: 'renamer'),
      const Text('操作记录与撤销', style: TextStyle(fontSize: 18)),
      ref
          .watch(recordsProvider('archive_operation'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final row
                    in rows
                        .where((r) => r.text('operation') == 'rename_staged')
                        .take(20))
                  LTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${row.title} · ${row.text('status')} · ${readableTime(row.updatedAt)}',
                        ),
                        if (row.text('error').isNotEmpty)
                          Text(row.text('error')),
                        if (row.text('undoError').isNotEmpty)
                          Text(row.text('undoError')),
                        TextButton(
                          onPressed: row.text('status') == 'undone'
                              ? null
                              : () async {
                                  if (!await ltConfirm(
                                        context,
                                        title: '条件撤销重命名？',
                                        message: '先校验所有文件内容与原路径占用，再安全还原。后续编辑过的文件不会覆盖。',
                                      ) ||
                                      !context.mounted) {
                                    return;
                                  }
                                  final service = ref.read(
                                    archiveServiceProvider,
                                  );
                                  await runUi(
                                    context,
                                    () => ref
                                        .read(utilityJobsProvider)
                                        .submit(
                                          'renamer',
                                          'undo',
                                          '撤销重命名',
                                          {'journalId': row.id},
                                          confirmed: true,
                                          run: (job, _) async {
                                            final result = await service.undo(
                                              row,
                                              confirmed: true,
                                            );
                                            await job.output(result.id);
                                            if (result.text('status') !=
                                                'undone') {
                                              throw ToolFailure(
                                                result.text('undoError'),
                                              );
                                            }
                                            return result.id;
                                          },
                                        ),
                                  );
                                },
                          child: const Text('校验并撤销'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
    ],
  );
}
