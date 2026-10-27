import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'controlled_worker.dart';
import 'regex_service.dart';
import 'dev_tool_widgets.dart';

class RegexLabPage extends ConsumerStatefulWidget {
  const RegexLabPage({super.key});
  @override
  ConsumerState<RegexLabPage> createState() => _RegexLabPageState();
}

class _RegexLabPageState extends ConsumerState<RegexLabPage> {
  final pattern = TextEditingController(),
      text = TextEditingController(),
      replacement = TextEditingController();
  bool sensitive = true, multiline = false, dotAll = false, unicode = false;
  String testedText = '';
  Map? output;
  ControlledWorker? worker;
  @override
  void dispose() {
    worker?.cancel();
    pattern.dispose();
    text.dispose();
    replacement.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final submittedPattern = pattern.text, submittedText = text.text;
    final store = ref.read(recordStoreProvider);
    final task = ControlledWorker(evaluateRegex, {
      'pattern': pattern.text,
      'text': text.text,
      'replacement': replacement.text,
      'caseSensitive': sensitive,
      'multiLine': multiline,
      'dotAll': dotAll,
      'unicode': unicode,
    }, timeout: const Duration(milliseconds: 1000));
    setState(() => worker = task);
    try {
      final result = await task.result as Map;
      if (!mounted) return;
      setState(() {
        output = result;
        testedText = submittedText;
      });
      await store.setSetting('dev.regex.last', submittedPattern);
      await store.transaction(() async {
        final old = await store.find(
          'regex_history',
          'pattern',
          submittedPattern,
        );
        final data = {'pattern': submittedPattern, 'syncAllowed': false};
        if (old == null) {
          await store.create(
            'regex_history',
            submittedPattern,
            body: submittedPattern,
            data: data,
          );
        } else {
          await store.save(old.copyWith(data: data));
        }
      });
    } finally {
      if (mounted) setState(() => worker = null);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'DEVELOPER TOOLS',
    title: 'Regex Lab',
    description: 'Dart正则，1秒执行预算，可取消；最多200000字符 / 1000项匹配。',
    children: [
      DevTextEditor(controller: pattern, label: '表达式', lines: 2),
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            label: const Text('区分大小写'),
            selected: sensitive,
            onSelected: (v) => setState(() => sensitive = v),
          ),
          FilterChip(
            label: const Text('Multiline'),
            selected: multiline,
            onSelected: (v) => setState(() => multiline = v),
          ),
          FilterChip(
            label: const Text('DotAll'),
            selected: dotAll,
            onSelected: (v) => setState(() => dotAll = v),
          ),
          FilterChip(
            label: const Text('Unicode'),
            selected: unicode,
            onSelected: (v) => setState(() => unicode = v),
          ),
        ],
      ),
      DevTextEditor(controller: text, label: '测试文本'),
      DevTextEditor(
        controller: replacement,
        label: r'替换模板（$1 / ${name} / $$）',
        lines: 2,
      ),
      LTToolbar(
        children: [
          LTButton(
            label: '匹配与替换',
            onPressed: worker != null ? null : () => runUi(context, run),
          ),
          if (worker != null)
            TextButton(onPressed: worker!.cancel, child: const Text('取消')),
          TextButton(
            onPressed: () => runUi(context, () async {
              pattern.text =
                  await ref
                      .read(recordStoreProvider)
                      .setting('dev.regex.last') ??
                  '';
            }),
            child: const Text('上次表达式'),
          ),
          TextButton(
            onPressed: () => runUi(context, () async {
              final fields = await ltEditForm(
                context,
                title: '保存常用规则',
                fields: [const LTField('name', '名称', required: true)],
              );
              if (fields == null) return;
              await ref
                  .read(recordStoreProvider)
                  .create(
                    'regex_rule',
                    fields['name']!,
                    body: pattern.text,
                    data: {
                      'caseSensitive': sensitive,
                      'multiLine': multiline,
                      'dotAll': dotAll,
                      'unicode': unicode,
                      'syncAllowed': false,
                    },
                  );
            }),
            child: const Text('保存规则'),
          ),
        ],
      ),
      for (final rule
          in ref.watch(recordsProvider('regex_rule')).asData?.value ?? [])
        ListTile(
          title: Text(rule.title),
          subtitle: Text(
            rule.body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => setState(() {
            pattern.text = rule.body;
            sensitive = rule.flag('caseSensitive');
            multiline = rule.flag('multiLine');
            dotAll = rule.flag('dotAll');
            unicode = rule.flag('unicode');
          }),
        ),
      ExpansionTile(
        title: const Text('表达式历史（最近20条）'),
        children: [
          for (final history
              in (ref.watch(recordsProvider('regex_history')).asData?.value ??
                      [])
                  .take(20))
            ListTile(
              title: Text(
                history.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => setState(() => pattern.text = history.body),
            ),
        ],
      ),
      if (worker != null) const LinearProgressIndicator(),
      if (output != null) ...[
        Text(
          '${(output!['matches'] as List).length}${output!['truncated'] == true ? '+' : ''}项匹配 · ${output!['note']}',
        ),
        _MatchHighlight(text: testedText, matches: output!['matches'] as List),
        JsonTree(value: output!['matches'], label: '匹配范围与分组'),
        const LTSectionHeader('替换预览'),
        DevOutput(text: output!['replacement'] as String),
        TextButton(
          onPressed: () => copyDevText(output!['replacement'] as String),
          child: const Text('复制替换结果'),
        ),
      ],
    ],
  );
}

class _MatchHighlight extends StatelessWidget {
  const _MatchHighlight({required this.text, required this.matches});
  final String text;
  final List matches;
  @override
  Widget build(BuildContext context) {
    final end = text.length.clamp(0, 20000), spans = <TextSpan>[];
    var cursor = 0;
    for (final raw in matches) {
      final m = raw as Map, start = m['start'] as int, stop = m['end'] as int;
      if (start >= end) break;
      if (start < cursor || stop > text.length) continue;
      spans.add(TextSpan(text: text.substring(cursor, start)));
      spans.add(
        TextSpan(
          text: text.substring(start, stop.clamp(0, end)),
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        ),
      );
      cursor = stop.clamp(0, end);
    }
    spans.add(TextSpan(text: text.substring(cursor, end)));
    return LTCard(
      child: SelectableText.rich(
        TextSpan(children: spans),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
  }
}
