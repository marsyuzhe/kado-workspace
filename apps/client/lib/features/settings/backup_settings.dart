import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/backup/backup_service.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';

class BackupSettings extends ConsumerStatefulWidget {
  const BackupSettings({super.key});
  @override
  ConsumerState<BackupSettings> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends ConsumerState<BackupSettings> {
  bool busy = false;
  File? latest;
  String? status;
  @override
  void initState() {
    super.initState();
    loadLatest();
  }

  Future<void> loadLatest() async {
    try {
      final home = await ref.read(dataHomeProvider.future);
      final dir = Directory(p.join(home.base.path, 'backups'));
      if (await dir.exists()) {
        final files = await dir
            .list()
            .where((e) => e is File && p.extension(e.path) == '.zip')
            .cast<File>()
            .toList();
        files.sort((a, b) => b.path.compareTo(a.path));
        if (mounted) setState(() => latest = files.firstOrNull);
      }
      final notice = File(p.join(home.base.path, 'restore-status.txt'));
      if (await notice.exists() && mounted) {
        final text = await notice.readAsString();
        if (mounted) setState(() => status = text);
      }
    } catch (_) {
      if (mounted) setState(() => status = '备份目录读取失败，请检查存储权限。');
    }
  }

  Future<void> create() async {
    if (!await ref
            .read(navigationSaveGuardProvider)
            .before(Uri(path: '/backup')) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    final file = await runUi(
      context,
      () async => (await ref.read(backupServiceProvider.future)).create(),
    );
    if (mounted) {
      setState(() {
        busy = false;
        if (file != null) {
          latest = file;
          status = '完整备份已创建，包含数据库和所引用附件；不包含API Key、SSH密码或私钥。';
        }
      });
    }
  }

  Future<void> export() async {
    if (latest == null) return;
    setState(() => busy = true);
    await runUi(context, () async {
      await FilePicker.saveFile(
        fileName: p.basename(latest!.path),
        bytes: await latest!.readAsBytes(),
        mimeType: 'application/zip',
      );
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> restore() async {
    setState(() => busy = true);
    await runUi(context, () async {
      final selected = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (selected == null) return;
      final home = await ref.read(dataHomeProvider.future);
      final imports = Directory(p.join(home.base.path, 'restore-import'));
      await imports.create(recursive: true);
      final file = File(
        p.join(imports.path, '${DateTime.now().microsecondsSinceEpoch}.zip'),
      );
      await file.create(exclusive: true);
      try {
        var size = 0;
        final out = await file.open(mode: FileMode.writeOnly);
        try {
          await for (final chunk in selected.readAsByteStream()) {
            size += chunk.length;
            if (size > maxBackupBytes) {
              throw const ToolFailure('备份文件超过250MB上限。');
            }
            await out.writeFrom(chunk);
          }
          await out.flush();
        } finally {
          await out.close();
        }
        final preview = await (await ref.read(backupServiceProvider.future))
            .inspect(file);
        if (!mounted) return;
        final confirmed = await ltConfirm(
          context,
          title: '校验通过，安排重启后恢复？',
          message:
              '备份时间：${readableTime(preview.createdAt)}\nSchema ${preview.schema}\n${preview.counts.entries.map((e) => '${e.key}：${e.value}').join('\n')}\n附件/数据库文件：${preview.files.length}\n\n退出并重新打开后启用新数据目录。恢复前的数据库与附件会完整保留，可回退。备份不含密钥；恢复后剪贴板监听关闭。',
          confirmLabel: '确认恢复',
        );
        if (!confirmed) return;
        await home.schedule(preview, confirmed: true);
        if (mounted) {
          setState(() => status = '已安排恢复。请退出并重新打开应用。重启前仍使用当前数据；密钥不会从备份恢复。');
        }
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> rollback() async {
    if (!await ltConfirm(
          context,
          title: '重启后回到恢复前的数据？',
          message: '保留当前恢复目录。退出并重开后使用上次恢复之前的数据目录；期间请勿继续编辑。',
          confirmLabel: '回到恢复前',
        ) ||
        !mounted) {
      return;
    }
    await runUi(context, () async {
      await (await ref.read(dataHomeProvider.future))
          .rollbackPointer(confirmed: true);
      if (mounted) setState(() => status = '回退指针已更新。请退出并重新打开应用。现有目录均已保留。');
    });
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('完整备份与恢复', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text(
            '包含本机数据库与所引用附件，逐文件SHA-256校验。恢复先校验，重启后启用新目录；原数据保留。不备份系统安全存储中的凭据。压缩上限250MB，展开上限500MB。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LTButton(
                label: '创建完整备份',
                onPressed: busy ? null : create,
                loading: busy,
              ),
              LTButton(
                label: '导出最近备份',
                onPressed: busy || latest == null ? null : export,
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '选择备份恢复',
                onPressed: busy ? null : restore,
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '恢复前数据回退',
                onPressed: busy ? null : rollback,
                style: LTButtonStyle.ghost,
              ),
            ],
          ),
          if (latest != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText('最近备份：${latest!.path}'),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(status!),
            ),
        ],
      ),
    ),
  );
}
