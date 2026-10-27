import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';
import 'environment_snapshot.dart';
import 'utility_providers.dart';
import 'job_widgets.dart';

class EnvironmentSnapshotPage extends ConsumerStatefulWidget {
  const EnvironmentSnapshotPage({super.key});
  @override
  ConsumerState<EnvironmentSnapshotPage> createState() =>
      _EnvironmentSnapshotPageState();
}

class _EnvironmentSnapshotPageState
    extends ConsumerState<EnvironmentSnapshotPage> {
  final configPaths = <String>[];
  String? output;
  EnvironmentPlan? preview;
  bool busy = false;
  Future<void> addConfigs() async => runUi(context, () async {
    final chosen = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'json',
        'yaml',
        'yml',
        'toml',
        'ini',
        'txt',
        'ps1',
        'cfg',
        'conf',
      ],
    );
    final paths = chosen.map((f) => f.path).whereType<String>().toList();
    if (configPaths.length + paths.length > 10) {
      throw const ToolFailure('最多选择10个文本配置。');
    }
    if (mounted) {
      setState(() {
        configPaths.addAll(paths.where((p) => !configPaths.contains(p)));
        preview = null;
      });
    }
  });
  Future<void> plan() async => runUi(context, () async {
    setState(() => busy = true);
    try {
      final value = await ref
          .read(environmentSnapshotProvider)
          .plan(List.of(configPaths));
      if (mounted) setState(() => preview = value);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  });
  Future<void> export() async => runUi(context, () async {
    final plan = preview, parent = output;
    if (plan == null || parent == null) throw const ToolFailure('请先预检并选择输出目录。');
    if (!await ltConfirm(
      context,
      title: '收集版本并导出环境快照？',
      message:
          '将在已预览的路径执行固定版本命令，并尝试winget export/Get-AppxPackage只读清单，不接受源协议或安装软件。\n输出到 $parent 下的新目录，含4份报告与已预览配置副本。\n变量仅导出名称；请确认已审阅下方配置预览。',
    )) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(environmentSnapshotProvider);
    await ref
        .read(utilityJobsProvider)
        .submit(
          'environment_snapshot',
          'collect',
          'Windows环境快照',
          {
            'outputParent': parent,
            'tools': plan.tools.map((t) => t['id']).toList(),
            'configNames': plan.configs.map((c) => c.name).toList(),
          },
          confirmed: true,
          retainedBytes: plan.configs.fold<int>(
            0,
            (n, c) => n + c.content.length,
          ),
          run: (job, _) async => (await service.collect(plan, parent, job)).id,
        );
  });
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('Windows环境快照', style: TextStyle(fontSize: 24)),
      const Text(
        '用户主动收集：系统/CPU/内存/固定磁盘、可获取的开发工具版本和软件清单。默认不复制任何配置或环境变量值。可选配置先脱敏预览；本版提供手动恢复指南，不自动覆盖系统设置。',
      ),
      LTToolbar(
        children: [
          LTButton(
            label: '选择可选文本配置',
            onPressed: busy || !Platform.isWindows ? null : addConfigs,
          ),
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    configPaths.clear();
                    preview = null;
                  }),
            child: const Text('清空配置选择'),
          ),
          TextButton(
            onPressed: busy || !Platform.isWindows
                ? null
                : () => runUi(context, () async {
                    final path = await FilePicker.getDirectoryPath(
                      dialogTitle: '选择环境快照输出父目录',
                    );
                    if (mounted && path != null) setState(() => output = path);
                  }),
            child: const Text('选择输出目录'),
          ),
          LTButton(
            label: '只读预检与隐私预览',
            onPressed: busy || !Platform.isWindows ? null : plan,
          ),
        ],
      ),
      Text('可选配置${configPaths.length}个 · 输出：${output ?? '尚未选择'}'),
      for (final path in configPaths) Text(path),
      if (busy) const LinearProgressIndicator(),
      if (preview != null) ...[
        const SizedBox(height: 16),
        const Text('系统与工具预检', style: TextStyle(fontSize: 18)),
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(preview!.hardware),
        ),
        for (final tool in preview!.tools)
          ListTile(
            title: Text(
              '${tool['id']} · ${tool['available'] == true ? '已定位，导出时读取版本' : '不可用'}',
            ),
            subtitle: SelectableText(
              tool['available'] == true
                  ? '${tool['path']}\nSHA256 ${tool['sha256']}'
                  : '${tool['reason']}',
            ),
          ),
        const Text('配置预览（请先人工核对；检测无法保证识别所有自定义秘密）'),
        for (final config in preview!.configs)
          ExpansionTile(
            title: Text(
              '${config.name} · ${config.rejected.isNotEmpty ? '拒绝导出' : '替换${config.redactions}处'}',
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  config.rejected.isNotEmpty
                      ? config.rejected
                      : utf8.decode(config.content),
                ),
              ),
            ],
          ),
        LTButton(
          label: '确认并导出四份报告',
          onPressed: output == null || busy ? null : export,
        ),
      ],
      const SizedBox(height: 16),
      const UtilityJobHistory(moduleId: 'environment_snapshot'),
      ref
          .watch(recordsProvider('environment_snapshot'))
          .when(
            loading: () => const LTLoadingState(),
            error: (_, _) => const LTErrorState(),
            data: (rows) => Column(
              children: [
                for (final row in rows)
                  LTCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${row.title} · ${const {'partial': '部分工具不可获取，详见报告', 'complete': '已收集', 'processing': '收集中', 'failed': '失败，已写文件保留', 'cancelled': '已取消，已写文件保留'}[row.text('status')] ?? row.text('status')} · ${readableTime(row.createdAt)}',
                        ),
                        SelectableText(row.text('outputDirectory')),
                        if (row.text('error').isNotEmpty)
                          Text(row.text('error')),
                        for (final warning in row.strings('warnings'))
                          Text(warning),
                        TextButton(
                          onPressed: () => runUi(
                            context,
                            () => openTarget(
                              context,
                              ref,
                              TargetAction(
                                'folder',
                                row.text('outputDirectory'),
                              ),
                            ),
                          ),
                          child: const Text('打开报告与恢复指南目录'),
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
