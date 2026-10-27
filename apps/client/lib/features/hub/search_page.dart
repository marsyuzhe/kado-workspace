import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'hub_actions.dart';
import 'search_service.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final query = TextEditingController();
  final focus = FocusNode();
  Timer? timer;
  List<SearchResult> results = [];
  bool busy = false;
  String? error, filter;
  int selected = 0, generation = 0;
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(handleKey);
  }

  @override
  void dispose() {
    timer?.cancel();
    HardwareKeyboard.instance.removeHandler(handleKey);
    query.dispose();
    focus.dispose();
    super.dispose();
  }

  bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      context.go('/');
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        results.isNotEmpty) {
      setState(() => selected = (selected + 1) % results.length);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && results.isNotEmpty) {
      setState(
        () => selected = (selected - 1 + results.length) % results.length,
      );
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && results.isNotEmpty) {
      openResult(results[selected]);
      return true;
    }
    return false;
  }

  void changed(String value) {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 220), load);
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final page = await ref
          .read(searchServiceProvider)
          .search(
            query.text,
            sourceFilters: filter == null ? {} : {filter!},
            limit: 100,
          );
      if (!mounted || request != generation) return;
      final grouped = <String, List<SearchResult>>{};
      for (final r in page.results) {
        grouped.putIfAbsent(r.sourceModule, () => []).add(r);
      }
      setState(() {
        results = grouped.values.expand((r) => r).toList();
        selected = 0;
        busy = false;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          error = '搜索未能完成，请重新输入或重试。';
          busy = false;
        });
      }
    }
  }

  Future<void> openResult(SearchResult result) => runUi(
    context,
    () => openTarget(context, ref, result.action, title: result.title),
  );
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    return PageFrame(
      eyebrow: 'SEARCH YOUR WORKSPACE',
      title: '应用内搜索',
      description: '搜索本地模块、收藏、剪贴板、笔记、文件元数据、提示词和服务器。↑↓选择，Enter打开，Esc返回。',
      children: [
        TextField(
          controller: query,
          focusNode: focus,
          autofocus: true,
          onChanged: changed,
          decoration: const InputDecoration(
            hintText: '输入关键词，支持中文子串',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in {
              null: '全部',
              'hub': '收藏/工作台',
              'clipboard': '剪贴板/提示词',
              'memory': '笔记',
              'archive': '文件',
              'ai_desk': 'AI配置',
              'server': '服务器',
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: filter == entry.key,
                onSelected: (_) {
                  setState(() => filter = entry.key);
                  load();
                },
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (busy) const LinearProgressIndicator(),
        if (error != null) LTErrorState(message: error!, onRetry: load),
        if (!busy && error == null && results.isEmpty)
          LTEmptyState(
            title: query.text.trim().isEmpty ? '从一个关键词开始' : '没有找到相关内容',
            message: query.text.trim().isEmpty
                ? '输入模块名称或已保存内容。没有预置虚假记录。'
                : '试试更短的关键词或切换来源。',
          ),
        for (var i = 0; i < results.length; i++) ...[
          if (i == 0 || results[i - 1].sourceModule != results[i].sourceModule)
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                _sourceName(results[i].sourceModule),
                style: TextStyle(color: t.textSecondary, fontSize: 12),
              ),
            ),
          Card(
            child: ListTile(
              selected: i == selected,
              selectedTileColor: t.accent.withValues(alpha: .08),
              leading: Icon(results[i].icon),
              title: _highlight(context, results[i].title, query.text),
              subtitle: results[i].subtitle.isEmpty
                  ? null
                  : Text(
                      results[i].subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: const Icon(Icons.arrow_forward, size: 18),
              onTap: () => openResult(results[i]),
            ),
          ),
        ],
      ],
    );
  }
}

String _sourceName(String source) =>
    {
      'hub': '工作台 / 收藏',
      'clipboard': '剪贴板 / 提示词',
      'memory': '记忆仓库',
      'archive': '文件管理',
      'ai_desk': 'AI控制台',
      'server': '服务器',
    }[source] ??
    source;
Widget _highlight(BuildContext context, String text, String query) {
  if (query.trim().isEmpty) return Text(text);
  final index = text.toLowerCase().indexOf(query.toLowerCase());
  if (index < 0) return Text(text);
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: text.substring(0, index)),
        TextSpan(
          text: text.substring(index, index + query.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        TextSpan(text: text.substring(index + query.length)),
      ],
    ),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );
}
