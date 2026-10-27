import '../web_library/web_dialogs.dart';
import '../web_library/web_models.dart';
import '../web_library/web_providers.dart';

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../app/providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/modules/module_registry.dart';
import '../../core/modules/workspace_navigation.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/app_theme.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'hub_actions.dart';
import 'workspace_activity.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});
  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  String category = '全部';
  Future<void> addEntry(String type) async {
    String target = '';
    if (type == 'folder') {
      target = await FilePicker.getDirectoryPath(dialogTitle: '选择快捷文件夹') ?? '';
    }
    if (type == 'file' || type == 'application') {
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择快捷入口',
        type: type == 'application' ? FileType.custom : FileType.any,
        allowedExtensions: type == 'application' ? ['exe'] : null,
      );
      target = picked?.path ?? '';
    }
    if (!mounted) return;
    if (type != 'url' && target.isEmpty) return;
    final values = await ltEditForm(
      context,
      title: '添加快捷入口',
      fields: [
        const LTField('title', '名称', required: true),
        if (type == 'url')
          const LTField(
            'target',
            '网址',
            hint: 'https://example.com',
            required: true,
          ),
        const LTField('category', '分类', initial: '常用'),
        if (type == 'application')
          const LTField('args', '参数数组 JSON', initial: '[]'),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      final parsed = type == 'application'
          ? jsonDecode(values['args']!)
          : <String>[];
      if (parsed is! List || parsed.any((v) => v is! String)) {
        throw const ToolFailure('参数必须是字符串数组，例如 ["--flag", "value"]。');
      }
      await ref
          .read(hubRepositoryProvider)
          .addFavorite(
            values['title']!,
            TargetAction(
              type,
              type == 'url' ? values['target']! : target,
              arguments: parsed.cast<String>(),
            ),
            category: values['category']!.trim().isEmpty
                ? '常用'
                : values['category']!,
          );
    });
  }

  Future<void> favoriteMenu(
    ToolRecord record,
    String action,
    List<ToolRecord> all,
  ) async {
    final repo = ref.read(hubRepositoryProvider);
    final isWebsite = (record.data['action'] as Map?)?['type'] == 'url';
    if (isWebsite && action == 'edit') {
      await runUi(context, () async {
        final web = ref.read(webRepositoryProvider),
            categories = await web.categories(),
            current = await web.store.get(record.id);
        if (!mounted || current == null) return;
        final site = WebsiteBookmark(current),
            input = await editWebsiteDialog(context, categories, site: site);
        if (input != null) await web.saveWebsite(input, existing: site);
      });
      return;
    }
    if (action == 'edit') {
      final values = await ltEditForm(
        context,
        title: '编辑收藏',
        fields: [
          LTField('title', '名称', initial: record.title, required: true),
          LTField('category', '分类', initial: record.text('category')),
        ],
      );
      if (values != null && mounted) {
        await runUi(
          context,
          () => repo.updateFavorite(
            record,
            title: values['title'],
            category: values['category'],
          ),
        );
      }
      return;
    }
    await runUi(context, () async {
      if (action == 'pin') {
        await repo.updateFavorite(record, pinned: !record.flag('pinned'));
      }
      if (action == 'remove') {
        if (isWebsite && record.data['webDataVersion'] != null) {
          await ref
              .read(webRepositoryProvider)
              .updateWebsites(
                [WebsiteBookmark(record)],
                favorite: false,
                pinned: false,
              );
        } else {
          await repo.removeFavorite(record);
        }
      }
      if (action == 'up' || action == 'down') {
        final order = [...all];
        final index = order.indexWhere((v) => v.id == record.id);
        final to = index + (action == 'up' ? -1 : 1);
        if (to >= 0 && to < order.length) {
          order.removeAt(index);
          order.insert(to, record);
          await repo.reorder(order);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider),
        t = Theme.of(context).extension<DesignTokens>()!;
    final favorites = ref.watch(favoritesProvider);
    final recent = ref.watch(recentActionsProvider);
    final notes = ref.watch(recentNotesProvider);
    final shortcuts =
        <String>{
              for (final r in favorites.asData?.value ?? <ToolRecord>[])
                if (r.flag('pinned') &&
                    (r.data['action'] as Map?)?['type'] == 'module')
                  (r.data['action'] as Map)['target'] as String,
              'bookmarks',
              'studio',
              'ai_desk',
              'archive',
              'memory',
              'clipboard',
              'converter',
              'server',
            }
            .where(
              (id) =>
                  moduleById(id) != null &&
                  !legacyModuleIds.contains(id) &&
                  settings.moduleEnabled(
                    id,
                    defaultEnabled: moduleById(id)!.enabled,
                  ),
            )
            .take(8);
    return PageFrame(
      eyebrow: 'WORKSPACE',
      title: '工作台',
      description: '启动工具、继续项目、查看当前任务。',
      children: [
        const LTSectionHeader('快捷启动'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final count = c.maxWidth >= 960
                    ? 4
                    : c.maxWidth >= 760
                    ? 3
                    : c.maxWidth >= 420
                    ? 2
                    : 1,
                gap = AppDensity.gap(context),
                width = (c.maxWidth - (count - 1) * gap) / count;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final id in shortcuts)
                  Builder(
                    builder: (context) {
                      final m = moduleById(id)!;
                      return SizedBox(
                        width: width,
                        height: AppDensity.compact(context) ? 96 : 108,
                        child: LTCard(
                          onTap: () => runUi(
                            context,
                            () => openTarget(
                              context,
                              ref,
                              TargetAction('module', id),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(m.icon, color: t.accent, size: 24),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      id == 'bookmarks'
                                          ? '网站导航'
                                          : m.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      m.description,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: t.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              LTIconButton(
                                icon: Icons.star_border_rounded,
                                tooltip: '收藏 ${m.displayName}',
                                onPressed: () => runUi(
                                  context,
                                  () => ref
                                      .read(hubRepositoryProvider)
                                      .addFavorite(
                                        m.displayName,
                                        TargetAction('module', id),
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        const WorkspaceActivity(),
        LTSectionHeader(
          '收藏项目',
          action: PopupMenuButton<String>(
            tooltip: '添加快捷入口',
            onSelected: (type) => runUi(context, () => addEntry(type)),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'url', child: Text('添加网址')),
              if (Platform.isWindows) ...[
                const PopupMenuItem(value: 'folder', child: Text('添加文件夹')),
                const PopupMenuItem(value: 'file', child: Text('添加文件')),
                const PopupMenuItem(value: 'application', child: Text('添加应用')),
              ],
            ],
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Row(children: [Icon(Icons.add, size: 18), Text(' 添加入口')]),
            ),
          ),
        ),
        favorites.when(
          loading: () => const LTLoadingState(),
          error: (_, stack) =>
              LTErrorState(onRetry: () => ref.invalidate(favoritesProvider)),
          data: (all) {
            if (all.isEmpty) {
              return const LTCard(
                child: LTEmptyState(
                  title: '还没有收藏',
                  message: '点模块卡片上的星标，或添加常用网址、文件夹和应用。',
                ),
              );
            }
            final categories = {
              '全部',
              ...all.map((r) => r.text('category', '常用')),
            };
            final selected = categories.contains(category) ? category : '全部';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in categories)
                      ChoiceChip(
                        label: Text(name),
                        selected: selected == name,
                        onSelected: (_) => setState(() => category = name),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final r in all.where(
                  (r) =>
                      selected == '全部' || r.text('category', '常用') == selected,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LTCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: Icon(
                          r.flag('pinned')
                              ? Icons.push_pin_outlined
                              : Icons.star_outline,
                        ),
                        title: Text(
                          r.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(r.text('category', '常用')),
                        onTap: () => runUi(
                          context,
                          () => openTarget(
                            context,
                            ref,
                            TargetAction.fromJson(
                              Map<String, dynamic>.from(
                                r.data['action'] as Map,
                              ),
                            ),
                            title: r.title,
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: '管理收藏',
                          onSelected: (value) => favoriteMenu(r, value, all),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'pin',
                              child: Text(r.flag('pinned') ? '取消置顶' : '置顶'),
                            ),
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('编辑名称/分类'),
                            ),
                            const PopupMenuItem(value: 'up', child: Text('上移')),
                            const PopupMenuItem(
                              value: 'down',
                              child: Text('下移'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('移除收藏'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        const LTSectionHeader('最近使用'),
        recent.when(
          loading: () => const LTLoadingState(),
          error: (_, stack) => const LTErrorState(),
          data: (items) => items.isEmpty
              ? const LTCard(
                  child: LTEmptyState(
                    title: '暂无访问记录',
                    message: '从这里实际打开模块或收藏后，记录才会出现。',
                  ),
                )
              : LTCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final r in items)
                        ListTile(
                          leading: const Icon(Icons.history),
                          title: Text(
                            r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(readableTime(r.openedAt)),
                          onTap: () => runUi(
                            context,
                            () => openTarget(
                              context,
                              ref,
                              TargetAction.fromJson(
                                Map<String, dynamic>.from(
                                  jsonDecode(r.action) as Map,
                                ),
                              ),
                              title: r.title,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 20),
        const LTSectionHeader('最近项目与笔记'),
        for (final project
            in (ref.watch(recordsProvider('project')).asData?.value ??
                    <ToolRecord>[])
                .take(3))
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => runUi(
              context,
              () => openTarget(
                context,
                ref,
                TargetAction('record', project.id, moduleId: 'memory'),
                title: project.title,
              ),
            ),
          ),
        notes.when(
          loading: () => const LTLoadingState(),
          error: (_, stack) => const LTErrorState(),
          data: (items) => items.isEmpty
              ? const LTCard(
                  child: LTEmptyState(
                    title: '知识从一条笔记开始',
                    message: '记忆仓库中的真实笔记会显示在这里。',
                  ),
                )
              : LTCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final r in items.take(5))
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(r.title),
                          onTap: () => runUi(
                            context,
                            () => openTarget(
                              context,
                              ref,
                              TargetAction('record', r.id, moduleId: 'memory'),
                              title: r.title,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 24),
        LTToolbar(
          children: [
            LTButton(
              label: '全局搜索',
              icon: Icons.search,
              style: LTButtonStyle.secondary,
              onPressed: () => contextGoSearch(context),
            ),
            LTButton(
              label: '打开设置',
              icon: Icons.tune_rounded,
              style: LTButtonStyle.ghost,
              onPressed: () => contextGoSettings(context),
            ),
          ],
        ),
      ],
    );
  }
}
