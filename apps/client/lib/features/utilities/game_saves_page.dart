import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import '../hub/hub_actions.dart';
import 'job_widgets.dart';
import 'utility_providers.dart';

class GameSavesPage extends ConsumerStatefulWidget {
  const GameSavesPage({super.key});
  @override
  ConsumerState<GameSavesPage> createState() => _GameSavesPageState();
}

class _GameSavesPageState extends ConsumerState<GameSavesPage> {
  String query = '', profileId = '';
  bool preparing = false;
  TaskCancellation? scanning;
  @override
  void dispose() {
    scanning?.cancel();
    super.dispose();
  }

  Future<void> edit([ToolRecord? row]) async => runUi(context, () async {
    var source = row?.text('sourceDirectory'),
        destination = row?.text('backupDirectory');
    if (row == null) {
      source = await FilePicker.getDirectoryPath(
        dialogTitle: '选择已关闭游戏的存档目录（只读）',
      );
      if (source == null || !mounted) return;
      destination = await FilePicker.getDirectoryPath(
        dialogTitle: '选择独立备份目录（不在源目录中）',
      );
      if (destination == null || !mounted) return;
    }
    final values = await ltEditForm(
      context,
      title: row == null ? '登记游戏实例' : '编辑游戏实例',
      fields: [
        LTField('name', '游戏 / 实例名称', initial: row?.title ?? '', required: true),
        LTField(
          'platform',
          '平台 / 版本',
          initial: row?.text('platform') ?? 'Windows',
          required: true,
        ),
        LTField(
          'keep',
          '建议保留版本数（1–100，仅手动清理）',
          initial: '${row?.number('keepCount', 5) ?? 5}',
          required: true,
        ),
      ],
    );
    if (values == null || !mounted) return;
    await ref
        .read(gameSavesProvider)
        .save(
          values['name']!,
          values['platform']!,
          source!,
          destination!,
          keep: int.tryParse(values['keep']!) ?? 0,
          existing: row,
        );
  });
  Future<void> backup(ToolRecord row) async => runUi(context, () async {
    setState(() => preparing = true);
    final token = TaskCancellation();
    scanning = token;
    final service = ref.read(gameSavesProvider);
    try {
      final plan = await service.plan(row, token);
      if (!mounted) return;
      final values = await ltEditForm(
        context,
        title: '备份版本备注',
        fields: [const LTField('note', '例如：升级模组前', multiline: true)],
      );
      if (values == null || !mounted) return;
      if (!await ltConfirm(
        context,
        title: '确认游戏已关闭并创建完整备份？',
        message:
            '${row.title}\n源：${row.text('sourceDirectory')}\n输出：${row.text('backupDirectory')}\n${plan.scan.files.length}文件 / ${plan.scan.directories.length}目录 / ${plan.scan.bytes}字节。\n应用不能可靠检测游戏是否运行。请先关闭游戏；压缩后逐文件核对哈希，源文件变化时中止。取消需等待当前文件的压缩调用结束。',
      )) {
        return;
      }
      if (!mounted) return;
      await ref
          .read(utilityJobsProvider)
          .submit(
            'game_saves',
            'backup',
            '备份${row.title}',
            {
              'profileId': row.id,
              'fileCount': plan.scan.files.length,
              'bytes': plan.scan.bytes,
            },
            retainedBytes:
                plan.scan.files.fold<int>(
                  0,
                  (n, f) => n + 1024 + f.path.length * 2,
                ) +
                plan.scan.directories.fold<int>(
                  0,
                  (n, d) => n + 256 + d.length * 2,
                ),
            confirmed: true,
            run: (job, _) async =>
                (await service.backup(plan, values['note']!, job)).id,
          );
    } finally {
      scanning = null;
      if (mounted) setState(() => preparing = false);
    }
  });
  Future<void> restore(ToolRecord row) async => runUi(context, () async {
    final parent = await FilePicker.getDirectoryPath(
      dialogTitle: '选择恢复目录的父文件夹（只创建新目录）',
    );
    if (parent == null || !mounted) return;
    final name =
        'Links-restored-${DateTime.now().toUtc().millisecondsSinceEpoch}';
    if (!await ltConfirm(
      context,
      title: '校验并恢复到新目录？',
      message:
          '${row.title}\n$parent${Platform.pathSeparator}$name\n先校验ZIP哈希，再逐文件核对内容；禁止覆盖已有目录。完成后由你检查并手动迁移至游戏。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(gameSavesProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'game_saves',
          'restore',
          '恢复${row.title}',
          {'backupId': row.id, 'parent': parent, 'directoryName': name},
          confirmed: true,
          run: (job, _) async =>
              (await service.restore(row, parent, name, job)).id,
        );
  });
  Future<void> cleanup(ToolRecord row) async => runUi(context, () async {
    final service = ref.read(gameSavesProvider),
        old = await service.retentionPreview(row);
    if (!mounted) return;
    if (old.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有超过建议保留数的完整版本。')));
      return;
    }
    final selected = old.take(100).toList();
    if (!await ltConfirm(
      context,
      title: '删除这些已校验的旧ZIP备份？',
      message:
          '保留建议：${row.number('keepCount', 5)}个新版本。此次删除${selected.length}个旧版本：\n${selected.map((r) => '${r.createdAt.toLocal()} · ${r.text('fileName')}').join('\n')}\n只删除本应用记录且哈希一致的ZIP；源存档不会删除。此操作不可撤销。',
    )) {
      return;
    }
    if (!mounted) return;
    await ref
        .read(utilityJobsProvider)
        .submit(
          'game_saves',
          'cleanup',
          '清理${row.title}旧版本',
          {'ids': selected.map((r) => r.id).toList()},
          confirmed: true,
          run: (job, _) async {
            await service.deleteBackups(
              selected.map((r) => r.id).toList(),
              job,
              confirmed: true,
            );
            return null;
          },
        );
  });
  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(recordsProvider('game_profile')),
        backups = ref.watch(recordsProvider('game_backup'));
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '游戏实例'),
              Tab(text: '版本与恢复'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                profiles.when(
                  loading: () => const LTLoadingState(),
                  error: (_, _) => const LTErrorState(),
                  data: (rows) => LTScrollPage(
                    title: '游戏存档',
                    description: '手动登记多个实例，包括Minecraft世界。完整ZIP版本与SHA-256校验；请先关闭游戏。只恢复到新目录，暂不自动检测游戏运行或监控目录。',
                    header: [
                      LTToolbar(
                        children: [
                          if (Platform.isWindows)
                            LTButton(
                              label: '登记游戏实例',
                              onPressed: preparing ? null : () => edit(),
                            ),
                          if (preparing)
                            TextButton(
                              onPressed: () => scanning?.cancel(),
                              child: const Text('取消预检'),
                            ),
                          if (!Platform.isWindows)
                            const Text('移动端可浏览版本记录；原目录备份暂需Windows授权路径。'),
                        ],
                      ),
                      const UtilityJobSummary(moduleId: 'game_saves'),
                    ],
                    itemCount: rows.length,
                    empty: const LTEmptyState(
                      title: '登记自己的存档目录',
                      message: '选择游戏实例源目录和独立备份目录，不猜测或扫描系统中的游戏路径。',
                    ),
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return LTCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${row.title} · ${row.text('platform')}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SelectableText(
                              '源：${row.text('sourceDirectory')}\n备份：${row.text('backupDirectory')}',
                            ),
                            Text(
                              '完整手动备份 · 建议保留${row.number('keepCount', 5)}版本\n上次完成：${row.text('lastBackupAt').isEmpty ? '尚未备份' : row.text('lastBackupAt')}',
                            ),
                            Wrap(
                              children: [
                                if (Platform.isWindows) ...[
                                  TextButton(
                                    onPressed: preparing
                                        ? null
                                        : () => backup(row),
                                    child: const Text('预检并备份'),
                                  ),
                                  TextButton(
                                    onPressed: () => edit(row),
                                    child: const Text('编辑'),
                                  ),
                                  TextButton(
                                    onPressed: () => cleanup(row),
                                    child: const Text('预览旧版本清理'),
                                  ),
                                ],
                                TextButton(
                                  onPressed: () {
                                    setState(() => profileId = row.id);
                                    DefaultTabController.of(context)
                                        .animateTo(1);
                                  },
                                  child: const Text('查看版本'),
                                ),
                                TextButton(
                                  onPressed: () => runUi(context, () async {
                                    if (!await ltConfirm(
                                      context,
                                      title: '移除游戏实例登记？',
                                      message:
                                          '${row.title}\n只移除登记，保留源存档、备份ZIP及历史记录。',
                                    )) {
                                      return;
                                    }
                                    await ref
                                        .read(gameSavesProvider)
                                        .removeProfile(row, confirmed: true);
                                  }),
                                  child: const Text('移除实例登记'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                backups.when(
                  loading: () => const LTLoadingState(),
                  error: (_, _) => const LTErrorState(),
                  data: (rows) {
                    final items = rows
                        .where(
                          (r) =>
                              (profileId.isEmpty ||
                                  r.text('profileId') == profileId) &&
                              '${r.title} ${r.body}'.toLowerCase().contains(
                                query,
                              ),
                        )
                        .toList();
                    return LTScrollPage(
                      title: '备份版本',
                      description:
                          '只将已完成并校验的版本标为完整。中断和待核验版本会重新核对实际ZIP；损坏或缺失时拒绝恢复。',
                      header: [
                        LTTextField(
                          label: '搜索版本和备注',
                          onChanged: (v) =>
                              setState(() => query = v.toLowerCase()),
                        ),
                        if (profileId.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() => profileId = ''),
                            child: const Text('显示所有实例'),
                          ),
                        const UtilityJobSummary(moduleId: 'game_saves'),
                      ],
                      itemCount: items.length,
                      empty: const LTEmptyState(
                        title: '暂无匹配版本',
                        message: '完成一次真实备份后，此处显示版本文件、校验值和恢复入口。',
                      ),
                      itemBuilder: (context, i) {
                        final row = items[i];
                        return LTCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('${row.title} · ${row.text('status')}'),
                              Text(
                                '${row.createdAt.toLocal()} · ${row.number('fileCount')}文件 · ${row.number('totalBytes')}字节',
                              ),
                              if (row.body.isNotEmpty) Text(row.body),
                              SelectableText(
                                '${row.text('fileName')}\nSHA256：${row.text('sha256')}',
                              ),
                              if (row.text('error').isNotEmpty)
                                Text(row.text('error')),
                              Wrap(
                                children: [
                                  if (Platform.isWindows &&
                                      {
                                        'complete',
                                        'committing',
                                        'committed-needs-review',
                                        'interrupted',
                                      }.contains(row.text('status')) &&
                                      row.text('sha256').isNotEmpty)
                                    TextButton(
                                      onPressed: () => restore(row),
                                      child: const Text('校验并恢复至新目录'),
                                    ),
                                  if (Platform.isWindows)
                                    TextButton(
                                      onPressed: () => runUi(
                                        context,
                                        () => openTarget(
                                          context,
                                          ref,
                                          TargetAction(
                                            'folder',
                                            row.text('backupRoot'),
                                          ),
                                        ),
                                      ),
                                      child: const Text('打开备份文件夹'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
