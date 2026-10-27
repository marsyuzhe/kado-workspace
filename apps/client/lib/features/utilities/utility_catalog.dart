import '../../app/navigation_controller.dart';
import '../../core/modules/workspace_navigation.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../app/providers.dart';
import '../../core/modules/module_registry.dart';
import '../../core/platform/system_actions.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/record_ui.dart';
import '../hub/hub_actions.dart';

const utilityGroups = <String, List<(String, String)>>{
  '媒体工具': [
    ('converter', '07 格式转换'),
    ('image_studio', '09 图片处理'),
    ('transcribe', '10 本地转写'),
    ('media_library', '11 视频素材'),
  ],
  '文件与系统': [
    ('renamer', '08 批量重命名'),
    ('software_library', '13 安装包管家'),
    ('environment_snapshot', '14 Windows环境备份'),
    ('game_saves', '17 游戏存档'),
  ],
  '网络与家庭': [('lan_transfer', '15 局域网互传'), ('home_dashboard', '16 家庭设备')],
  '个人工具': [
    ('bookmarks', '12 个人收藏'),
    ('finance', '18 记账分析'),
    ('collection_cards', '19 收藏卡'),
    ('timeline', '20 待办时间轴'),
  ],
};

class UtilityCatalogPage extends ConsumerStatefulWidget {
  const UtilityCatalogPage({super.key});
  @override
  ConsumerState<UtilityCatalogPage> createState() => _UtilityCatalogPageState();
}

class _UtilityCatalogPageState extends ConsumerState<UtilityCatalogPage> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final visibleLegacy =
        ref.watch(sidebarControllerProvider).asData?.value.visibleLegacy ??
        <String>{};
    final settings = ref.watch(settingsProvider),
        favorites = ref.watch(favoritesProvider).asData?.value ?? [];
    final recent = ref.watch(recentActionsProvider).asData?.value ?? [];
    final ids = utilityGroups.values.expand((v) => v).map((v) => v.$1).toSet();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '工具中心',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        const Text('按用途选择工具；旧版扩展在设置的模块管理中开启。'),
        const SizedBox(height: 16),
        LTToolbar(
          children: [
            LTButton(
              label: '查看工具任务',
              icon: Icons.pending_actions,
              onPressed: () => context.go('/modules/utility_jobs'),
            ),
            TextButton(
              onPressed: () => context.go('/modules/utilities?view=legacy'),
              child: const Text('经典四页工具'),
            ),
          ],
        ),
        LTTextField(
          label: '搜索工具名称或用途',
          onChanged: (v) => setState(() => query = v.toLowerCase()),
        ),
        if (recent.any((r) => ids.contains(r.moduleId))) ...[
          const SizedBox(height: 16),
          const Text('最近使用'),
          Wrap(
            spacing: 8,
            children: [
              for (final r
                  in recent.where((r) => ids.contains(r.moduleId)).take(6))
                ActionChip(
                  label: Text(r.title),
                  onPressed: () => runUi(
                    context,
                    () => openTarget(
                      context,
                      ref,
                      TargetAction.fromJson(
                        Map<String, dynamic>.from(jsonDecode(r.action) as Map),
                      ),
                      title: r.title,
                    ),
                  ),
                ),
            ],
          ),
        ],
        for (final group in utilityGroups.entries) ...[
          const SizedBox(height: 24),
          Text(
            group.key,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final entry in group.value)
            if ((!legacyModuleIds.contains(entry.$1) ||
                    visibleLegacy.contains(entry.$1)) &&
                '${entry.$2} ${moduleById(entry.$1)?.description ?? ''}'
                    .toLowerCase()
                    .contains(query))
              Builder(
                builder: (context) {
                  final module = moduleById(entry.$1),
                      pins = favorites
                          .where(
                            (r) =>
                                r.text('targetKey') ==
                                TargetAction('module', entry.$1).key,
                          )
                          .toList();
                  final enabled =
                      module != null &&
                      settings.moduleEnabled(
                        entry.$1,
                        defaultEnabled: module.enabled,
                      );
                  return LTCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(module?.icon ?? Icons.hourglass_empty),
                      title: Text(entry.$2),
                      subtitle: Text(
                        module?.description ?? 'TODO · 尚无可用执行器，未开放入口',
                      ),
                      onTap: !enabled
                          ? null
                          : () => runUi(
                              context,
                              () => openTarget(
                                context,
                                ref,
                                TargetAction('module', entry.$1),
                              ),
                            ),
                      trailing: module == null
                          ? const Text('开发中')
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!enabled) const Text('已禁用'),
                                IconButton(
                                  tooltip: pins.isEmpty ? '固定到工作台' : '取消工作台固定',
                                  icon: Icon(
                                    pins.isEmpty
                                        ? Icons.push_pin_outlined
                                        : Icons.push_pin,
                                  ),
                                  onPressed: () => runUi(context, () async {
                                    final hub = ref.read(hubRepositoryProvider);
                                    if (pins.isEmpty) {
                                      final row = await hub.addFavorite(
                                        entry.$2,
                                        TargetAction('module', entry.$1),
                                        category: '工具',
                                      );
                                      await hub.updateFavorite(
                                        row,
                                        pinned: true,
                                      );
                                    } else {
                                      await hub.removeFavorite(pins.first);
                                    }
                                  }),
                                ),
                                if (enabled) const Icon(Icons.chevron_right),
                              ],
                            ),
                    ),
                  );
                },
              ),
        ],
      ],
    );
  }
}
