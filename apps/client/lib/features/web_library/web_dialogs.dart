import 'package:flutter/material.dart';

import '../../core/data/tool_record.dart';
import '../../shared/record_ui.dart';
import '../utilities/bookmark_metadata.dart';
import 'web_models.dart';
import 'web_repository.dart';

IconData webIcon(String key) => switch (key) {
  'spark' => Icons.auto_awesome_outlined,
  'code' => Icons.code,
  'book' => Icons.menu_book_outlined,
  'cloud' => Icons.cloud_outlined,
  'forum' => Icons.forum_outlined,
  'model' => Icons.hub_outlined,
  'design' => Icons.palette_outlined,
  'media' => Icons.movie_outlined,
  'workflow' => Icons.account_tree_outlined,
  'game' => Icons.sports_esports_outlined,
  'school' => Icons.school_outlined,
  'shopping' => Icons.shopping_bag_outlined,
  'work' => Icons.work_outline,
  'star' => Icons.star_outline,
  'folder' => Icons.folder_outlined,
  _ => Icons.language,
};
String categoryLabel(WebsiteCategory c, List<WebsiteCategory> all) {
  final parent = all.where((p) => p.id == c.parentId).firstOrNull;
  return parent == null ? c.name : '${parent.name} / ${c.name}';
}

Future<String?> pickWebCategory(
  BuildContext context,
  List<WebsiteCategory> categories, {
  String? title,
  Set<String> exclude = const {},
}) => showDialog<String>(
  context: context,
  builder: (context) => _CategoryPicker(
    categories.where((c) => !exclude.contains(c.id)).toList(),
    title ?? '选择分类',
  ),
);

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker(this.categories, this.title);
  final List<WebsiteCategory> categories;
  final String title;
  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.categories
        .where(
          (c) => categoryLabel(
            c,
            widget.categories,
          ).toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '搜索分类',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (s) => setState(() => query = s),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: matches.isEmpty
                  ? const Center(child: Text('没有匹配分类'))
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, i) {
                        final c = matches[i];
                        return ListTile(
                          leading: Icon(webIcon(c.iconKey)),
                          title: Text(categoryLabel(c, widget.categories)),
                          trailing: c.isHidden
                              ? const Icon(Icons.visibility_off_outlined)
                              : null,
                          onTap: () => Navigator.pop(context, c.id),
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
          child: const Text('取消'),
        ),
      ],
    );
  }
}

Future<WebsiteInput?> editWebsiteDialog(
  BuildContext context,
  List<WebsiteCategory> categories, {
  WebsiteBookmark? site,
  String? categoryId,
}) => showDialog<WebsiteInput>(
  context: context,
  builder: (context) => _WebsiteEditor(categories, site, categoryId),
);

class _WebsiteEditor extends StatefulWidget {
  const _WebsiteEditor(this.categories, this.site, this.category);
  final List<WebsiteCategory> categories;
  final WebsiteBookmark? site;
  final String? category;
  @override
  State<_WebsiteEditor> createState() => _WebsiteEditorState();
}

