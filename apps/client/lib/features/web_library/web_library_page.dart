import '../../core/storage/selected_input.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import 'web_dialogs.dart';
import 'web_favicons.dart';
import 'web_management.dart';
import 'web_models.dart';
import 'web_providers.dart';
import 'web_search_service.dart';
import 'web_transfer_page.dart';

class WebLibraryPage extends ConsumerStatefulWidget {
  const WebLibraryPage({super.key});
  @override
  ConsumerState<WebLibraryPage> createState() => _WebLibraryPageState();
}

class _WebLibraryPageState extends ConsumerState<WebLibraryPage> {
  final search = TextEditingController(),
      searchFocus = FocusNode(),
      selection = <String, WebsiteBookmark>{};
  Timer? debounce;
  String query = '', category = '', view = 'all', sort = 'manual';
  int offset = 0;
  bool list = false, compact = false;
  @override
  void initState() {
    super.initState();
    unawaited(loadSettings());
  }

  Future<void> loadSettings() async {
    final store = ref.read(recordStoreProvider),
        layout = await store.setting('webLibrary.layout'),
        density = await store.setting('webLibrary.density');
    if (mounted) {
      setState(() {
        list = layout == 'list';
        compact = density == 'compact';
      });
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void filter({String? categoryId, String? viewId}) => setState(() {
    category = categoryId ?? category;
    view = viewId ?? view;
    offset = 0;
    selection.clear();
  });
  Future<void> edit(
    List<WebsiteCategory> categories, [
    WebsiteBookmark? site,
  ]) async => runUi(context, () async {
    final value = await editWebsiteDialog(
      context,
      categories,
      site: site,
      categoryId: category.isEmpty ? null : category,
    );
    if (value != null) {
      await ref.read(webRepositoryProvider).saveWebsite(value, existing: site);
    }
  });
  Future<void> open(WebsiteBookmark site) async => runUi(context, () async {
    await ref
        .read(nativePlatformProvider)
        .launch(TargetAction('url', site.url), confirmed: true);
    await ref.read(webRepositoryProvider).recordOpened(site);
  });
  Future<void> remove(List<WebsiteBookmark> sites) async =>
      runUi(context, () async {
        if (!await ltConfirm(
          context,
          title: '移入网站回收站？',
          message: '选中${sites.length}个网站；可在回收站恢复。自定义图标作为用户附件保留。',
        )) {
          return;
        }
        await ref
            .read(webRepositoryProvider)
            .removeWebsites(sites, confirmed: true);
        if (mounted) setState(selection.clear);
      });
  Future<void> action(
    String action,
    WebsiteBookmark site,
    List<WebsiteCategory> categories,
  ) async => runUi(context, () async {
    final repo = ref.read(webRepositoryProvider);
    switch (action) {
      case 'edit':
        await edit(categories, site);
      case 'favorite':
        await repo.updateWebsites([site], favorite: !site.isFavorite);
      case 'pin':
        await repo.updateWebsites([site], pinned: !site.isPinned);
      case 'delete':
        await remove([site]);
      case 'icon':
        final picked = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (picked.isEmpty) return;
        final file = picked.single;
        final bytes = await readToolFile(file, 5 * 1024 * 1024);
        await ref.read(webIconsProvider).setIcon(site, bytes);
      case 'clearIcon':
        await ref.read(webIconsProvider).clearIcon(site);
      case 'favicon':
        if (!context.mounted) return;
        if (!await ltConfirm(
          context,
          title: '读取此网站的公开图标？',
          message:
              '仅请求该网站自己的 /favicon.ico，不使用第三方图标服务。系统使用代理/PAC或网络策略未知时保留默认图标。',
        )) {
          return;
        }
        await WebFaviconService(
          ref.read(recordStoreProvider),
          () => ref.read(ownedFilesProvider.future),
        ).fetch(site);
    }
  });
  Widget menu(WebsiteBookmark s, List<WebsiteCategory> categories) =>
      PopupMenuButton<String>(
        tooltip: '网站操作',
        onSelected: (v) => action(v, s, categories),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('编辑网站')),
          PopupMenuItem(
            value: 'favorite',
            child: Text(s.isFavorite ? '取消收藏' : '加入收藏'),
          ),
          PopupMenuItem(
            value: 'pin',
            child: Text(s.isPinned ? '取消固定首页' : '固定首页'),
          ),
          const PopupMenuItem(value: 'icon', child: Text('选择自定义图标')),
          if (s.customIconPath.isNotEmpty)
            const PopupMenuItem(value: 'clearIcon', child: Text('移除自定义图标')),
          const PopupMenuItem(value: 'favicon', child: Text('主动读取网站图标')),
          const PopupMenuItem(value: 'delete', child: Text('移入回收站')),
        ],
      );
  Widget siteCard(WebsiteBookmark s, List<WebsiteCategory> categories) {
    final c = categories.where((c) => c.id == s.categoryId).firstOrNull;
    final check = Checkbox(
      value: selection.containsKey(s.id),
      semanticLabel: '选择 ${s.title}',
      onChanged: (v) => setState(() {
        if (v!) {
          selection[s.id] = s;
        } else {
          selection.remove(s.id);
        }
      }),
    );
    if (list) {
      return Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [check, WebSiteIcon(s, c)],
          ),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${Uri.tryParse(s.url)?.host ?? s.url} · ${c?.name ?? '未分类'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: menu(s, categories),
          onTap: () => open(s),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                WebSiteIcon(s, c),
                const Spacer(),
                check,
                menu(s, categories),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: () => open(s),
                  child: Text(
                    s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
            if (!compact)
              Text(
                s.description.isEmpty ? c?.name ?? '未分类' : s.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (s.isPinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.push_pin, size: 14),
                  ),
                if (s.isFavorite)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.star, size: 14),
                  ),
                Expanded(
                  child: Text(
                    Uri.tryParse(s.url)?.host ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                if (s.sourceType == 'RECOMMENDED')
                  const Text('推荐', style: TextStyle(fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> batchMove(List<WebsiteCategory> categories) async =>
      runUi(context, () async {
        final id = await pickWebCategory(context, categories);
        if (id == null) return;
        await ref
            .read(webRepositoryProvider)
            .updateWebsites(selection.values.toList(), categoryId: id);
        if (mounted) setState(selection.clear);
      });
  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(webCategoriesProvider).asData?.value ??
        const <WebsiteCategory>[];
    final q = (
          text: query,
          category: category,
          view: view,
          sort: sort,
          offset: offset,
        ),
        results = ref.watch(webResultsProvider(q));
    final currentCategory = categories
        .where((c) => c.id == category)
        .firstOrNull;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            searchFocus.requestFocus(),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final wide = bounds.maxWidth >= 1050;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  SizedBox(
                    width: 216,
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Text(
                          '网站导航',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        for (final entry in webViews.entries)
                          ListTile(
                            dense: true,
                            selected: view == entry.key && category.isEmpty,
                            title: Text(entry.value),
                            onTap: () =>
                                filter(categoryId: '', viewId: entry.key),
                          ),
                        const Divider(),
                        for (final c in categories.where(
                          (c) => c.parentId.isEmpty && !c.isHidden,
                        )) ...[
                          ListTile(
                            dense: true,
                            leading: Icon(webIcon(c.iconKey), size: 18),
                            title: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            selected: category == c.id,
                            onTap: () =>
                                filter(categoryId: c.id, viewId: 'all'),
                          ),
                          for (final child in categories.where(
                            (v) => v.parentId == c.id && !v.isHidden,
                          ))
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: ListTile(
                                dense: true,
                                title: Text(
                                  child.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                selected: category == child.id,
                                onTap: () =>
                                    filter(categoryId: child.id, viewId: 'all'),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                if (wide) const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(bounds.maxWidth < 600 ? 12 : 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Text(
                              currentCategory?.name ?? webViews[view]!,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton.icon(
                                  onPressed: categories.isEmpty
                                      ? null
                                      : () => edit(categories),
                                  icon: const Icon(Icons.add),
                                  label: const Text('添加网站'),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: '导航管理',
                                  onSelected: (value) =>
                                      runUi(context, () async {
                                        switch (value) {
                                          case 'categories':
                                            await showDialog<void>(
                                              context: context,
                                              builder: (_) =>
                                                  const WebCategoryManager(),
                                            );
                                          case 'catalog':
                                            await showDialog<void>(
                                              context: context,
                                              builder: (_) =>
                                                  const WebCatalogBrowser(),
                                            );
                                          case 'transfer':
                                            await showDialog<void>(
                                              context: context,
                                              builder: (_) => WebTransferDialog(
                                                selection: selection.keys
                                                    .toList(),
                                              ),
                                            );
                                          case 'trash':
                                            await showDialog<void>(
                                              context: context,
                                              builder: (_) =>
                                                  const WebTrashDialog(),
                                            );
                                          case 'order':
                                            await showWebOrder(
                                              context,
                                              ref.read(webRepositoryProvider),
                                              categoryId: category,
                                            );
                                          case 'density':
                                            setState(() => compact = !compact);
                                            await ref
                                                .read(recordStoreProvider)
                                                .setSetting(
                                                  'webLibrary.density',
                                                  compact
                                                      ? 'compact'
                                                      : 'comfortable',
                                                );
                                          case 'cache':
                                            final n = await WebFaviconService(
                                              ref.read(recordStoreProvider),
                                              () => ref.read(
                                                ownedFilesProvider.future,
                                              ),
                                            ).clear();
                                            if (context.mounted) {
                                              ltMessage(
                                                context,
                                                '已清理$n个缓存图标，自定义图标保留。',
                                              );
                                            }
                                        }
                                      }),
                                  itemBuilder: (_) => [
                                    for (final entry in {
                                      'categories': '分类管理',
                                      'catalog': '精选科技网站目录',
                                      'transfer': '导入 / 导出',
                                      'trash': '网站回收站',
                                      'order': '拖动排序',
                                      'density': compact ? '使用舒适密度' : '使用紧凑密度',
                                      'cache': '清理网站图标缓存',
                                    }.entries)
                                      PopupMenuItem(
                                        value: entry.key,
                                        child: Text(entry.value),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: search,
                          focusNode: searchFocus,
                          decoration: const InputDecoration(
                            labelText: '搜索网站、网址、标签或分类',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (v) {
                            debounce?.cancel();
                            debounce = Timer(
                              const Duration(milliseconds: 250),
                              () {
                                if (mounted) {
                                  setState(() {
                                    query = v;
                                    offset = 0;
                                  });
                                }
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (!wide) ...[
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final id = await pickWebCategory(
                                      context,
                                      categories,
                                    );
                                    if (id != null) {
                                      filter(categoryId: id, viewId: 'all');
                                    }
                                  },
                                  icon: const Icon(Icons.folder_outlined),
                                  label: Text(currentCategory?.name ?? '分类'),
                                ),
                                const SizedBox(width: 8),
                                DropdownButton<String>(
                                  value: view,
                                  items: webViews.entries
                                      .map(
                                        (e) => DropdownMenuItem(
                                          value: e.key,
                                          child: Text(e.value),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) =>
                                      filter(categoryId: '', viewId: v!),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (category.isNotEmpty)
                                ActionChip(
                                  label: const Text('全部分类'),
                                  onPressed: () => filter(categoryId: ''),
                                ),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: sort,
                                items: webSorts.entries
                                    .map(
                                      (e) => DropdownMenuItem(
                                        value: e.key,
                                        child: Text(e.value),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() {
                                  sort = v!;
                                  offset = 0;
                                }),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: list ? '切换网格' : '切换列表',
                                onPressed: () => runUi(context, () async {
                                  setState(() => list = !list);
                                  await ref
                                      .read(recordStoreProvider)
                                      .setSetting(
                                        'webLibrary.layout',
                                        list ? 'list' : 'grid',
                                      );
                                }),
                                icon: Icon(
                                  list
                                      ? Icons.grid_view
                                      : Icons.view_list_outlined,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selection.isNotEmpty)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                Text('已选${selection.length}项'),
                                TextButton(
                                  onPressed: () => batchMove(categories),
                                  child: const Text('移动分类'),
                                ),
                                TextButton(
                                  onPressed: () => runUi(context, () async {
                                    await ref
                                        .read(webRepositoryProvider)
                                        .updateWebsites(
                                          selection.values.toList(),
                                          favorite: true,
                                        );
                                    if (mounted) setState(selection.clear);
                                  }),
                                  child: const Text('收藏'),
                                ),
                                TextButton(
                                  onPressed: () => runUi(context, () async {
                                    final values = await ltEditForm(
                                      context,
                                      title: '添加标签',
                                      fields: const [
                                        LTField(
                                          'tags',
                                          '逗号分隔标签',
                                          required: true,
                                        ),
                                      ],
                                    );
                                    if (values != null) {
                                      await ref
                                          .read(webRepositoryProvider)
                                          .updateWebsites(
                                            selection.values.toList(),
                                            addTags: values['tags']!.split(
                                              RegExp('[,，]'),
                                            ),
                                          );
                                      if (mounted) setState(selection.clear);
                                    }
                                  }),
                                  child: const Text('标签'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      remove(selection.values.toList()),
                                  child: const Text('移入回收站'),
                                ),
                                TextButton(
                                  onPressed: () => setState(selection.clear),
                                  child: const Text('清除选择'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: results.when(
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (e, _) => Center(
                              child: Text(
                                e is ToolFailure ? e.message : '网站加载失败，请重新进入。',
                              ),
                            ),
                            data: (page) {
                              if (page.items.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.travel_explore,
                                        size: 40,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        query.isEmpty ? '此视图还没有网站' : '没有匹配的网站',
                                      ),
                                      TextButton(
                                        onPressed: () => filter(
                                          categoryId: '',
                                          viewId: 'all',
                                        ),
                                        child: const Text('查看全部网站'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return Column(
                                children: [
                                  Expanded(
                                    child: list
                                        ? ListView.builder(
                                            itemCount: page.items.length,
                                            itemBuilder: (_, i) => siteCard(
                                              page.items[i],
                                              categories,
                                            ),
                                          )
                                        : LayoutBuilder(
                                            builder: (context, b) {
                                              final columns =
                                                  ((b.maxWidth + 12) /
                                                          (compact ? 180 : 220))
                                                      .floor()
                                                      .clamp(1, 6);
                                              return GridView.builder(
                                                gridDelegate:
                                                    SliverGridDelegateWithFixedCrossAxisCount(
                                                      crossAxisCount: columns,
                                                      mainAxisExtent: compact
                                                          ? 154
                                                          : 204,
                                                      crossAxisSpacing: 12,
                                                      mainAxisSpacing: 12,
                                                    ),
                                                itemCount: page.items.length,
                                                itemBuilder: (_, i) => siteCard(
                                                  page.items[i],
                                                  categories,
                                                ),
                                              );
                                            },
                                          ),
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                        '共${page.total}个 · ${offset + 1}–${offset + page.items.length}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        tooltip: '上一页',
                                        onPressed: offset == 0
                                            ? null
                                            : () => setState(
                                                () => offset = (offset - 60)
                                                    .clamp(0, 10000),
                                              ),
                                        icon: const Icon(Icons.chevron_left),
                                      ),
                                      IconButton(
                                        tooltip: '下一页',
                                        onPressed: page.hasMore
                                            ? () => setState(() => offset += 60)
                                            : null,
                                        icon: const Icon(Icons.chevron_right),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class WebSiteIcon extends ConsumerWidget {
  const WebSiteIcon(this.site, this.category, {super.key});
  final WebsiteBookmark site;
  final WebsiteCategory? category;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = Icon(
      webIcon(category?.iconKey ?? 'globe'),
      size: 28,
      color: category == null
          ? null
          : Color(
              int.tryParse(
                    category!.color.replaceFirst('#', 'ff'),
                    radix: 16,
                  ) ??
                  0xff8196be,
            ),
    );
    final owned = ref.watch(ownedFilesProvider).asData?.value;
    if (owned == null) return SizedBox(width: 32, height: 32, child: fallback);
    File? file;
    try {
      if (site.customIconPath.isNotEmpty) {
        file = owned.resolve(site.customIconPath);
      } else if (WebFaviconService.validKey(
        site.record.text('faviconCacheKey'),
      )) {
        file = WebFaviconService.cacheFile(
          owned,
          site.record.text('faviconCacheKey'),
        );
      }
    } catch (_) {
      file = null;
    }
    return SizedBox(
      width: 32,
      height: 32,
      child: file == null
          ? fallback
          : Image.file(
              file,
              cacheWidth: 64,
              cacheHeight: 64,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
