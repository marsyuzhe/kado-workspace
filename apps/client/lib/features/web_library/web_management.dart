import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import 'web_dialogs.dart';
import 'web_models.dart';
import 'web_providers.dart';
import 'web_repository.dart';

class WebCategoryManager extends ConsumerStatefulWidget {
  const WebCategoryManager({super.key});
  @override
  ConsumerState<WebCategoryManager> createState() => _CategoryManagerState();
}

class _CategoryManagerState extends ConsumerState<WebCategoryManager> {
  String parent = '';
  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(webCategoriesProvider).asData?.value ??
        const <WebsiteCategory>[];
    final group = categories.where((c) => c.parentId == parent).toList(),
        repo = ref.read(webRepositoryProvider);
    return AlertDialog(
      title: const Text('分类管理'),
      content: SizedBox(
        width: 640,
        height: 500,
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => runUi(context, () async {
                    final id = await pickWebCategory(
                      context,
                      categories.where((c) => c.parentId.isEmpty).toList(),
                      title: '管理此分类的下级',
                    );
                    if (id != null && mounted) setState(() => parent = id);
                  }),
                  child: Text(
                    parent.isEmpty
                        ? '顶层分类'
                        : '上级：${categories.where((c) => c.id == parent).firstOrNull?.name ?? ''}',
                  ),
                ),
                if (parent.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => parent = ''),
                    child: const Text('返回顶层'),
                  ),
                FilledButton.icon(
                  onPressed: () => editWebCategory(context, repo, categories),
                  icon: const Icon(Icons.add),
                  label: const Text('新建分类'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '拖动手柄调整当前层级顺序。隐藏不会删除网站；删除分类时需指定网站去向。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: group.length,
                onReorderItem: (from, to) => runUi(context, () async {
                  final ids = group.map((c) => c.id).toList();

                  ids.insert(to, ids.removeAt(from));
                  await repo.reorderCategories(ids, parentId: parent);
                }),
                itemBuilder: (context, i) {
                  final c = group[i];
                  return ListTile(
                    key: ValueKey(c.id),
                    contentPadding: const EdgeInsets.only(right: 36),
                    leading: Icon(webIcon(c.iconKey)),
                    title: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      c.isHidden
                          ? '已隐藏'
                          : c.isSystemPreset
                          ? '默认分类（可编辑）'
                          : '自定义分类',
                    ),
                    onTap: () =>
                        editWebCategory(context, repo, categories, category: c),
                    trailing: PopupMenuButton<String>(
                      tooltip: '分类操作',
                      onSelected: (v) => runUi(context, () async {
                        if (v == 'edit') {
                          await editWebCategory(
                            context,
                            repo,
                            categories,
                            category: c,
                          );
                          return;
                        }
                        if (v == 'hide') {
                          await repo.saveCategory(
                            WebsiteCategoryInput(
                              c.name,
                              description: c.description,
                              parentId: c.parentId,
                              iconKey: c.iconKey,
                              color: c.color,
                              sortOrder: c.sortOrder,
                              isHidden: !c.isHidden,
                            ),
                            existing: c,
                          );
                          return;
                        }
                        final target = await pickWebCategory(
                          context,
                          categories,
                          exclude: {c.id},
                          title: '把此分类的网站移动到',
                        );
                        if (target == null || !context.mounted) return;
                        if (!await ltConfirm(
                          context,
                          title: '删除分类“${c.name}”？',
                          message: '网站移动到所选分类，子分类保留并移至顶层。此操作不会删除网站。',
                        )) {
                          return;
                        }
                        await repo.removeCategory(
                          c,
                          moveTo: target,
                          confirmed: true,
                        );
                      }),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑分类')),
                        PopupMenuItem(
                          value: 'hide',
                          child: Text(c.isHidden ? '恢复显示' : '隐藏分类'),
                        ),
                        if (c.id != uncategorizedId)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除并移动网站'),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class WebTrashDialog extends ConsumerWidget {
  const WebTrashDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: const Text('网站回收站'),
    content: SizedBox(
      width: 600,
      height: 440,
      child: ref
          .watch(webTrashProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Text('回收站加载失败'),
            data: (rows) => rows.isEmpty
                ? const Center(child: Text('回收站为空'))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final s = rows[i];
                      return ListTile(
                        title: Text(s.title),
                        subtitle: Text(
                          s.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () => runUi(context, () async {
                            await ref
                                .read(webRepositoryProvider)
                                .restoreWebsite(s);
                          }),
                          child: const Text('恢复'),
                        ),
                      );
                    },
                  ),
          ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class WebCatalogBrowser extends ConsumerStatefulWidget {
  const WebCatalogBrowser({super.key});
  @override
  ConsumerState<WebCatalogBrowser> createState() => _CatalogBrowserState();
}

class _CatalogBrowserState extends ConsumerState<WebCatalogBrowser> {
  String query = '', category = '';
  final selected = <String>{};
  bool busy = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('精选科技网站目录'),
    content: SizedBox(
      width: 760,
      height: 520,
      child: ref
          .watch(webCatalogProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Text('目录加载失败'),
            data: (catalog) {
              final rows = catalog.sites
                  .where(
                    (s) =>
                        (category.isEmpty || s['categoryId'] == category) &&
                        '${s['title']} ${s['url']} ${(s['tags'] as List).join(' ')}'
                            .toLowerCase()
                            .contains(query.toLowerCase()),
                  )
                  .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '目录 v${catalog.version} · ${catalog.sites.length}个候选。预置推荐不代表个人常用；仅添加明确选择的条目。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '搜索目录',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: category,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部分类')),
                      ...catalog.categories.map(
                        (c) => DropdownMenuItem(
                          value: c['id'] as String,
                          child: Text(c['name'] as String),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => category = v!),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final s = rows[i], id = s['id'] as String;
                        return CheckboxListTile(
                          value: selected.contains(id),
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  if (v!) {
                                    selected.add(id);
                                  } else {
                                    selected.remove(id);
                                  }
                                }),
                          title: Text(s['title'] as String),
                          subtitle: Text(
                            '${s['url']}\n${s['description']}\n${s['verificationStatus'] == 'PAGE_READ' ? '官方页面已核对' : '访问受限或内容未验证，保留官方候选地址'}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                  FilledButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => runUi(context, () async {
                            if (!await ltConfirm(
                              context,
                              title: '添加所选${selected.length}个推荐？',
                              message:
                                  '按稳定ID与规范化网址去重，保留已有个人修改；删除过的同ID条目不会自动复活。',
                            )) {
                              return;
                            }
                            if (!mounted) return;
                            setState(() => busy = true);
                            try {
                              final result = await ref
                                  .read(webRepositoryProvider)
                                  .mergeCatalog(
                                    catalog,
                                    selected.toList(),
                                    confirmed: true,
                                  );
                              if (context.mounted) {
                                ltMessage(
                                  context,
                                  '已添加${result.added}项；跳过${result.skipped}项。',
                                );
                              }
                              if (mounted) setState(selected.clear);
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          }),
                    child: Text(busy ? '正在添加…' : '确认添加${selected.length}项'),
                  ),
                ],
              );
            },
          ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

Future<void> showWebOrder(
  BuildContext context,
  WebLibraryRepository repo, {
  String categoryId = '',
}) async {
  final all = await repo.sites(),
      rows = all
          .where((s) => categoryId.isEmpty || s.categoryId == categoryId)
          .toList();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('调整网站顺序'),
        content: SizedBox(
          width: 560,
          height: 440,
          child: Column(
            children: [
              const Text(
                '固定项仍显示在前。当前分类仅调整直接归属的网站；保存后生效。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: rows.length,
                  onReorderItem: (from, to) => setState(() {
                    rows.insert(to, rows.removeAt(from));
                  }),
                  itemBuilder: (_, i) => ListTile(
                    key: ValueKey(rows[i].id),
                    title: Text(rows[i].title),
                    leading: Icon(
                      rows[i].isPinned ? Icons.push_pin : Icons.language,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => runUi(context, () async {
              await repo.reorderWebsites(
                rows.map((s) => s.id).toList(),
                categoryId: categoryId,
              );
              if (context.mounted) Navigator.pop(context);
            }),
            child: const Text('保存顺序'),
          ),
        ],
      ),
    ),
  );
}
