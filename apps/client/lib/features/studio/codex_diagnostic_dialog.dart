import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import 'codex_diagnostics.dart';

Future<void> showCodexDiagnostic(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _CodexDiagnosticDialog(),
);

class _CodexDiagnosticDialog extends StatefulWidget {
  const _CodexDiagnosticDialog();
  @override
  State<_CodexDiagnosticDialog> createState() => _CodexDiagnosticDialogState();
}

class _CodexDiagnosticDialogState extends State<_CodexDiagnosticDialog> {
  String path = '', error = '';
  bool approved = false, busy = false;
  CodexDiagnostic? result;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Codex 本地诊断'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '检查用户选择的原生 Codex 程序版本与官方协议字段。此入口尚不能创建编程任务，也未验证账号登录或模型连接。',
            ),
            const SizedBox(height: 16),
            SelectableText(path.isEmpty ? '尚未选择 codex.exe' : path),
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('选择 Codex 程序'),
              onPressed: !Platform.isWindows || busy
                  ? null
                  : () async {
                      final file = await FilePicker.pickFile(
                        type: FileType.custom,
                        allowedExtensions: ['exe'],
                      );
                      if (file != null && mounted) {
                        setState(() {
                          path = file.path ?? '';
                          approved = false;
                          result = null;
                          error = '';
                        });
                      }
                    },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: approved,
              onChanged: busy || path.isEmpty
                  ? null
                  : (v) => setState(() => approved = v == true),
              title: const Text('我确认该程序可信，允许运行版本查询和 Schema 导出'),
              subtitle: const Text('仅执行固定元数据参数；不运行模型任务，不修改项目，不读取登录文件。'),
            ),
            if (!Platform.isWindows)
              const Text('需要 Windows 桌面执行器；当前设备不能运行本地 Codex。'),
            if (result case final r?) ...[
              const Divider(),
              Text(r.version),
              const SizedBox(height: 8),
              Text(r.explanation),
              const SizedBox(height: 8),
              SelectableText(
                'Schema SHA-256\n${r.schemaChecksum}',
                style: const TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 8),
              const Text('真实 Codex 会话：UNVERIFIED。诊断成功不代表模型任务接入完成。'),
            ],
            if (error.isNotEmpty)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      LTButton(
        label: '运行本地诊断',
        loading: busy,
        onPressed: !Platform.isWindows || !approved || busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  error = '';
                });
                try {
                  final value = await CodexDiagnostics().inspect(path);
                  if (mounted) setState(() => result = value);
                } catch (e) {
                  if (mounted) {
                    setState(
                      () => error = e is ToolFailure
                          ? e.message
                          : '本地诊断失败；没有启动模型任务。',
                    );
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
      ),
    ],
  );
}
