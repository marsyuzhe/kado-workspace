import '../dev_tools/snippet_page.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import '../../shared/local_markdown.dart';
import 'memory_repository.dart';

class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key, this.noteId, this.initialProjectId});
  final String? noteId;
  final String? initialProjectId;
  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  final search = TextEditingController();
  String projectId = '', tag = '', query = '';
  bool pinned = false;
  MemoryRepository get repo => ref.read(memoryRepositoryProvider);
  @override
  void initState() {
    super.initState();
    projectId = widget.initialProjectId ?? '';
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> editProject([ToolRecord? current]) async {
    final values = await ltEditForm(
      context,
      title: current == null ? '创建项目' : '编辑项目',
      fields: [
        LTField('title', '项目名称', initial: current?.title ?? '', required: true),
        LTField(
          'description',
          '项目介绍',
          initial: current?.body ?? '',
          multiline: true,
        ),
        LTField(
          'stack',
          '技术栈',
          initial: current?.text('stack') ?? '',
          multiline: true,
        ),
        LTField(
          'progress',
          '开发进度',
          initial: current?.text('progress') ?? '',
          multiline: true,
        ),
      ],
    );
    if (values == null || !mounted) return;
    final value = await runUi(
      context,
      () => repo.project(
        values['title']!,
        description: values['description']!,
        stack: values['stack']!,
        progress: values['progress']!,
        existing: current,
      ),
    );
    if (value != null && mounted) setState(() => projectId = value.id);
  }

  Future<void> createNote({String body = '', String? title}) async {
    final note = await runUi(
      context,
      () => repo.createNote(title ?? '未命名笔记', body: body, projectId: projectId),
    );
    if (note != null && mounted) {
      context.go(
        Uri(
          path: '/modules/memory',
          queryParameters: {'id': note.id},
        ).toString(),
      );
    }
  }

  Future<void> importNote() async {
    await runUi(context, () async {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['md', 'markdown', 'txt'],
      );
      if (file == null) return;
      if ((await file.length() ?? 0) > MemoryRepository.maxNoteBytes) {
        throw const ToolFailure('Markdown文件不能超过1MB。');
      }
      final bytes = <int>[];
      await for (final chunk in file.readAsByteStream()) {
        bytes.addAll(chunk);
        if (bytes.length > MemoryRepository.maxNoteBytes) {
          throw const ToolFailure('Markdown文件不能超过1MB。');
        }
      }
      final body = utf8.decode(bytes);
      if (mounted) {
        await createNote(
          body: body,
          title: p.basenameWithoutExtension(file.name),
        );
      }
    });
  }

  Future<void> exportContext(ToolRecord project) async {
    final rows = await ref.read(recordStoreProvider).list('note', limit: 10000);
    if (!mounted) return;
    final candidates = rows
        .where((r) => r.text('projectId') == project.id)
        .toList();
    final ids = candidates
        .where((r) => !r.flag('isSensitive'))
        .map((r) => r.id)
        .toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, change) => AlertDialog(
          title: const Text('选择上下文笔记'),
          content: SizedBox(
            width: 560,
            height: 360,
            child: ListView(
              children: [
                const Text('敏感笔记始终排除。可取消选择其他笔记，再检查五个文件的预览。'),
                for (final n in candidates)
                  CheckboxListTile(
                    value: ids.contains(n.id),
                    onChanged: n.flag('isSensitive')
                        ? null
                        : (v) => change(
                            () => v == true ? ids.add(n.id) : ids.remove(n.id),
                          ),
                    title: Text(n.title),
                    subtitle: Text(
                      n.flag('isSensitive') ? '敏感内容，禁止导出' : n.text('category'),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            LTButton(label: '生成预览', onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final preview = await runUi(
      context,
      () => repo.contextPreview(project, ids),
    );
    if (preview == null || !mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => DefaultTabController(
        length: 5,
        child: AlertDialog(
          title: const Text('上下文导出预览'),
          content: SizedBox(
            width: 800,
            height: 480,
            child: Column(
              children: [
                TabBar(
                  isScrollable: true,
                  tabs: [for (final file in contextFiles) Tab(text: file)],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (final file in contextFiles)
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(preview[file]!),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            LTButton(
              label: '选择目录并导出',
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
    if (proceed != true || !mounted) return;
    await runUi(context, () async {
      final destination = await FilePicker.getDirectoryPath(
        dialogTitle: '选择上下文导出目录（已有同名文件不会覆盖）',
      );
      if (destination == null) return;
      await repo.exportContext(
        project,
        preview,
        Directory(destination),
        confirmed: true,
      );
      if (mounted) ltMessage(context, '五个Markdown文件已真实导出至 $destination');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.noteId != null) {
      return NoteEditor(key: ValueKey(widget.noteId), noteId: widget.noteId!);
    }
    final projects = ref.watch(recordsProvider('project')).value ?? [];
    final notes = ref.watch(noteSearchProvider(query));
    final rows = notes.value ?? [];
    final tags = rows.expand((r) => r.tags).toSet().toList()..sort();
    final visible = rows
        .where(
          (n) =>
              (projectId.isEmpty || n.projectId == projectId) &&
              (tag.isEmpty || n.tags.contains(tag)) &&
              (!pinned || n.pinned),
        )
        .toList();
    final project = projects.where((r) => r.id == projectId).firstOrNull;
    return LTScrollPage(
      title: '知识仓库',
      description: '本机项目知识库 · Markdown笔记 · 中文检索 · 可预览的上下文导出',
      header: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LTButton(
              label: '新建笔记',
              icon: Icons.note_add_outlined,
              onPressed: () => createNote(),
            ),
            LTButton(
              label: '新建项目',
              onPressed: () => editProject(),
              style: LTButtonStyle.secondary,
            ),
            LTButton(
              label: '导入Markdown',
              onPressed: importNote,
              style: LTButtonStyle.secondary,
            ),
            if (project != null) ...[
              LTButton(
                label: '项目设置',
                onPressed: () => editProject(project),
                style: LTButtonStyle.ghost,
              ),
              LTButton(
                label: '导出上下文',
                onPressed: () => exportContext(project),
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '删除项目',
                style: LTButtonStyle.danger,
                onPressed: () async {
                  if (await ltConfirm(
                        context,
                        title: '删除项目？',
                        message: '笔记和附件将保留并移入未归属项目；只删除项目资料。',
                        confirmLabel: '删除项目',
                      ) &&
                      context.mounted) {
                    await runUi(context, () => repo.deleteProject(project));
                    if (context.mounted) setState(() => projectId = '');
                  }
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        LTSearchField(
          controller: search,
          hint: '搜索标题与全文（支持中文）',
          onChanged: (v) => setState(() => query = v.trim()),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('全部项目'),
              selected: projectId.isEmpty,
              onSelected: (_) => setState(() => projectId = ''),
            ),
            for (final p in projects)
              ChoiceChip(
                label: Text(p.title),
                selected: projectId == p.id,
                onSelected: (_) => setState(() => projectId = p.id),
              ),
            FilterChip(
              label: const Text('收藏'),
              selected: pinned,
              onSelected: (v) => setState(() => pinned = v),
            ),
          ],
        ),
        if (tags.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部标签'),
                selected: tag.isEmpty,
                onSelected: (_) => setState(() => tag = ''),
              ),
              for (final value in tags)
                ChoiceChip(
                  label: Text(value),
                  selected: tag == value,
                  onSelected: (_) => setState(() => tag = value),
                ),
            ],
          ),
        if (project != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${project.body}\n${project.text('stack')}\n${project.text('progress')}',
            ),
          ),
        if (notes.isLoading) const LinearProgressIndicator(),
        if (notes.hasError) const Text('笔记读取失败，请检查本机存储。'),
      ],
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final n = visible[i];
        return ListTile(
          leading: Icon(
            n.pinned ? Icons.star_outline : Icons.description_outlined,
          ),
          title: Text(n.title),
          subtitle: Text(
            '${n.preview.replaceAll('\n', ' ')}\n${n.tags.join(' · ')} · ${readableTime(n.updatedAt)}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          onTap: () => context.go(
            Uri(
              path: '/modules/memory',
              queryParameters: {'id': n.id},
            ).toString(),
          ),
        );
      },
      empty: const LTEmptyState(
        title: '开始记录',
        message: '创建项目与笔记，内容会保存在本机数据库。',
        icon: Icons.note_outlined,
      ),
    );
  }
}

class NoteEditor extends ConsumerStatefulWidget {
  const NoteEditor({super.key, required this.noteId});
  final String noteId;
  @override
  ConsumerState<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<NoteEditor> {
  final title = TextEditingController(),
      body = TextEditingController(),
      tags = TextEditingController();
  NoteEditorSession? session;
  Timer? debounce;
  bool dirty = false, saving = false, preview = false;
  String? error;
  String projectId = '', category = 'CONTEXT.md';
  bool pinned = false, sensitive = false;
  late final NavigationSaveGuard guard;
  MemoryRepository get repo => ref.read(memoryRepositoryProvider);
  @override
  void initState() {
    super.initState();
    guard = ref.read(navigationSaveGuardProvider);
    load();
  }

  Future<void> load() async {
    final note = await ref.read(recordStoreProvider).get(widget.noteId);
    if (!mounted) return;
    if (note == null || !{'note', 'memory_prompt'}.contains(note.kind)) {
      setState(() => error = '笔记不存在，可能已被删除。');
      return;
    }
    title.text = note.title;
    body.text = note.body;
    tags.text = note.strings('tags').join(', ');
    projectId = note.text('projectId');
    category = note.text('category', 'CONTEXT.md');
    pinned = note.flag('pinned');
    sensitive = note.flag('isSensitive');
    setState(() => session = NoteEditorSession(repo, note));
    guard.owner = widget.noteId;
    guard.callback = save;
  }

  @override
  void dispose() {
    guard.clear(widget.noteId);
    debounce?.cancel();
    title.dispose();
    body.dispose();
    tags.dispose();
    super.dispose();
  }

  void changed([String? _]) {
    setState(() => dirty = true);
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 600), save);
  }

  Future<bool> save() async {
    debounce?.cancel();
    final current = session;
    if (current == null) return false;
    if (!dirty) return error == null;
    final text = body.text, heading = title.text;
    final metadata = {
      ...current.record.data,
      'projectId': projectId,
      'category': category,
      'tags': tags.text
          .split(RegExp('[,，]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
      'pinned': pinned,
      'isSensitive': sensitive,
      'syncAllowed': false,
    };
    setState(() => saving = true);
    try {
      await current.save(heading, text, metadata);
      if (mounted) {
        setState(() {
          dirty =
              body.text != text ||
              title.text != heading ||
              tags.text
                      .split(RegExp('[,，]'))
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .join(',') !=
                  (metadata['tags'] as List).join(',') ||
              projectId != metadata['projectId'] ||
              category != metadata['category'] ||
              pinned != metadata['pinned'] ||
              sensitive != metadata['isSensitive'];
          saving = false;
          error = null;
        });
      }
      return !dirty;
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e is ToolFailure ? e.message : '自动保存失败。草稿保留，请重试或另存为笔记。';
        });
      }
      return false;
    }
  }

  Future<void> back() async {
    if (session == null) {
      context.go('/modules/memory');
      return;
    }
    if (!await save() || !mounted) return;
    context.go('/modules/memory');
  }

  Future<void> attach() async {
    if (!await save()) return;
    if (!mounted) return;
    await runUi(context, () async {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      if ((await file.length() ?? 0) > MemoryRepository.maxAttachmentBytes) {
        throw const ToolFailure('附件上限25MB。');
      }
      final bytes = <int>[];
      await for (final chunk in file.readAsByteStream()) {
        bytes.addAll(chunk);
        if (bytes.length > MemoryRepository.maxAttachmentBytes) {
          throw const ToolFailure('附件上限25MB。');
        }
      }
      await repo.attach(session!.record, file.name, Uint8List.fromList(bytes));
    });
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(recordsProvider('project')).value ?? [];
    final attachments = (ref.watch(recordsProvider('attachment')).value ?? [])
        .where((r) => r.text('noteId') == widget.noteId)
        .toList();
    final links = (ref.watch(recordsProvider('note_link')).value ?? [])
        .where(
          (r) =>
              r.text('from') == widget.noteId || r.text('to') == widget.noteId,
        )
        .toList();
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await back();
      },
      child: LTScrollPage(
        title: '笔记编辑',
        description:
            '${saving
                ? '正在保存…'
                : dirty
                ? '有未保存草稿'
                : '已保存在本机'}${session == null ? '' : ' · 版本${session!.record.revision}'}',
        header: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LTButton(
                label: '返回笔记',
                onPressed: back,
                style: LTButtonStyle.ghost,
              ),
              LTButton(
                label: '保存',
                onPressed: session == null ? null : save,
                loading: saving,
              ),
              LTButton(
                label: preview ? '继续编辑' : 'Markdown预览',
                onPressed: () => setState(() => preview = !preview),
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '保存代码片段',
                style: LTButtonStyle.secondary,
                onPressed: session == null || session!.record.flag('isSensitive')
                    ? null
                    : () => runUi(
                        context,
                        () => saveSnippetDialog(
                          context,
                          ref,
                          code: body.text,
                          sourceId: widget.noteId,
                        ),
                      ),
              ),
              LTButton(
                label: '导出Markdown',
                onPressed: session == null
                    ? null
                    : () async {
                        if (!await save() || !context.mounted) return;
                        await runUi(context, () async {
                          await FilePicker.saveFile(
                            fileName: 'note-${widget.noteId}.md',
                            bytes: Uint8List.fromList(
                              utf8.encode('# ${title.text}\n\n${body.text}'),
                            ),
                            mimeType: 'text/markdown',
                          );
                        });
                      },
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '添加附件',
                onPressed: session == null ? null : attach,
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '送入AI草稿',
                onPressed: session == null
                    ? null
                    : () async {
                        if (!await save() || !context.mounted) return;
                        ref.read(aiDraftProvider.notifier).setDraft(body.text);
                        context.go('/modules/ai_desk');
                      },
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '保存为提示词',
                onPressed: session == null
                    ? null
                    : () async {
                        if (await save() && context.mounted) {
                          await runUi(
                            context,
                            () => repo.prompt(session!.record),
                            success: '提示词已保存在项目资料中。',
                          );
                        }
                      },
                style: LTButtonStyle.ghost,
              ),
              LTButton(
                label: '删除笔记',
                onPressed: session == null
                    ? null
                    : () async {
                        if (!await save() || !context.mounted) return;
                        if (await ltConfirm(
                              context,
                              title: '删除笔记？',
                              message: '将删除此笔记、关联与受控附件，无法撤销。',
                              confirmLabel: '删除',
                            ) &&
                            context.mounted) {
                          await runUi(context, () async {
                            await repo.removeNote(session!.record);
                            if (context.mounted) context.go('/modules/memory');
                          });
                        }
                      },
                style: LTButtonStyle.danger,
              ),
            ],
          ),
          if (error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error!),
                    TextButton(
                      onPressed: session == null
                          ? load
                          : () async {
                              final note = await runUi(
                                context,
                                () => repo.createNote(
                                  '${title.text}（草稿副本）',
                                  body: body.text,
                                  projectId: projectId,
                                  sensitive: sensitive,
                                ),
                              );
                              if (note != null && context.mounted) {
                                context.go(
                                  Uri(
                                    path: '/modules/memory',
                                    queryParameters: {'id': note.id},
                                  ).toString(),
                                );
                              }
                            },
                      child: Text(session == null ? '重试加载' : '将当前草稿另存为笔记'),
                    ),
                  ],
                ),
              ),
            ),
          if (session != null) ...[
            const SizedBox(height: 16),
            LTTextField(controller: title, label: '笔记标题', onChanged: changed),
            const SizedBox(height: 12),
            LTTextField(
              controller: tags,
              label: '标签（逗号分隔）',
              onChanged: changed,
            ),
            Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: projects.any((p) => p.id == projectId)
                      ? projectId
                      : '',
                  items: [
                    const DropdownMenuItem(value: '', child: Text('未归属项目')),
                    for (final p in projects)
                      DropdownMenuItem(value: p.id, child: Text(p.title)),
                  ],
                  onChanged: (v) {
                    projectId = v!;
                    changed();
                  },
                ),
                DropdownButton<String>(
                  value: contextFiles.contains(category)
                      ? category
                      : 'CONTEXT.md',
                  items: [
                    for (final f in contextFiles)
                      DropdownMenuItem(value: f, child: Text(f)),
                  ],
                  onChanged: (v) {
                    category = v!;
                    changed();
                  },
                ),
                FilterChip(
                  label: const Text('收藏'),
                  selected: pinned,
                  onSelected: (v) {
                    pinned = v;
                    changed();
                  },
                ),
                FilterChip(
                  label: const Text('敏感内容'),
                  selected: sensitive,
                  onSelected: (v) {
                    sensitive = v;
                    changed();
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (preview)
              LocalMarkdown(text: body.text)
            else
              TextField(
                controller: body,
                minLines: 14,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                onChanged: changed,
                decoration: const InputDecoration(
                  labelText: 'Markdown正文',
                  alignLabelWithHint: true,
                ),
              ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () async {
                if (!await save() || !context.mounted) return;
                final summaries = ref.read(noteSummariesProvider).value ?? [];
                final target = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('链接到另一篇笔记'),
                    children: [
                      for (final n in summaries.where(
                        (n) => n.id != widget.noteId,
                      ))
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, n.id),
                          child: Text(n.title),
                        ),
                    ],
                  ),
                );
                if (target == null || !context.mounted) return;
                await runUi(context, () async {
                  final to = await ref.read(recordStoreProvider).get(target);
                  if (to != null) await repo.link(session!.record, to);
                });
              },
              child: const Text('添加笔记关联'),
            ),
            for (final link in links)
              ListTile(
                title: Text(link.title),
                onTap: () async {
                  if (await save() && context.mounted) {
                    context.go(
                      Uri(
                        path: '/modules/memory',
                        queryParameters: {
                          'id': link.text('from') == widget.noteId
                              ? link.text('to')
                              : link.text('from'),
                        },
                      ).toString(),
                    );
                  }
                },
                trailing: IconButton(
                  tooltip: '移除关联',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => runUi(
                    context,
                    () => ref.read(recordStoreProvider).delete(link),
                  ),
                ),
              ),
            for (final a in attachments)
              ListTile(
                title: Text(a.title),
                subtitle: Text(readableBytes(a.number('size'))),
                onTap: () => runUi(context, () async {
                  final bytes = await (await ref.read(
                    ownedFilesProvider.future,
                  )).resolve(a.text('attachment')).readAsBytes();
                  await FilePicker.saveFile(
                    fileName: a.title,
                    bytes: bytes,
                    mimeType: 'application/octet-stream',
                  );
                }),
                trailing: IconButton(
                  tooltip: '移除附件',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (await ltConfirm(
                          context,
                          title: '移除附件？',
                          message: '仅删除应用保存的副本。',
                          confirmLabel: '移除',
                        ) &&
                        context.mounted) {
                      await runUi(context, () => repo.removeAttachment(a));
                    }
                  },
                ),
              ),
          ],
        ],
        itemCount: 0,
        itemBuilder: (_, i) => const SizedBox(),
      ),
    );
  }
}