class _WebsiteEditorState extends State<_WebsiteEditor> {
  late final title = TextEditingController(text: widget.site?.title ?? ''),
      url = TextEditingController(text: widget.site?.url ?? ''),
      description = TextEditingController(text: widget.site?.description ?? ''),
      tags = TextEditingController(text: widget.site?.tags.join(', ') ?? ''),
      alternate = TextEditingController(
        text: widget.site?.record.text('alternateUrl') ?? '',
      );
  late String category =
      widget.site?.categoryId ?? widget.category ?? uncategorizedId;
  late bool favorite = widget.site?.isFavorite ?? false,
      pinned = widget.site?.isPinned ?? false;
  bool fetching = false;
  String? error;
  @override
  void dispose() {
    for (final c in [title, url, description, tags, alternate]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.categories.where((c) => c.id == category).firstOrNull;
    return AlertDialog(
      title: Text(widget.site == null ? '添加网站' : '编辑网站'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 300,
                decoration: const InputDecoration(labelText: '网站名称'),
              ),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '网址',
                  hintText: 'example.com，自动补全https://',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: fetching
                      ? null
                      : () => runUi(context, () async {
                          final target = normalizeWebsiteUrl(url.text);
                          setState(() => fetching = true);
                          try {
                            final metadata = await BookmarkMetadataService()
                                .fetch(target);
                            if (mounted) {
                              setState(() {
                                title.text = metadata.title;
                                description.text = metadata.description;
                                url.text = target;
                              });
                            }
                          } finally {
                            if (mounted) setState(() => fetching = false);
                          }
                        }),
                  icon: fetching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text('读取此网页的公开标题和描述'),
                ),
              ),
              const Text(
                '仅在点击后联网。无法读取时可直接手动保存。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final id = await pickWebCategory(context, widget.categories);
                  if (id != null && mounted) setState(() => category = id);
                },
                icon: Icon(webIcon(c?.iconKey ?? 'folder')),
                label: Text(
                  c == null ? '选择分类' : categoryLabel(c, widget.categories),
                ),
              ),
              TextField(
                controller: description,
                maxLines: 3,
                maxLength: 4000,
                decoration: const InputDecoration(labelText: '描述'),
              ),
              TextField(
                controller: tags,
                decoration: const InputDecoration(
                  labelText: '标签',
                  hintText: '用英文或中文逗号分隔',
                ),
              ),
              TextField(
                controller: alternate,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: '备用网址（可选）'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('加入收藏'),
                value: favorite,
                onChanged: (v) => setState(() => favorite = v!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('固定首页'),
                value: pinned,
                onChanged: (v) => setState(() => pinned = v!),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: fetching
              ? null
              : () {
                  try {
                    final value = WebsiteInput(
                      title.text,
                      url.text,
                      description: description.text,
                      categoryId: category,
                      tags: tags.text
                          .split(RegExp('[,，]'))
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList(),
                      isFavorite: favorite,
                      isPinned: pinned,
                      alternateUrl: alternate.text,
                    );
                    value.validate();
                    Navigator.pop(context, value);
                  } on ToolFailure catch (e) {
                    setState(() => error = e.message);
                  }
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> editWebCategory(
  BuildContext context,
  WebLibraryRepository repo,
  List<WebsiteCategory> all, {
  WebsiteCategory? category,
}) async {
  String parent = category?.parentId ?? '',
      icon = category?.iconKey ?? 'folder';
  bool hidden = category?.isHidden ?? false;
  final name = TextEditingController(text: category?.name ?? ''),
      desc = TextEditingController(text: category?.description ?? ''),
      color = TextEditingController(text: category?.color ?? '#8196BE');
  try {
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(category == null ? '新建分类' : '编辑分类'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    maxLength: 300,
                    decoration: const InputDecoration(labelText: '分类名称'),
                  ),
                  TextField(
                    controller: desc,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: '分类描述'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: icon,
                    decoration: const InputDecoration(labelText: '分类图标'),
                    items: webIconKeys
                        .map(
                          (key) => DropdownMenuItem(
                            value: key,
                            child: Icon(webIcon(key)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => icon = v!),
                  ),
                  TextField(
                    controller: color,
                    decoration: const InputDecoration(
                      labelText: '颜色，如 #8196BE',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: category?.id == uncategorizedId
                        ? null
                        : () async {
                            final eligible = all
                                .where(
                                  (c) =>
                                      c.parentId.isEmpty &&
                                      c.id != category?.id &&
                                      c.id != uncategorizedId,
                                )
                                .toList();
                            final id = await pickWebCategory(
                              context,
                              eligible,
                              title: '选择上级（最多两层）',
                            );
                            if (id != null && context.mounted) {
                              setState(() => parent = id);
                            }
                          },
                    child: Text(
                      parent.isEmpty
                          ? '位于顶层'
                          : '上级：${all.where((c) => c.id == parent).firstOrNull?.name ?? ''}',
                    ),
                  ),
                  if (parent.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() => parent = ''),
                      child: const Text('移至顶层'),
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: hidden,
                    title: const Text('隐藏分类及其网站'),
                    onChanged: (v) => setState(() => hidden = v!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => runUi(context, () async {
                await repo.saveCategory(
                  WebsiteCategoryInput(
                    name.text,
                    description: desc.text,
                    iconKey: icon,
                    parentId: parent,
                    color: color.text.trim(),
                    isHidden: hidden,
                    sortOrder: category?.sortOrder ?? all.length,
                  ),
                  existing: category,
                );
                if (context.mounted) Navigator.pop(context);
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
  } finally {
    name.dispose();
    desc.dispose();
    color.dispose();
  }
}
