import 'package:links_toolbox/core/modules/workspace_navigation.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:links_toolbox/app/navigation_controller.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/app/workspace_shell.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/modules/navigation_state_repository.dart';
import 'package:links_toolbox/core/ui/app_theme.dart';

import 'persistence_ui_support.dart';

void main() {
  test('core home and websites stay available, optional disabled state remains real', () {
    const settings = LocalSettings(
      enabled: {'hub': false, 'bookmarks': false, 'archive': false},
    );
    expect(settings.moduleEnabled('hub'), true);
    expect(settings.moduleEnabled('bookmarks'), true);
    expect(settings.moduleEnabled('archive'), false);
    expect(
      moduleVisibility('bookmarks', enabled: false),
      ModuleVisibility.core,
    );
    expect(
      moduleVisibility('archive', enabled: false),
      ModuleVisibility.disabled,
    );
    expect(moduleVisibility('archive'), ModuleVisibility.optional);
    expect(moduleVisibility('finance'), ModuleVisibility.legacy);
  });
  late Directory temp;
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kado-v24-nav-');
    db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  test(
    'navigation, density and legacy placement survive actual database reopen',
    () async {
      final ctl = container.read(sidebarControllerProvider.notifier);
      await container.read(sidebarControllerProvider.future);
      await Future.wait([
        ctl.change(
          (s) =>
              s.copyWith(workspaceOpen: false, closedGroups: {'files', 'ai'}),
        ),
        ctl.change(
          (s) =>
              s.copyWith(width: 999, compact: true, visibleLegacy: {'finance'}),
        ),
      ]);
      await container.read(settingsProvider.notifier).setDensity(true);
      await container
          .read(settingsProvider.notifier)
          .setModule('finance', false);
      container.dispose();
      await db.close();
      db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      final state = await container.read(sidebarControllerProvider.future);
      expect(state.width, 280);
      expect(state.workspaceOpen, false);
      expect(state.compact, true);
      expect(state.closedGroups, {'files', 'ai'});
      expect(state.visibleLegacy, {'finance'});
      final settings = await SettingsRepository(db).load();
      expect(settings.compact, true);
      expect(settings.moduleEnabled('finance'), false);
      expect(db.schemaVersion, 3);
    },
  );

  for (final (size, dpr) in [
    (const Size(1366, 768), 1.0),
    (const Size(1600, 900), 1.0),
    (const Size(1920, 1080), 1.0),
    (const Size(2560, 1440), 1.0),
    (const Size(1366, 768), 1.25),
    (const Size(1600, 900), 1.5),
    (const Size(800, 600), 1.0),
    (const Size(360, 640), 1.0),
  ]) {
    testWidgets('responsive sidebar real navigation $size DPR$dpr', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        routes: [
          ShellRoute(
            builder: (context, state, child) => WorkspaceShell(child: child),
            routes: [
              GoRoute(path: '/', builder: (_, _) => const Text('主页内容')),
              GoRoute(
                path: '/modules/:id',
                builder: (_, state) => Text('内容 ${state.pathParameters['id']}'),
              ),
              GoRoute(path: '/settings', builder: (_, _) => const Text('设置内容')),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: appTheme(Brightness.dark),
            routerConfig: router,
          ),
        ),
      );
      await withPersistenceFrames(
        tester,
        () => container.read(sidebarControllerProvider.future),
      );
      await tester.pumpAndSettle();
      final mobile = size.width / dpr < 720;
      if (mobile) {
        await tester.tap(find.byTooltip('科技工作空间'));
        await tester.pumpAndSettle();
      }
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('nav-bookmarks'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('toggle-科技工作空间'))).dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('toggle-科技工作空间')));
      await waitForPersisted(
        tester,
        () => container.read(navigationStateRepositoryProvider).load(),
        (s) => !s.workspaceOpen,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-archive')), findsNothing);
      if (mobile) {
        router.go('/');
        Navigator.of(
          tester.element(find.byKey(const ValueKey('nav-bookmarks'))),
        ).pop();
      }
      router.go('/modules/archive');
      await tester.pumpAndSettle();
      await waitForPersisted(
        tester,
        () => container.read(navigationStateRepositoryProvider).load(),
        (s) => s.workspaceOpen,
      );
      await tester.pumpAndSettle();
      expect(find.text('内容 archive'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
  test('corrupt layout is reported and finite widths clamped', () {
    expect(NavigationState.fromJson({'width': double.nan}).width, 232);
    expect(NavigationState.fromJson({'width': 100}).width, 196);
  });
}
