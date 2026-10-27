import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  late AppDatabase database;
  late SettingsRepository repository;
  late ProviderContainer container;
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await database.initialize();
    repository = SettingsRepository(database);
    container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LinksToolboxApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(800, 1100),
    const Size(1440, 1000),
  ]) {
    testWidgets(
      'offline workspace and settings fit ${size.width} x ${size.height}',
      (tester) async {
        await mount(tester, size);
        expect(find.text('快捷启动'), findsOneWidget);
        expect(
          find.byType(NavigationBar),
          size.width < 720 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
        container.read(routerProvider).go('/settings');
        await tester.pumpAndSettle();
        expect(find.text('让工作台适合你'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'disabled deep link is guarded; another module remains accessible',
    (tester) async {
      await container
          .read(settingsProvider.notifier)
          .setModule('archive', false);
      await mount(tester, const Size(1200, 900));
      final router = container.read(routerProvider);
      router.go('/modules/archive');
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/modules');
      router.go('/modules/memory');
      await tester.pumpAndSettle();
      expect(find.text('新建笔记'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, '/modules/memory');
      await container
          .read(settingsProvider.notifier)
          .setModule('memory', false);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/modules');
    },
  );
  testWidgets('theme state updates the app after persistence', (tester) async {
    await mount(tester, const Size(1200, 900));
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    await container.read(settingsProvider.notifier).setTheme(ThemeMode.light);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    expect((await repository.load()).themeMode, ThemeMode.light);
  });
  testWidgets('unknown module routes fall back without crashing', (
    tester,
  ) async {
    await mount(tester, const Size(390, 844));
    container.read(routerProvider).go('/modules/unknown');
    await tester.pumpAndSettle();
    expect(find.text('模块管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
