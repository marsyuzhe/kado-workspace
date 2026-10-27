import '../features/dev_tools/snippet_page.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../app/data_providers.dart';
import '../core/data/tool_record.dart';
import '../core/platform/system_actions.dart';
import '../core/ui/lt_components.dart';
import '../core/ui/lt_scroll_page.dart';
import '../features/hub/hub_actions.dart';
import '../features/clipboard/clipboard_page.dart';
import '../features/memory/memory_page.dart';
import '../features/memory/memory_repository.dart';
import '../features/ai_desk/ai_page.dart';
import '../features/server/server_page.dart';
import '../features/utilities/transcribe_page.dart';
import 'record_ui.dart';

class RecordLanding extends ConsumerWidget {
  const RecordLanding({super.key, required this.moduleId, required this.id});
  final String moduleId, id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(recordByIdProvider(id));
    return record.when(
      loading: () => const LTLoadingState(),
      error: (_, _) => const LTErrorState(message: '无法读取记录。'),
      data: (r) {
        if (r == null) {
          return const LTEmptyState(title: '记录不存在', message: '记录可能已被删除。');
        }
        if(moduleId == 'snippets' && r.kind == 'dev_snippet') { return SnippetLibraryPage(initialId:r.id); }
        if (moduleId == 'transcribe' && r.kind == 'transcript') {
          return TranscribePage(recordId: r.id);
        }
        if (moduleId == 'memory' &&
            {'note', 'memory_prompt'}.contains(r.kind)) {
          return MemoryPage(noteId: r.id);
        }
        if (moduleId == 'memory' && r.kind == 'project') {
          return MemoryPage(initialProjectId: r.id);
        }
        if (moduleId == 'clipboard' &&
            {'clipboard', 'prompt'}.contains(r.kind)) {
          return ClipboardPage(key: ValueKey(id), recordId: r.id);
        }
        if (moduleId == 'archive' && r.kind == 'archive_file') {
          return _ArchiveRecord(record: r);
        }
        if (moduleId == 'ai_desk' && r.kind == 'ai_provider') {
          return AiDeskPage(key: ValueKey(id), initialProviderId: r.id);
        }
        if (moduleId == 'ai_desk' && r.kind == 'ai_conversation') {
          return AiDeskPage(key: ValueKey(id), conversationId: r.id);
        }
        if (moduleId == 'server' && r.kind == 'server') {
          return ServerPage(serverId: r.id);
        }
        return const LTEmptyState(title: '此入口已失效', message: '请返回模块选择有效记录。');
      },
    );
  }
}

class _ArchiveRecord extends ConsumerWidget {
  const _ArchiveRecord({required this.record});
  final ToolRecord record;
  String get details =>
      '# ${record.title}\n\n路径：${record.text('path')}\n大小：${record.number('size')} bytes\n分类：${record.text('category')}\n扫描时修改日期：${record.text('modified')}\n\n仅保存扫描元数据；不包含文件内容。';
  @override
  Widget build(BuildContext context, WidgetRef ref) => LTScrollPage(
    title: record.title,
    description: '文件索引记录。路径来自明确授权的扫描；文件可能已在扫描后移动或修改。',
    header: [
      SelectableText(details),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          LTButton(
            label: '返回归档',
            onPressed: () => context.go('/modules/archive'),
            style: LTButtonStyle.ghost,
          ),
          if (Platform.isWindows)
            LTButton(
              label: '打开文件',
              onPressed: () => openTarget(
                context,
                ref,
                TargetAction('file', record.text('path')),
                title: record.title,
              ),
            ),
          if (Platform.isWindows)
            LTButton(
              label: '所在目录',
              onPressed: () => openTarget(
                context,
                ref,
                TargetAction('folder', p.dirname(record.text('path'))),
                title: record.title,
              ),
              style: LTButtonStyle.secondary,
            ),
          LTButton(
            label: '元数据保存到记忆仓库',
            onPressed: () => runUi(
              context,
              () => ref
                  .read(memoryRepositoryProvider)
                  .createNote(
                    record.title,
                    body: details,
                    sensitive: true,
                    source: 'archive:${record.id}',
                  ),
              success: '文件元数据已保存为敏感笔记。',
            ),
            style: LTButtonStyle.secondary,
          ),
          LTButton(
            label: '复制此文件为笔记附件',
            onPressed: () async {
              if (!await ltConfirm(
                    context,
                    title: '复制选定文件为附件？',
                    message: '${record.text('path')}\n只复制此文件，最多25MB；源文件保持原样。',
                    confirmLabel: '明确导入',
                  ) ||
                  !context.mounted) {
                return;
              }
              await runUi(context, () async {
                final file = File(record.text('path'));
                if (await FileSystemEntity.type(
                      file.path,
                      followLinks: false,
                    ) !=
                    FileSystemEntityType.file) {
                  throw const ToolFailure('源文件不存在或是链接。');
                }
                if (await file.length() > MemoryRepository.maxAttachmentBytes) {
                  throw const ToolFailure('附件上限25MB。');
                }
                final bytes = await file.readAsBytes();
                if (bytes.length > MemoryRepository.maxAttachmentBytes) {
                  throw const ToolFailure('附件读取期间超过25MB上限。');
                }
                final repo = ref.read(memoryRepositoryProvider);
                final note = await repo.createNote(
                  record.title,
                  body: details,
                  sensitive: true,
                  source: 'archive:${record.id}',
                );
                await repo.attach(note, record.title, bytes);
                if (context.mounted) {
                  context.go(
                    Uri(
                      path: '/modules/memory',
                      queryParameters: {'id': note.id},
                    ).toString(),
                  );
                }
              });
            },
            style: LTButtonStyle.secondary,
          ),
        ],
      ),
    ],
    itemCount: 0,
    itemBuilder: (_, i) => const SizedBox(),
  );
}
