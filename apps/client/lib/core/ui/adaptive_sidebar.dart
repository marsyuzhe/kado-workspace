import 'package:flutter/material.dart';

import '../../app/brand_config.dart';
import '../modules/module_registry.dart';
import '../modules/navigation_state_repository.dart';
import '../modules/workspace_navigation.dart';
import 'app_theme.dart';

typedef SidebarMutation = void Function(
  NavigationState Function(NavigationState),
);

class AdaptiveSidebar extends StatefulWidget {
  const AdaptiveSidebar({
    super.key,
    required this.uri,
    required this.state,
    required this.onChange,
    required this.onNavigate,
    required this.enabled,
    required this.onAbout,
    this.compact = false,
    this.allowResize = true,
  });
  final Uri uri;
  final NavigationState state;
  final SidebarMutation onChange;
  final ValueChanged<String> onNavigate;
  final bool Function(String) enabled;
  final VoidCallback onAbout;
  final bool compact, allowResize;
  @override
  State<AdaptiveSidebar> createState() => _AdaptiveSidebarState();
}

class _AdaptiveSidebarState extends State<AdaptiveSidebar> {
  double? draggedWidth;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    final compact = widget.compact, prefs = widget.state;
    Widget item(WorkspaceDestination d) => SidebarItem(
      key: ValueKey('nav-${d.id}'),
      icon: d.icon,
      label: d.label,
      compact: compact,
      selected: d.matches(widget.uri),
      onTap: () => widget.onNavigate(d.route),
    );
    final groups = <Widget>[];
    for (final group in workspaceSections) {
      final entries = group.items
          .where(
            (i) => isRegisteredDestination(i) && widget.enabled(i.moduleId),
          )
          .toList();
      entries.sort((a, b) {
        int rank(String id) {
          final index = prefs.order.indexOf(id);
          return index < 0 ? 999 : index;
        }

        final diff = rank(a.id).compareTo(rank(b.id));
        return diff == 0
            ? group.items.indexOf(a).compareTo(group.items.indexOf(b))
            : diff;
      });
      if (entries.isEmpty) continue;
      groups.add(
        SidebarGroup(
          key: ValueKey('group-${group.id}'),
          label: group.label,
          icon: group.icon,
          compact: compact,
          open: !prefs.closedGroups.contains(group.id),
          onToggle: () => widget.onChange(
            (s) => s.copyWith(
              closedGroups: s.closedGroups.contains(group.id)
                  ? ({...s.closedGroups}..remove(group.id))
                  : {...s.closedGroups, group.id},
            ),
          ),
          children: entries.map(item).toList(),
        ),
      );
    }
    final legacy = modules
        .where(
          (m) =>
              legacyModuleIds.contains(m.moduleId) &&
              prefs.visibleLegacy.contains(m.moduleId) &&
              widget.enabled(m.moduleId),
        )
        .toList();
    return AnimatedContainer(
      duration: draggedWidth == null
          ? AppMotion.duration(context)
          : Duration.zero,
      width: compact ? 72 : draggedWidth ?? prefs.width,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Image.asset(
                      AppBrandConfig.iconAsset,
                      width: 36,
                      height: 36,
                      cacheWidth: 96,
                      cacheHeight: 96,
                    ),
                    if (!compact)
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: 10),
                          child: Text(
                            AppBrandConfig.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SidebarItem(
                icon: Icons.search,
                label: '搜索 / Ctrl+K',
                compact: compact,
                selected: widget.uri.path == '/search',
                onTap: () => widget.onNavigate('/search'),
              ),
              const Divider(height: 12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    SidebarItem(
                      icon: Icons.space_dashboard_outlined,
                      label: '首页',
                      compact: compact,
                      selected: {'/', '/modules/hub'}.contains(widget.uri.path),
                      onTap: () => widget.onNavigate('/'),
                    ),
                    if (widget.enabled('bookmarks'))
                      SidebarItem(
                        key: const ValueKey('nav-bookmarks'),
                        icon: Icons.language,
                        label: '网站导航',
                        compact: compact,
                        selected: widget.uri.path == '/modules/bookmarks',
                        onTap: () => widget.onNavigate('/modules/bookmarks'),
                      ),
                    SidebarSection(
                      label: '科技工作空间',
                      icon: Icons.workspaces_outline,
                      open: prefs.workspaceOpen,
                      compact: compact,
                      onToggle: () => widget.onChange(
                        (s) => s.copyWith(workspaceOpen: !s.workspaceOpen),
                      ),
                      children: groups,
                    ),
                    if (legacy.isNotEmpty)
                      SidebarGroup(
                        label: '其他工具 / 旧版扩展',
                        icon: Icons.extension_outlined,
                        compact: compact,
                        open: !prefs.closedGroups.contains('legacy'),
                        onToggle: () => widget.onChange(
                          (s) => s.copyWith(
                            closedGroups: s.closedGroups.contains('legacy')
                                ? ({...s.closedGroups}..remove('legacy'))
                                : {...s.closedGroups, 'legacy'},
                          ),
                        ),
                        children: [
                          for (final m in legacy)
                            SidebarItem(
                              icon: m.icon,
                              label: m.displayName,
                              compact: compact,
                              selected: widget.uri.path == m.route,
                              onTap: () => widget.onNavigate(m.route),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const Divider(height: 8),
              SidebarItem(
                icon: Icons.tune_rounded,
                label: '设置',
                compact: compact,
                selected: widget.uri.path == '/settings',
                onTap: () => widget.onNavigate('/settings'),
              ),
              SidebarItem(
                icon: Icons.info_outline,
                label: '关于',
                compact: compact,
                selected: false,
                onTap: widget.onAbout,
              ),
              if (widget.allowResize)
                SidebarItem(
                  icon: compact ? Icons.chevron_right : Icons.chevron_left,
                  label: compact ? '展开侧栏' : '紧凑侧栏',
                  compact: compact,
                  selected: false,
                  onTap: () =>
                      widget.onChange((s) => s.copyWith(compact: !s.compact)),
                ),
              const SizedBox(height: 8),
            ],
          ),
          if (!compact && widget.allowResize)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) => setState(
                    () => draggedWidth =
                        ((draggedWidth ?? prefs.width) + d.delta.dx).clamp(
                          196,
                          280,
                        ),
                  ),
                  onHorizontalDragEnd: (_) {
                    final width = draggedWidth;
                    setState(() => draggedWidth = null);
                    if (width != null) {
                      widget.onChange((s) => s.copyWith(width: width));
                    }
                  },
                  onHorizontalDragCancel: () =>
                      setState(() => draggedWidth = null),
                  child: const SizedBox(width: 6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SidebarItem extends StatelessWidget {
  const SidebarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.compact,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool compact, selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    final height = MediaQuery.sizeOf(context).width < AppBreakpoints.phone
        ? 48.0
        : Theme.of(context).visualDensity == VisualDensity.compact
        ? 40.0
        : 44.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Tooltip(
        message: label,
        child: Semantics(
          selected: selected,
          button: true,
          child: Material(
            color: selected ? t.surfaceElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.medium),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.medium),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 4 : 10,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      Icon(
                        icon,
                        size: 20,
                        color: selected ? t.accent : t.textSecondary,
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SidebarGroup extends StatelessWidget {
  const SidebarGroup({
    super.key,
    required this.label,
    required this.icon,
    required this.open,
    required this.compact,
    required this.onToggle,
    required this.children,
  });
  final String label;
  final IconData icon;
  final bool open, compact;
  final VoidCallback onToggle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Tooltip(
        message: '$label · ${open ? '收起' : '展开'}',
        child: InkWell(
          key: ValueKey('toggle-$label'),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(icon, size: 18),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ],
            ),
          ),
        ),
      ),
      AnimatedSize(
        duration: AppMotion.duration(context),
        alignment: Alignment.topCenter,
        child: open
            ? Padding(
                padding: EdgeInsets.only(left: compact ? 0 : 8),
                child: Column(children: children),
              )
            : const SizedBox(width: double.infinity),
      ),
    ],
  );
}

class SidebarSection extends SidebarGroup {
  const SidebarSection({
    super.key,
    required super.label,
    required super.icon,
    required super.open,
    required super.compact,
    required super.onToggle,
    required super.children,
  });
}
