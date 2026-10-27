import '../features/dev_tools/github_projects_page.dart';
import '../features/dev_tools/project_inspection_page.dart';
import '../features/dev_tools/workflow_page.dart';
import '../features/dev_tools/snippet_page.dart';
import '../features/dev_tools/network_inspector_page.dart';
import '../features/dev_tools/log_page.dart';
import '../features/dev_tools/api_studio_page.dart';
import '../features/dev_tools/data_formatter_page.dart';
import '../features/dev_tools/regex_page.dart';
import '../features/dev_tools/hash_page.dart';
import 'brand_config.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/modules/module_registry.dart';
import '../core/ui/app_theme.dart';
import '../features/hub/workspace_page.dart';
import '../features/modules/module_pages.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/component_gallery.dart';
import '../features/hub/search_page.dart';
import '../features/clipboard/clipboard_page.dart';
import '../features/archive/archive_page.dart';
import '../features/memory/memory_page.dart';
import '../features/ai_desk/ai_page.dart';
import '../features/server/server_page.dart';
import '../features/studio/studio_page.dart';
import '../features/utilities/utilities_page.dart';
import '../features/utilities/utility_catalog.dart';
import '../features/utilities/renamer_page.dart';
import '../features/utilities/job_widgets.dart';
import '../features/utilities/converter_page.dart';
import '../features/utilities/transcribe_page.dart';
import '../features/utilities/utility_providers.dart';
import '../features/utilities/media_library_page.dart';
import '../features/utilities/software_library_page.dart';
import '../features/utilities/environment_snapshot_page.dart';
import '../features/utilities/home_dashboard_page.dart';
import '../features/utilities/game_saves_page.dart';
import '../features/utilities/lan_transfer_page.dart';
import '../features/utilities/finance_page.dart';
import '../features/utilities/collection_page.dart';
import '../features/utilities/timeline_page.dart';
import '../features/utilities/timeline_providers.dart';
import '../shared/record_landing.dart';
import 'data_providers.dart';
import 'providers.dart';
import 'workspace_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(settingsProvider, (_, next) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/',
    onEnter: (context, current, next, router) async =>
        await ref.read(navigationSaveGuardProvider).before(next.uri)
        ? const Allow()
        : const Block.stop(),
    refreshListenable: refresh,
    routes: [
      ShellRoute(
        builder: (context, state, child) => WorkspaceShell(child: child),
        routes: [
          if (kDebugMode)
            GoRoute(
              path: '/dev/components',
              builder: (_, state) => const ComponentGallery(),
            ),
          GoRoute(path: '/', builder: (_, state) => const WorkspacePage()),
          GoRoute(path: '/search', builder: (_, state) => const SearchPage()),
          GoRoute(path: '/modules', builder: (_, state) => const ModulesPage()),
          GoRoute(
            path: '/settings',
            builder: (_, state) => const SettingsPage(),
          ),
          GoRoute(
            path: '/modules/:id',
            redirect: (_, state) {
              final id = state.pathParameters['id']!;
              final module = moduleById(id);
              if (module == null ||
                  !ref
                      .read(settingsProvider)
                      .moduleEnabled(id, defaultEnabled: module.enabled)) {
                return '/modules';
              }
              return null;
            },
            builder: (_, state) => _modulePage(state),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('这个页面不存在'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('返回工作台'),
            ),
          ],
        ),
      ),
    ),
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

