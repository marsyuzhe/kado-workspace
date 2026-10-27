import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import '../archive/archive_service.dart';
import '../utilities/utility_providers.dart';
import 'controlled_worker.dart';
import 'dev_tool_widgets.dart';
import 'log_service.dart';

class LogViewerPage extends ConsumerStatefulWidget {
  const LogViewerPage({super.key});
  @override
  ConsumerState<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends ConsumerState<LogViewerPage> {
  final query = TextEditingController(),
      from = TextEditingController(),
      to = TextEditingController();
  String? path;
  String level = '';
  Map? page;
  ControlledWorker? worker;
  @override
  void dispose() {
    worker?.cancel();
    query.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Map<String, dynamic> args({bool next = false}) => {
    'path': path,
    'query': query.text,
    'level': level,
    'from': from.text,
    'to': to.text,
    if (next && page != null) ...{
      'offset': page!['nextOffset'],
      'line': page!['line'],
      'size': page!['size'],
      'modified': page!['modified'],
    },
  };
  Future<void> load({bool next = false}) async {
    if (path == null) return;
    for (final value in [from.text, to.text]) {
      if (value.isNotEmpty && DateTime.tryParse(value) == null) {
        throw const FormatException('时间使用ISO8601格式。');
      }
    }
    final task = ControlledWorker(
      scanLog,
      args(next: next),
      timeout: const Duration(seconds: 30),
    );
    setState(() => worker = task);
    try {
      final result = await task.result as Map;
      if (mounted) setState(() => page = result);
    } finally {
      if (mounted) setState(() => worker = null);
    }
  }

  Future<void> export() async {
    if (path == null) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择筛选结果输出目录',
    );
    if (directory == null) return;
    final temp = await Directory.systemTemp.createTemp('kado-log-export-'),
        output = File(p.join(temp.path, 'filtered.log'));
    await output.create(exclusive: true);
    final task = ControlledWorker(scanLog, {
      ...args(),
      'output': output.path,
    }, timeout: const Duration(seconds: 60));
    setState(() => worker = task);
    try {
      final result = await task.result as Map;
      await ref
          .read(utilityFilesProvider)
          .exportFile(
            directory,
            'filtered-${DateTime.now().microsecondsSinceEpoch}.log',
            output,
            TaskCancellation(),
          );
      if (mounted) ltMessage(context, '已导出${result['matched']}行（超长行有明确截断标记）。');
    } finally {
      if (mounted) setState(() => worker = null);
      if (await output.exists()) await output.delete();
      await temp.delete();
    }
  }

  Future<void> ai(String text) async {
    final values = await ltEditForm(
      context,
      title: '检查脱敏内容，再插入AI草稿',
      description: '自动识别可能遗漏。请检查敏感信息；这里只准备草稿，不自动发送。',
      fields: [
        LTField(
          'text',
          '将发送的内容',
          initial: redactLog(text),
          multiline: true,
          required: true,
        ),
      ],
      submit: '插入草稿',
    );
    if (values == null || !mounted) return;
    ref.read(aiDraftProvider.notifier).setDraft('请分析以下日志：\n${values['text']}');
    context.go('/modules/ai_desk');
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'SYSTEM & NETWORK',
    title: 'Log Viewer',
    description:
        '流式读取TXT / LOG / JSON Lines；200行分页，单行预览16KiB上限。时间筛选排除无法解析时间的行。',
    children: [
      LTToolbar(
        children: [
          LTButton(
            label: '选择日志',
            onPressed: worker != null
                ? null
                : () => runUi(context, () async {
                    final file = await FilePicker.pickFile(
                      dialogTitle: '选择日志文件',
                    );
                    if (file?.path == null) return;
                    setState(() {
                      path = file!.path;
                      page = null;
                    });
                    await load();
                  }),
          ),
          TextButton(
            onPressed: path == null || worker != null
                ? null
                : () => runUi(context, () => load()),
            child: const Text('筛选 / 第一页'),
          ),
          TextButton(
            onPressed: page?['more'] != true || worker != null
                ? null
                : () => runUi(context, () => load(next: true)),
            child: const Text('下一页'),
          ),
          TextButton(
            onPressed: path == null || worker != null
                ? null
                : () => runUi(context, export),
            child: const Text('导出全部筛选结果'),
          ),
          if (worker != null)
            TextButton(onPressed: worker!.cancel, child: const Text('取消')),
        ],
      ),
      if (path != null) Text(p.basename(path!)),
      LTTextField(controller: query, label: '关键词（不区分大小写）'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          DropdownMenu<String>(
            initialSelection: level,
            label: const Text('级别'),
            dropdownMenuEntries: [
              const DropdownMenuEntry(value: '', label: '全部'),
              for (final l in [
                'ERROR',
                'WARN',
                'INFO',
                'DEBUG',
                'TRACE',
                'FATAL',
              ])
                DropdownMenuEntry(value: l, label: l),
            ],
            onSelected: (v) => setState(() => level = v!),
          ),
          SizedBox(
            width: 260,
            child: LTTextField(controller: from, label: '开始时间 ISO8601（可选）'),
          ),
          SizedBox(
            width: 260,
            child: LTTextField(controller: to, label: '结束时间 ISO8601（可选）'),
          ),
        ],
      ),
      if (worker != null) const LinearProgressIndicator(),
      if (page != null) ...[
        Text(
          '本页${(page!['items'] as List).length}行 · 扫描至行${page!['line']} / byte ${page!['nextOffset']}',
        ),
        TextButton(
          onPressed: () => copyDevText(
            (page!['items'] as List).map((r) => r['text']).join('\n'),
          ),
          child: const Text('复制本页'),
        ),
        for (final raw in page!['items'] as List)
          LTCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '行${raw['line']} · ${raw['level']} ${raw['truncated'] == true ? '· 超长行已截断' : ''}',
                ),
                _HighlightedLog(text: raw['text'] as String, query: query.text),
                TextButton(
                  onPressed: () =>
                      runUi(context, () => ai(raw['text'] as String)),
                  child: const Text('脱敏并插入AI草稿'),
                ),
              ],
            ),
          ),
      ],
    ],
  );
}

class _HighlightedLog extends StatelessWidget {
  const _HighlightedLog({required this.text, required this.query});
  final String text, query;
  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      );
    }
    final spans = <TextSpan>[];
    var start = 0;
    for (final match in RegExp(
      RegExp.escape(query),
      caseSensitive: false,
    ).allMatches(text)) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
      spans.add(
        TextSpan(
          text: match[0],
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        ),
      );
      start = match.end;
    }
    spans.add(TextSpan(text: text.substring(start)));
    return SelectableText.rich(
      TextSpan(children: spans),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    );
  }
}
