import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import '../utilities/job_widgets.dart';
import '../utilities/utility_providers.dart';
import 'workflow_service.dart';

class LocalWorkflowPage extends ConsumerStatefulWidget {
  const LocalWorkflowPage({super.key});
  @override
  ConsumerState<LocalWorkflowPage> createState() => _LocalWorkflowPageState();
}

class _LocalWorkflowPageState extends ConsumerState<LocalWorkflowPage> {
  String? input, output;
  final steps = <String>['copy'];
  Future<void> run() async {
    final source = input, directory = output, plan = List<String>.of(steps);
    if (source == null || directory == null) return;
    if (!await ltConfirm(
      context,
      title: '运行文件工作流？',
      message:
          '输入：$source\n步骤：${plan.join(' → ')} → SHA256/512 → 导出\n输出目录：$directory\n原文件保留，输出采用新名称，不执行任何脚本。',
    )) {
      return;
    }
    final service = LocalWorkflowService(
      ref.read(recordStoreProvider),
      ref.read(utilityFilesProvider),
    );
    await ref
        .read(utilityJobsProvider)
        .submit(
          'workflow',
          'run',
          '本地文件工作流',
          {'input': source, 'outputDirectory': directory, 'steps': plan},
          confirmed: true,
          run: (job, _) async =>
              (await service.run(source, directory, plan, job)).id,
        );
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'AUTOMATION',
    title: 'Local Workflow',
    description: '选择文件 → 表单式处理步骤 → 两种哈希 → 新文件导出。复用现有任务队列；只处理数据，不运行脚本。',
    children: [
      LTToolbar(
        children: [
          TextButton(
            onPressed: () => runUi(context, () async {
              final file = await FilePicker.pickFile(dialogTitle: '选择工作流输入文件');
              if (file?.path != null && mounted) {
                setState(() => input = file!.path);
              }
            }),
            child: const Text('选择输入文件'),
          ),
          TextButton(
            onPressed: () => runUi(context, () async {
              final path = await FilePicker.getDirectoryPath(
                dialogTitle: '选择工作流输出目录',
              );
              if (path != null && mounted) setState(() => output = path);
            }),
            child: const Text('选择输出目录'),
          ),
          LTButton(
            label: '确认并运行',
            onPressed: input == null || output == null
                ? null
                : () => runUi(context, run),
          ),
        ],
      ),
      Text('输入：${input ?? '未选择'}\n输出：${output ?? '未选择'}'),
      for (var i = 0; i < steps.length; i++)
        ListTile(
          title: Text('步骤${i + 1} · ${steps[i]}'),
          trailing: IconButton(
            tooltip: '移除步骤',
            onPressed: steps.length == 1
                ? null
                : () => setState(() => steps.removeAt(i)),
            icon: const Icon(Icons.remove_circle_outline),
          ),
        ),
      Wrap(
        children: [
          for (final step in workflowSteps)
            TextButton(
              onPressed: steps.length >= 8
                  ? null
                  : () => setState(() => steps.add(step)),
              child: Text('添加 $step'),
            ),
          TextButton(
            onPressed: () => runUi(context, () async {
              final values = await ltEditForm(
                context,
                title: '保存工作流模板',
                fields: [const LTField('name', '名称', required: true)],
              );
              if (values != null) {
                await ref
                    .read(recordStoreProvider)
                    .create(
                      'workflow_template',
                      values['name']!,
                      data: {
                        'steps': List<String>.of(steps),
                        'syncAllowed': false,
                      },
                    );
              }
            }),
            child: const Text('保存模板'),
          ),
        ],
      ),
      const Text('格式转换最多2MiB；复制/哈希最多1GiB。模板不保存输入路径或输出授权，每次运行重新确认。'),
      for (final row
          in ref.watch(recordsProvider('workflow_template')).asData?.value ??
              [])
        ListTile(
          title: Text(row.title),
          subtitle: Text(row.strings('steps').join(' → ')),
          onTap: () => setState(() {
            steps
              ..clear()
              ..addAll(row.strings('steps'));
          }),
        ),
      const UtilityJobHistory(moduleId: 'workflow'),
    ],
  );
}