/// Routing is independent of sidebar placement. Keep legacy IDs/query views so
/// saved links, favorites and record landing pages survive navigation changes.
Widget _modulePage(GoRouterState state) {
  final id = state.pathParameters['id']!, query = state.uri.queryParameters;
  if (query['id'] case final String recordId) {
    return RecordLanding(moduleId: id, id: recordId);
  }
  return switch (id) {
    'github_projects' => const GitHubProjectsPage(),
    'dependency_inspector' => const ProjectInspectionPage(),
    'environment_diff' => const ProjectInspectionPage(environment: true),
    'workflow' => const LocalWorkflowPage(),
    'snippets' => const SnippetLibraryPage(),
    'network_inspector' => const NetworkInspectorPage(),
    'log_viewer' => const LogViewerPage(),
    'api_studio' => const ApiStudioPage(),
    'data_formatter' => const DataFormatterPage(),
    'regex_lab' => const RegexLabPage(),
    'hash_inspector' => const HashInspectorPage(),
    'utilities' =>
      query['view'] == 'legacy'
          ? const UtilitiesPage()
          : const UtilityCatalogPage(),
    'image_studio' => const ImageWorkbench(),
    'converter' => ConverterPage(initialTab: query['view'] == 'media' ? 1 : 0),
    'transcribe' => const TranscribePage(),
    'media_library' => const MediaLibraryPage(),
    'software_library' => const SoftwareLibraryPage(),
    'environment_snapshot' => const EnvironmentSnapshotPage(),
    'collection_cards' => const CollectionPage(),
    'finance' => const FinancePage(),
    'lan_transfer' => const LanTransferPage(),
    'game_saves' => const GameSavesPage(),
    'home_dashboard' => const HomeDashboardPage(),
    'bookmarks' => const BookmarksPage(),
    'renamer' => const RenamerPage(),
    'timeline' => const TimelinePage(),
    'utility_jobs' => const UtilityJobsPage(),
    'studio' => StudioPage(
      key: ValueKey(state.uri.toString()),
      initialTab: query['view'] == 'tasks' ? 1 : 0,
    ),
    'clipboard' => ClipboardPage(
      key: ValueKey(state.uri.toString()),
      initialPrompts: query['view'] == 'prompts',
    ),
    'archive' => const ArchivePage(),
    'memory' => const MemoryPage(),
    'ai_desk' => AiDeskPage(key: ValueKey(state.uri.toString())),
    'server' => const ServerPage(),
    'hub' => const WorkspacePage(),
    _ => const ModulesPage(),
  };
}

class LinksToolboxApp extends ConsumerStatefulWidget {
  const LinksToolboxApp({super.key});
  @override
  ConsumerState<LinksToolboxApp> createState() => _LinksToolboxAppState();
}

class _LinksToolboxAppState extends ConsumerState<LinksToolboxApp> {
  StreamSubscription<void>? _hotkey;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hotkey = ref.read(nativePlatformProvider).hotkeys.listen((_) {
        if (mounted) ref.read(routerProvider).go('/search');
      });
      unawaited(ref.read(hotkeyProvider.notifier).initialize());
      unawaited(ref.read(clipboardProvider.notifier).initialize());
      unawaited(
        ref.read(timelineReminderControllerProvider.notifier).initialize(),
      );
      unawaited(
        ref.read(nativePlatformProvider).setCloseGuard(() async {
          if (!await ref
              .read(navigationSaveGuardProvider)
              .before(Uri(path: '/closing'))) {
            return false;
          }
          await ref.read(timelineReminderControllerProvider.notifier).stop();
          await ref.read(utilityJobsProvider).dispose();
          return true;
        }),
      );
    });
  }

  @override
  void dispose() {
    _hotkey?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: AppBrandConfig.displayName,
    debugShowCheckedModeBanner: false,
    theme: appTheme(
      Brightness.light,
      compact: ref.watch(settingsProvider).compact,
    ),
    darkTheme: appTheme(
      Brightness.dark,
      compact: ref.watch(settingsProvider).compact,
    ),
    themeMode: ref.watch(settingsProvider).themeMode,
    routerConfig: ref.watch(routerProvider),
    builder: (context, child) => Column(
      children: [
        TimelineReminderBanner(
          onOpen: () => ref.read(routerProvider).go('/modules/timeline'),
        ),
        Expanded(child: child ?? const SizedBox.shrink()),
      ],
    ),
  );
}
