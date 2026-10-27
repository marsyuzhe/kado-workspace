import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/modules/module_registry.dart';
import '../core/modules/navigation_state_repository.dart';
import '../core/ui/adaptive_sidebar.dart';
import '../core/ui/app_theme.dart';
import '../core/ui/lt_components.dart';
import '../core/platform/system_actions.dart';
import '../features/hub/hub_actions.dart';
import '../shared/record_ui.dart';
import 'brand_config.dart';
import 'navigation_controller.dart';
import 'providers.dart';
import 'version.dart';

class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell> {
  String? previousRoute;
  void reveal(Uri uri) {
    if (previousRoute == uri.toString()) return;
    previousRoute = uri.toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          runUi(
            context,
            () => ref.read(sidebarControllerProvider.notifier).reveal(uri),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final uri = GoRouterState.of(context).uri,
        settings = ref.watch(settingsProvider),
        persisted = ref.watch(sidebarControllerProvider),
        prefs = persisted.asData?.value ?? const NavigationState(),
        t = Theme.of(context).extension<DesignTokens>()!;
    if (persisted.hasValue) reveal(uri);
    bool enabled(String id) {
      final m = moduleById(id);
      return m != null && settings.moduleEnabled(id, defaultEnabled: m.enabled);
    }

    void navigate(String route) {
      // Query destinations retain their exact URI; record the module usage once.
      final target = Uri.parse(route);
      if (target.path.startsWith('/modules/') && !target.hasQuery) {
        unawaited(
          runUi(
            context,
            () => openTarget(
              context,
              ref,
              TargetAction('module', target.pathSegments.last),
            ),
          ),
        );
      } else {
        context.go(route);
      }
    }

    void about() => showAboutDialog(
      context: context,
      applicationName: AppBrandConfig.displayName,
      applicationVersion: appVersion,
      applicationLegalese: AppBrandConfig.legal,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            context.go('/search'),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            context.go('/search'),
      },
      child: LayoutBuilder(
        builder: (context, c) {
          final phone = c.maxWidth < AppBreakpoints.phone;
          final compact = prefs.compact || c.maxWidth < 1000;
          final selected = uri.path == '/modules/bookmarks'
              ? 1
              : uri.path.startsWith('/modules')
              ? 2
              : uri.path == '/settings'
              ? 3
              : 0;
          Widget sidebar({bool drawer = false}) => AdaptiveSidebar(
            uri: uri,
            state: prefs,
            compact: drawer ? false : compact,
            allowResize: !drawer && c.maxWidth >= 1000,
            enabled: enabled,
            onAbout: about,
            onChange: (change) => unawaited(
              runUi(
                context,
                () =>
                    ref.read(sidebarControllerProvider.notifier).change(change),
              ),
            ),
            onNavigate: (route) {
              if (drawer) Navigator.of(context).pop();
              navigate(route);
            },
          );
          return Scaffold(
            drawer: phone
                ? Drawer(
                    width: prefs.width,
                    child: SafeArea(child: sidebar(drawer: true)),
                  )
                : null,
            bottomNavigationBar: phone
                ? NavigationBar(
                    selectedIndex: selected,
                    onDestinationSelected: (i) => context.go(
                      ['/', '/modules/bookmarks', '/modules', '/settings'][i],
                    ),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.space_dashboard_outlined),
                        label: '工作台',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.language),
                        label: '网站',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.workspaces_outline),
                        label: '工具',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.tune_rounded),
                        label: '设置',
                      ),
                    ],
                  )
                : null,
            body: SafeArea(
              child: Row(
                children: [
                  if (!phone) sidebar(),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: t.border)),
                          ),
                          child: Row(
                            children: [
                              if (phone)
                                Builder(
                                  builder: (context) => IconButton(
                                    tooltip: '科技工作空间',
                                    icon: const Icon(Icons.menu),
                                    onPressed: () =>
                                        Scaffold.of(context).openDrawer(),
                                  ),
                                ),
                              Expanded(
                                child: InkWell(
                                  onTap: () => context.go('/search'),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.search, size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            phone ? '搜索' : '搜索模块、笔记和本地内容',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: t.textSecondary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                        if (!phone) const LTBadge('Ctrl K'),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (persisted.hasError)
                                IconButton(
                                  tooltip: '导航设置读取失败，点击重试',
                                  icon: const Icon(Icons.error_outline),
                                  onPressed: () {
                                    previousRoute = null;
                                    ref.invalidate(sidebarControllerProvider);
                                  },
                                ),
                              const SizedBox(width: 8),
                              const LTBadge('本地模式'),
                            ],
                          ),
                        ),
                        Expanded(child: widget.child),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
