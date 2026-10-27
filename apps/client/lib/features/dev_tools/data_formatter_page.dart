import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'controlled_worker.dart';
import 'data_formatter_service.dart';
import 'dev_tool_widgets.dart';

class DataFormatterPage extends StatefulWidget {
  const DataFormatterPage({super.key});
  @override
  State<DataFormatterPage> createState() => _DataFormatterPageState();
}

class _DataFormatterPageState extends State<DataFormatterPage> {
  final input = TextEditingController(), other = TextEditingController();
  String mode = 'format', output = '', note = '';
  Object? tree;
  ControlledWorker? worker;
  @override
  void dispose() {
    worker?.cancel();
    input.dispose();
    other.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final task = ControlledWorker(formatData, {
      'text': input.text,
      'other': other.text,
      'mode': mode,
    }, timeout: const Duration(seconds: 5));
    setState(() => worker = task);
    try {
      final result = await task.result as Map;
      if (mounted) {
        setState(() {
          output = result['text'] as String;
          note = result['note'] as String;
          tree = result['value'];
        });
      }
    } finally {
      if (mounted) setState(() => worker = null);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'DEVELOPER TOOLS',
    title: 'Data Formatter',
    description: 'JSON / YAML解析、格式化和差异比较。输入最多2MiB，复杂YAML类型转换可能有损。',
    children: [
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: mode,
        decoration: const InputDecoration(labelText: '操作'),
        items: const [
          DropdownMenuItem(value: 'format', child: Text('JSON 格式化 / 验证')),
          DropdownMenuItem(value: 'minify', child: Text('JSON 压缩')),
          DropdownMenuItem(value: 'yaml-json', child: Text('YAML → JSON / 验证')),
          DropdownMenuItem(
            value: 'yaml-format',
            child: Text('YAML 规范化（YAML 1.2流式语法）'),
          ),
          DropdownMenuItem(
            value: 'json-yaml',
            child: Text('JSON → YAML 1.2流式语法'),
          ),
          DropdownMenuItem(value: 'diff', child: Text('两个JSON差异比较')),
        ],
        onChanged: worker != null ? null : (v) => setState(() => mode = v!),
      ),
      DevTextEditor(controller: input, label: '输入'),
      if (mode == 'diff') DevTextEditor(controller: other, label: '比较对象'),
      LTToolbar(
        children: [
          LTButton(
            label: '处理',
            onPressed: worker != null ? null : () => runUi(context, run),
          ),
          if (worker != null)
            TextButton(onPressed: worker!.cancel, child: const Text('取消')),
          TextButton(
            onPressed: () => runUi(context, () async {
              final text = await pickDevText();
              if (text != null) input.text = text;
            }),
            child: const Text('导入'),
          ),
          TextButton(
            onPressed: output.isEmpty ? null : () => copyDevText(output),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: output.isEmpty
                ? null
                : () => runUi(
                    context,
                    () => saveDevText(
                      'formatted.${mode.startsWith('yaml') || mode == 'json-yaml' ? 'yaml' : 'json'}',
                      output,
                    ),
                  ),
            child: const Text('导出'),
          ),
        ],
      ),
      if (worker != null) const LinearProgressIndicator(),
      if (note.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(note),
        ),
      if (output.isNotEmpty) ...[
        DevOutput(text: output),
        JsonTree(value: tree),
      ],
    ],
  );
}
