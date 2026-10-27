import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/storage/selected_input.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'controlled_worker.dart';
import 'dev_tool_widgets.dart';
import 'project_inspection_service.dart';

class ProjectInspectionPage extends StatefulWidget {
  const ProjectInspectionPage({super.key, this.environment = false});
  final bool environment;
  @override
  State<ProjectInspectionPage> createState() => _ProjectInspectionPageState();
}

class _ProjectInspectionPageState extends State<ProjectInspectionPage> {
  final inputs = <String, String>{};
  Map? result;
  ControlledWorker? worker;
  @override
  void dispose() {
    worker?.cancel();
    super.dispose();
  }

  Future<void> manifest() async {
    final file = await FilePicker.pickFile(dialogTitle: '选择项目依赖配置');
    if (file == null) return;
    final text = utf8.decode(await readToolFile(file, 2 * 1024 * 1024));
    await execute(inspectDependencies, {'name': file.name, 'text': text});
  }

  Future<void> choose(String key) async {
    final file = await FilePicker.pickFile(
      dialogTitle: key.endsWith('Csv')
          ? '选择software-list.csv'
          : '选择environment.json',
    );
    if (file == null) return;
    final text = utf8.decode(await readToolFile(file, 8 * 1024 * 1024));
    if (mounted) setState(() => inputs[key] = text);
  }

  Future<void> execute(
    Object? Function(Object?) action,
    Map<String, dynamic> args,
  ) async {
    final task = ControlledWorker(
      action,
      args,
      timeout: const Duration(seconds: 10),
    );
    setState(() => worker = task);
    try {
      final value = await task.result as Map;
      if (mounted) setState(() => result = value);
    } finally {
      if (mounted) setState(() => worker = null);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'PROJECT TOOLS',
    title: widget.environment ? 'Environment Diff' : 'Dependency Inspector',
    description: widget.environment
        ? '选择两次已导出的环境快照；只比较名称和版本，不导出环境变量值。'
        : '主动选择单个项目配置。离线读取依赖约束，不安装依赖、不运行脚本，不推测漏洞。',
    children: [
      LTToolbar(
        children: [
          if (!widget.environment)
            LTButton(
              label: '选择依赖文件',
              onPressed: worker != null ? null : () => runUi(context, manifest),
            ),
          if (widget.environment) ...[
            for (final entry in {
              'before': '旧environment.json',
              'after': '新environment.json',
              'beforeCsv': '旧software-list.csv（可选）',
              'afterCsv': '新software-list.csv（可选）',
            }.entries)
              TextButton(
                onPressed: worker != null
                    ? null
                    : () => runUi(context, () => choose(entry.key)),
                child: Text(
                  '${inputs.containsKey(entry.key) ? '✓ ' : ''}${entry.value}',
                ),
              ),
            LTButton(
              label: '比较',
              onPressed:
                  worker != null ||
                      !inputs.containsKey('before') ||
                      !inputs.containsKey('after')
                  ? null
                  : () =>
                        runUi(context, () => execute(diffEnvironment, inputs)),
            ),
          ],
          if (worker != null)
            TextButton(onPressed: worker!.cancel, child: const Text('取消')),
          TextButton(
            onPressed: result == null
                ? null
                : () => runUi(
                    context,
                    () => saveDevText(
                      'inspection.json',
                      const JsonEncoder.withIndent('  ').convert(result),
                    ),
                  ),
            child: const Text('导出结果'),
          ),
        ],
      ),
      if (worker != null) const LinearProgressIndicator(),
      if (result != null) ...[
        Text('${result!['note']}'),
        JsonTree(value: result),
        DevOutput(text: const JsonEncoder.withIndent('  ').convert(result)),
      ],
    ],
  );
}
