import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'dev_tool_widgets.dart';
import 'snippet_repository.dart';

final snippetRepositoryProvider = Provider(
  (ref) => SnippetRepository(ref.watch(recordStoreProvider)),
);
final snippetSearchProvider = FutureProvider.autoDispose
    .family<List<ToolRecord>, (String, bool)>((ref, args) async {
      ref.watch(recordsProvider('dev_snippet'));
      return ref
          .watch(snippetRepositoryProvider)
          .search(args.$1, favorites: args.$2);
    });

Future<void> saveSnippetDialog(
  BuildContext context,
  WidgetRef ref, {
  String code = '',
  String sourceId = '',
  ToolRecord? existing,
}) async {
  final values = await ltEditForm(
    context,
    title: existing == null ? '保存代码片段' : '编辑代码片段',
    fields: [
      LTField('name', '名称', initial: existing?.title ?? '', required: true),
      LTField(
        'code',
        '代码（仅保存，不执行）',
        initial: existing?.body ?? code,
        multiline: true,
        required: true,
      ),
      LTField(
        'language',
        '语言',
        initial: existing?.text('language') ?? 'Text',
        options: {for (final l in snippetLanguages) l: l},
      ),
      LTField('category', '分类', initial: existing?.text('category') ?? ''),
      LTField(
        'tags',
        '标签（逗号分隔）',
        initial: existing?.strings('tags').join(',') ?? '',
      ),
    ],
  );
  if (values == null) return;
  await ref
      .read(snippetRepositoryProvider)
      .save(
        values['name']!,
        values['code']!,
        language: values['language']!,
        category: values['category']!,
        tags: values['tags']!
            .split(RegExp('[,，]'))
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toList(),
        favorite: existing?.flag('favorite') ?? false,
        sourceId: sourceId,
        existing: existing,
      );
}

class SnippetLibraryPage extends ConsumerStatefulWidget {
  const SnippetLibraryPage({super.key, this.initialId});
  final String? initialId;
  @override
  ConsumerState<SnippetLibraryPage> createState() => _SnippetLibraryPageState();
}

class _SnippetLibraryPageState extends ConsumerState<SnippetLibraryPage> {
  String query = '';
  bool favorites = false;
  Timer? debounce;
  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.initialId == null
        ? ref.watch(snippetSearchProvider((query, favorites)))
        : ref
              .watch(recordByIdProvider(widget.initialId!))
              .whenData((r) => r == null ? <ToolRecord>[] : [r]);
    return PageFrame(
      eyebrow: 'DEVELOPER TOOLS',
      title: 'Snippet Library',
      description: '保存、搜索与复制代码。共享本地内容存储，不执行脚本。每页最多200条。',
      children: [
        LTToolbar(
          children: [
            LTButton(
              label: '新增片段',
              onPressed: () =>
                  runUi(context, () => saveSnippetDialog(context, ref)),
            ),
            FilterChip(
              label: const Text('收藏'),
              selected: favorites,
              onSelected: (v) => setState(() => favorites = v),
            ),
            TextButton(
              onPressed: () => runUi(context, () async {
                final text = await pickDevText();
                if (text == null) return;
                final parsed = jsonDecode(text) as Map,
                    items = parsed['items'] as List;
                if (!context.mounted ||
                    !await ltConfirm(
                      context,
                      title: '导入片段？',
                      message: '${items.length}条；保存为新记录，不执行代码。',
                    )) {
                  return;
                }
                await ref.read(snippetRepositoryProvider).importJson(text);
              }),
              child: const Text('导入JSON'),
            ),
            TextButton(
              onPressed: () => runUi(context, () async {
                final text = await ref
                    .read(snippetRepositoryProvider)
                    .exportAll();
                await saveDevText('snippets.json', text);
              }),
              child: const Text('导出全部'),
            ),
            TextButton(
              onPressed: rows.asData == null
                  ? null
                  : () => runUi(
                      context,
                      () => saveDevText(
                        'snippets-filtered.json',
                        ref
                            .read(snippetRepositoryProvider)
                            .exportJson(rows.asData!.value),
                      ),
                    ),
              child: const Text('导出筛选结果'),
            ),
          ],
        ),
        LTTextField(
          label: '搜索名称、代码、语言、分类或标签',
          onChanged: (v) {
            debounce?.cancel();
            debounce = Timer(
              const Duration(milliseconds: 200),
              () => setState(() => query = v),
            );
          },
        ),
        rows.when(
          loading: () => const LTLoadingState(),
          error: (_, _) => const LTErrorState(),
          data: (items) => Column(
            children: [
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('没有匹配的代码片段。'),
                ),
              for (final row in items)
                LTCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(row.title),
                        subtitle: Text(
                          '${row.text('language')} · ${row.text('category')} · ${row.strings('tags').join(', ')}',
                        ),
                        trailing: IconButton(
                          tooltip: '收藏片段',
                          icon: Icon(
                            row.flag('favorite')
                                ? Icons.star
                                : Icons.star_border,
                          ),
                          onPressed: () => runUi(
                            context,
                            () => ref
                                .read(recordStoreProvider)
                                .save(
                                  row.copyWith(
                                    data: {
                                      ...row.data,
                                      'favorite': !row.flag('favorite'),
                                    },
                                  ),
                                ),
                          ),
                        ),
                      ),
                      CodeHighlight(
                        code: row.body,
                        language: row.text('language'),
                      ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: () => copyDevText(row.body),
                            child: const Text('复制'),
                          ),
                          TextButton(
                            onPressed: () => runUi(
                              context,
                              () => saveSnippetDialog(
                                context,
                                ref,
                                existing: row,
                              ),
                            ),
                            child: const Text('编辑'),
                          ),
                          TextButton(
                            onPressed: () => runUi(context, () async {
                              if (await ltConfirm(
                                context,
                                title: '删除片段？',
                                message: row.title,
                              )) {
                                await ref.read(recordStoreProvider).delete(row);
                              }
                            }),
                            child: const Text('删除'),
                          ),
                        ],
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
}

/// Lightweight display highlighting, not an IDE/parser. Preview is bounded;
/// copying and exports retain the complete code.
class CodeHighlight extends StatelessWidget {
  const CodeHighlight({super.key, required this.code, required this.language});
  final String code, language;
  @override
  Widget build(BuildContext context) {
    final text = code.length > 12000
        ? '${code.substring(0, 12000)}\n…预览截断'
        : code;
    final tokens = RegExp(
      r'''//[^\n]*|\#[^\n]*|'[^'\n]*'|"[^"\n]*"|\b(?:if|else|for|while|return|class|def|fn|let|var|final|const|import|from|SELECT|FROM|WHERE|function|async|await|true|false|null)\b|\b\d+(?:\.\d+)?\b''',
    );
    final spans = <TextSpan>[];
    var end = 0;
    for (final match in tokens.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(end, match.start)));
      spans.add(
        TextSpan(
          text: match[0],
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      );
      end = match.end;
    }
    spans.add(TextSpan(text: text.substring(end)));
    return SelectableText.rich(
      TextSpan(children: spans),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    );
  }
}
