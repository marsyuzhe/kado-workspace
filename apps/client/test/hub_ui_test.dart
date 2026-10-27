import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
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
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
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

  testWidgets('module star really creates persisted favorite', (tester) async {
    await mount(tester);
    final star = find.byTooltip('收藏 AI 控制台');
    await tester.ensureVisible(star);
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(
      (await container.read(hubRepositoryProvider).favorites()).single.title,
      'AI 控制台',
    );
  });
  testWidgets('search debounce, Enter and Esc operate actual router', (
    tester,
  ) async {
    await mount(tester);
    container.read(routerProvider).go('/search');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '剪贴板');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '剪贴板'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/modules/clipboard',
    );
    container.read(routerProvider).go('/search');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/',
    );
  });
}
