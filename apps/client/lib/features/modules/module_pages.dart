import '../../app/data_providers.dart';
import '../web_library/web_favicons.dart';
import '../../core/ui/lt_components.dart';
import '../../app/navigation_controller.dart';
import '../../core/modules/workspace_navigation.dart';
import '../../shared/record_ui.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/logging/app_log.dart';
import '../../core/modules/module_registry.dart';
import '../../shared/page_frame.dart';

class ModulesPage extends ConsumerStatefulWidget {
  const ModulesPage({super.key});
  @override
  ConsumerState<ModulesPage> createState() => _ModulesPageState();
}

class _ModulesPageState extends ConsumerState<ModulesPage> {
  bool _saving = false;
  Future<void> _toggle(String id, bool enabled) async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsProvider.notifier).setModule(id, enabled);
    } catch (error) {
      AppLog.record(AppEvent.settingsWriteFailed, error);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设置未能保存，请检查磁盘空间和权限。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final nav = ref.watch(sidebarControllerProvider).asData?.value;
    return PageFrame(
      eyebrow: 'MODULES',
      title: '模块管理',
      description: '隐藏和禁用仅控制入口，保留数据库、附件和原有深度链接。旧版扩展默认从主工作空间隐藏。',
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('网站图标缓存'),
            subtitle: const Text('只清理可重新获取的favicon；保留网站记录、自定义图标附件和模型。'),
            trailing: TextButton(
              onPressed: () => runUi(context, () async {
                if (!await ltConfirm(
                  context,
                  title: '清理网站图标缓存？',
                  message: '不会删除网站、用户图标或其他附件。',
                )) {
                  return;
                }
                final count = await WebFaviconService(
                  ref.read(recordStoreProvider),
                  () => ref.read(ownedFilesProvider.future),
                ).clear();
                if (context.mounted) ltMessage(context, '已清理$count个缓存文件。');
              }),
              child: const Text('清理缓存'),
            ),
          ),
        ),
        for (final module in modules)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: SwitchListTile(
                key: ValueKey('toggle-${module.moduleId}'),
                value: settings.moduleEnabled(
                  module.moduleId,
                  defaultEnabled: module.enabled,
                ),
                onChanged: _saving || coreModuleIds.contains(module.moduleId)
                    ? null
                    : (enabled) => _toggle(module.moduleId, enabled),
                secondary: Icon(module.icon),
                title: Text(module.displayName),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${moduleVisibility(module.moduleId, enabled: settings.moduleEnabled(module.moduleId, defaultEnabled: module.enabled)).name.toUpperCase()} · v${module.version}',
                    ),
                    Text(module.description),
                    if (legacyModuleIds.contains(module.moduleId))
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('显示在其他工具 / 旧版扩展'),
                        value:
                            nav?.visibleLegacy.contains(module.moduleId) ??
                            false,
                        onChanged: nav == null
                            ? null
                            : (v) => runUi(
                                context,
                                () => ref
                                    .read(sidebarControllerProvider.notifier)
                                    .change(
                                      (s) => s.copyWith(
                                        visibleLegacy: v
                                            ? {
                                                ...s.visibleLegacy,
                                                module.moduleId,
                                              }
                                            : ({...s.visibleLegacy}
                                                ..remove(module.moduleId)),
                                      ),
                                    ),
                              ),
                      ),
                    if (!legacyModuleIds.contains(module.moduleId))
                      Row(
                        children: [
                          const Text('侧栏分类内排序'),
                          IconButton(
                            tooltip: '提前显示',
                            icon: const Icon(Icons.vertical_align_top),
                            onPressed: nav == null
                                ? null
                                : () => runUi(
                                    context,
                                    () => ref
                                        .read(
                                          sidebarControllerProvider.notifier,
                                        )
                                        .change(
                                          (s) => s.copyWith(
                                            order: [
                                              module.moduleId,
                                              ...s.order.where(
                                                (id) => id != module.moduleId,
                                              ),
                                            ],
                                          ),
                                        ),
                                  ),
                          ),
                          IconButton(
                            tooltip: '延后显示',
                            icon: const Icon(Icons.vertical_align_bottom),
                            onPressed: nav == null
                                ? null
                                : () => runUi(
                                    context,
                                    () => ref
                                        .read(
                                          sidebarControllerProvider.notifier,
                                        )
                                        .change(
                                          (s) => s.copyWith(
                                            order: [
                                              ...{
                                                ...s.order,
                                                ...workspaceSections
                                                    .expand((g) => g.items)
                                                    .map((i) => i.id),
                                              }.where(
                                                (id) => id != module.moduleId,
                                              ),
                                              module.moduleId,
                                            ],
                                          ),
                                        ),
                                  ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
