import '../dev_tools/snippet_page.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';

class ClipboardPage extends ConsumerStatefulWidget {
  const ClipboardPage({super.key, this.recordId, this.initialPrompts = false});
  final String? recordId;
  final bool initialPrompts;
  @override
  ConsumerState<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends ConsumerState<ClipboardPage> {
  final search = TextEditingController();
  Timer? debounce;
  String tab = '全部';
  Set<String>? matches;
  bool searching = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    if (widget.initialPrompts) tab = '提示词';
    loadSelected();
  }

  Future<void> loadSelected() async {
    if (widget.recordId == null) return;
    final record = await ref.read(recordStoreProvider).get(widget.recordId!);
    if (mounted && record?.kind == 'prompt') setState(() => tab = '提示词');
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  bool get prompts => tab == '提示词';
  Future<void> loadSearch() async {
    final request = ++generation;
    final text = search.text.trim();
    if (text.isEmpty) {
      setState(() {
        matches = null;
        searching = false;
      });
      return;
    }
    setState(() => searching = true);
    final result = await runUi(
      context,
      () => ref
          .read(recordStoreProvider)
          .search(text, kinds: [prompts ? 'prompt' : 'clipboard'], limit: 500),
    );
    if (mounted && request == generation) {
      setState(() {
        matches = result?.map((r) => r.id).toSet() ?? {};
        searching = false;
      });
    }
  }

  Future<void> configure() async {
    final current = ref.read(clipboardProvider).config;
    final result = await ltEditForm(
      context,
      title: '剪贴板保留设置',
      description: '最多500条，文本≤64KB；PNG≤2MB、边长≤4096、最多838万像素。收藏不按期限自动清理。',
      fields: [
        LTField(
          'max',
          '历史数量上限',
          initial: current.maxItems.toString(),
          required: true,
        ),
        LTField(
          'days',
          '保留天数',
          initial: current.retentionDays.toString(),
          required: true,
        ),
      ],
    );
    if (result == null || !mounted) return;
    await runUi(context, () {
      final max = int.tryParse(result['max']!),
          days = int.tryParse(result['days']!);
      if (max == null || days == null) throw const ToolFailure('请输入有效整数。');
      return ref
          .read(clipboardProvider.notifier)
          .configure(current.copyWith(maxItems: max, retentionDays: days));
    });
  }

  Future<void> toggleListening() async {
    final current = ref.read(clipboardProvider).config;
    if (!current.enabled &&
        !await ltConfirm(
          context,
          title: '启用Windows剪贴板监听？',
          message: '应用运行期间会记录新复制的文本和受限图片，保存在本机。可以暂停、清空和设置保存期限。程序不能可靠识别所有密码或敏感信息；复制秘密前请暂停或开启私密模式。',
          confirmLabel: '明确启用',
        )) {
      return;
    }
    if (mounted) {
      await runUi(
        context,
        () => ref
            .read(clipboardProvider.notifier)
            .configure(
              current.copyWith(enabled: !current.enabled, paused: false),
            ),
      );
    }
  }

  Future<void> saveText({bool snippet = false, ToolRecord? existing}) async {
    final values = await ltEditForm(
      context,
      title: snippet ? '${existing == null ? '新建' : '编辑'}提示词/模板' : '手动保存文本',
      fields: [
        if (snippet)
          LTField(
            'title',
            '标题',
            initial: existing?.title ?? '',
            required: true,
          ),
        LTField(
          'body',
          '内容',
          initial: existing?.body ?? '',
          multiline: true,
          required: true,
        ),
        if (snippet) ...[
          LTField(
            'category',
            '分类',
            initial: existing?.text('category') ?? '提示词',
          ),
          LTField(
            'tags',
            '标签（逗号分隔）',
            initial: existing?.strings('tags').join(',') ?? '',
          ),
        ],
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      if (snippet) {
        await ref
            .read(clipboardRepositoryProvider)
            .snippet(
              values['title']!,
              values['body']!,
              category: values['category']!,
              tags: values['tags']!
                  .split(RegExp('[,，]'))
                  .map((v) => v.trim())
                  .where((v) => v.isNotEmpty)
                  .toList(),
              existing: existing,
            );
      } else {
        await ref.read(clipboardProvider.notifier).service.capture({
          'type': 'text',
          'text': values['body']!,
        });
      }
    }, success: '已保存到本机');
  }

  Future<void> action(ToolRecord record, String command) async {
    final repo = ref.read(clipboardRepositoryProvider),
        service = ref.read(clipboardProvider.notifier).service;
    if (command == 'edit') {
      await saveText(snippet: true, existing: record);
      return;
    }
    if (command == 'delete' &&
        !await ltConfirm(
          context,
          title: '删除这条记录？',
          message: '删除本机内容与对应受控附件，不修改系统剪贴板。',
          dangerous: true,
        )) {
      return;
    }
    if (!mounted) return;
    await runUi(context, () async {
      switch (command) {
        case 'snippet':
          await saveSnippetDialog(
            context,
            ref,
            code: record.body,
            sourceId: record.id,
          );
        case 'memory':
          final note = await ref
              .read(memoryRepositoryProvider)
              .createNote(
                record.title,
                body: record.body,
                sensitive: record.flag('isSensitive'),
                source: 'clipboard:${record.id}',
              );
          if (mounted) {
            context.go(
              Uri(
                path: '/modules/memory',
                queryParameters: {'id': note.id},
              ).toString(),
            );
          }
        case 'ai':
          ref.read(aiDraftProvider.notifier).setDraft(record.body);
          if (mounted) context.go('/modules/ai_desk');
        case 'copy':
          await service.copy(record);
          if (mounted) ltMessage(context, '已复制');
        case 'pin':
          await repo.pin(record, !record.flag('pinned'));
        case 'private':
          await repo.setPrivate(record, !record.flag('isSensitive'));
        case 'sync':
          await repo.setSyncAllowed(record, !record.flag('syncAllowed'));
        case 'code':
          await repo.store.save(
            record.copyWith(data: {...record.data, 'contentType': 'code'}),
          );
        case 'delete':
          await repo.remove(record);
        case 'export':
          final file = (await ref.read(ownedFilesProvider.future))
              .resolve(record.text('attachment'));
          await FilePicker.saveFile(
            fileName: 'clipboard.png',
            bytes: await file.readAsBytes(),
            mimeType: 'image/png',
          );
      }
    });
  }

  List<PopupMenuEntry<String>> menu(ToolRecord record) => [
    if (record.text('contentType') != 'image') ...[
      const PopupMenuItem(value: 'snippet', child: Text('保存到代码片段')),
      const PopupMenuItem(value: 'memory', child: Text('保存到记忆仓库')),
      const PopupMenuItem(value: 'ai', child: Text('插入AI草稿（不自动发送）')),
    ],
    const PopupMenuItem(value: 'copy', child: Text('重新复制')),
    PopupMenuItem(
      value: 'pin',
      child: Text(record.flag('pinned') ? '取消收藏' : '收藏'),
    ),
    if (record.kind == 'prompt')
      const PopupMenuItem(value: 'edit', child: Text('编辑提示词/模板')),
    if (record.kind == 'clipboard') ...[
      PopupMenuItem(
        value: 'private',
        child: Text(record.flag('isSensitive') ? '取消私密标记' : '标记为私密'),
      ),
      PopupMenuItem(
        value: 'sync',
        enabled: !record.flag('isSensitive'),
        child: Text(record.flag('syncAllowed') ? '撤销未来同步授权' : '允许未来同步（当前未连接）'),
      ),
      if (record.text('contentType') == 'text')
        const PopupMenuItem(value: 'code', child: Text('标记为代码片段')),
      if (record.text('contentType') == 'image')
        const PopupMenuItem(value: 'export', child: Text('导出图片')),
    ],
    const PopupMenuItem(value: 'delete', child: Text('删除')),
  ];
  Future<void> contextMenu(ToolRecord record, Offset position) async {
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final command = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & box.size,
      ),
      items: menu(record),
    );
    if (command != null && mounted) await action(record, command);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(clipboardProvider);
    final rows = ref.watch(recordsProvider(prompts ? 'prompt' : 'clipboard'));
    final all = rows.asData?.value ?? <ToolRecord>[];
    final filtered = all.where((r) {
      if (widget.recordId != null && r.id != widget.recordId) return false;
      if (matches != null && !matches!.contains(r.id)) return false;
      return switch (tab) {
        '收藏' => r.flag('pinned'),
        '文本' => r.text('contentType') == 'text',
        '图片' => r.text('contentType') == 'image',
        '链接' => r.text('contentType') == 'url',
        '代码' => r.text('contentType') == 'code',
        _ => true,
      };
    }).toList();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            runUi(
              context,
              () => ref.read(clipboardProvider.notifier).service.paste(),
            ),
      },
      child: LTScrollPage(
        title: '剪贴板',
        description: Platform.isWindows
            ? '记录由你主动启用。自动去重、暂停与数量/期限限制，内容默认不上传。'
            : '通过主动粘贴、手动保存和应用内复制管理内容；没有后台全局监听。',
        header: [
          if (widget.recordId != null)
            TextButton(
              onPressed: () => context.go('/modules/clipboard'),
              child: const Text('返回全部剪贴板记录'),
            ),
          LTToolbar(
            children: [
              LTButton(
                label: '主动粘贴',
                icon: Icons.content_paste,
                onPressed: state.loading
                    ? null
                    : () => runUi(
                        context,
                        () => ref
                            .read(clipboardProvider.notifier)
                            .service
                            .paste(),
                        success: '已保存到历史',
                      ),
              ),
              LTButton(
                label: '手动保存',
                style: LTButtonStyle.secondary,
                onPressed: () => saveText(),
              ),
              LTButton(
                label: '新建提示词',
                style: LTButtonStyle.secondary,
                onPressed: () => saveText(snippet: true),
              ),
              if (Platform.isWindows)
                LTButton(
                  label: state.config.enabled ? '关闭自动监听' : '启用自动监听',
                  style: LTButtonStyle.secondary,
                  onPressed: state.loading ? null : toggleListening,
                ),
              if (Platform.isWindows && state.config.enabled)
                LTButton(
                  label: state.config.paused ? '恢复监听' : '暂停监听',
                  style: LTButtonStyle.ghost,
                  onPressed: () => runUi(
                    context,
                    () => ref
                        .read(clipboardProvider.notifier)
                        .configure(
                          state.config.copyWith(paused: !state.config.paused),
                        ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LTBadge(
                state.listening
                    ? '监听正在运行'
                    : state.config.privateMode
                    ? '私密模式 · 自动监听暂停'
                    : state.config.paused
                    ? '自动监听已暂停'
                    : '自动监听未运行',
              ),
              FilterChip(
                label: const Text('私密模式'),
                selected: state.config.privateMode,
                onSelected: state.loading
                    ? null
                    : (v) => runUi(
                        context,
                        () => ref
                            .read(clipboardProvider.notifier)
                            .configure(state.config.copyWith(privateMode: v)),
                      ),
              ),
              LTButton(
                label: '保留设置',
                style: LTButtonStyle.ghost,
                onPressed: configure,
              ),
              LTButton(
                label: '清空历史',
                style: LTButtonStyle.ghost,
                onPressed: () async {
                  if (await ltConfirm(
                        context,
                        title: '清空剪贴板历史？',
                        message: '包括收藏的历史记录和对应图片。提示词模板会保留。此操作不能撤销。',
                        dangerous: true,
                      ) &&
                      context.mounted) {
                    await runUi(
                      context,
                      () => ref.read(clipboardRepositoryProvider).clear(),
                    );
                  }
                },
              ),
            ],
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(state.error!),
            ),
          const SizedBox(height: 16),
          LTSearchField(
            controller: search,
            hint: '搜索已保存的内容',
            onChanged: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 220), loadSearch);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in ['全部', '收藏', '文本', '图片', '链接', '代码', '提示词'])
                ChoiceChip(
                  label: Text(name),
                  selected: tab == name,
                  onSelected: (_) {
                    setState(() {
                      tab = name;
                      matches = null;
                    });
                    loadSearch();
                  },
                ),
            ],
          ),
          if (searching)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
        itemCount: filtered.length,
        empty: rows.hasError
            ? const LTErrorState()
            : rows.isLoading
            ? const LTLoadingState()
            : const LTEmptyState(
                title: '暂无匹配内容',
                message: '主动粘贴或手动保存第一条内容；Windows可在明确启用后记录后续复制。',
              ),
        itemBuilder: (context, index) {
          final record = filtered[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              onDoubleTap: () => action(record, 'copy'),
              onSecondaryTapDown: (event) =>
                  contextMenu(record, event.globalPosition),
              child: LTCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: record.text('contentType') == 'image'
                      ? _ClipImage(record)
                      : Icon(
                          record.flag('pinned')
                              ? Icons.star
                              : record.kind == 'prompt'
                              ? Icons.text_snippet_outlined
                              : Icons.content_paste_outlined,
                        ),
                  title: Text(
                    record.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (record.body.isNotEmpty)
                        Text(
                          record.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 6),
                      Text(
                        '${readableTime(record.createdAt)} · ${record.flag('isSensitive') ? '私密 · ' : ''}${record.text('sourceName').isEmpty ? '来源不可用' : record.text('sourceName')}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(record.title),
                      scrollable: true,
                      content: record.text('contentType') == 'image'
                          ? _ClipImage(record, large: true)
                          : SelectableText(record.body),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: '记录操作',
                    itemBuilder: (_) => menu(record),
                    onSelected: (value) => action(record, value),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ClipImage extends ConsumerWidget {
  const _ClipImage(this.record, {this.large = false});
  final ToolRecord record;
  final bool large;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(ownedFilesProvider)
      .when(
        loading: () => const SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(),
        ),
        error: (_, stack) => const Icon(Icons.broken_image_outlined),
        data: (files) => Image.file(
          files.resolve(record.text('attachment')),
          width: large ? 480 : 56,
          height: large ? 360 : 56,
          fit: BoxFit.contain,
          cacheWidth: large ? 960 : 112,
          errorBuilder: (_, error, stack) =>
              const Icon(Icons.broken_image_outlined),
        ),
      );
}
