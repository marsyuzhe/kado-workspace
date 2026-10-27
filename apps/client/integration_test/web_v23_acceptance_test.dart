import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_providers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native V2.3 brand legacy UUID migration website edits categories and policy',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('kado-v23-native-'),
          db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
      await db.initialize();
      final store = RecordStore(db);
      final legacy = await store.create(
        'favorite',
        '旧版测试网址',
        data: {
          'action': const TargetAction(
            'url',
            'https://example.org/legacy-native',
          ).toJson(),
          'targetKey': const TargetAction(
            'url',
            'https://example.org/legacy-native',
          ).key,
          'pinned': true,
          'order': 9,
          'category': '旧版分类',
        },
      );
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
          ownedFilesProvider.overrideWith((ref) async => OwnedFileStore(temp)),
        ],
      );
      final artifact = Directory(
        Platform.environment['KADO_V23_ARTIFACT_ROOT'] ??
            '${Directory.current.path}/../../artifacts/v23-native',
      );
      await artifact.create(recursive: true);
      final boundary = GlobalKey();
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
      }

      Future<void> capture(String name) async {
        await settle();
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('${artifact.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      }

      try {
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: boundary,
              child: const LinksToolboxApp(),
            ),
          ),
        );
        await settle();
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
          'KADO Desk',
        );
        container.read(routerProvider).go('/modules/bookmarks');
        await container.read(webRepositoryProvider).initialize();
        await settle();
        final repo = container.read(webRepositoryProvider),
            migrated = (await repo.sites()).firstWhere(
              (s) => s.id == legacy.id,
            );
        expect(migrated.record.id, legacy.id);
        expect(migrated.sortOrder, 9);
        expect(migrated.isPinned, isTrue);
        expect((await repo.categories()).any((c) => c.name == '旧版分类'), isTrue);
        final root = await repo.saveCategory(
          const WebsiteCategoryInput('原生分类', iconKey: 'code'),
        );
        final child = await repo.saveCategory(
          WebsiteCategoryInput('原生子类', parentId: root.id),
        );
        var own = await repo.saveWebsite(
          WebsiteInput(
            '原生网站',
            'https://example.org/native-new',
            categoryId: child.id,
            tags: ['真实SQLite'],
          ),
        );
        own = await repo.saveWebsite(
          WebsiteInput(
            '修改后的网站',
            own.url,
            categoryId: child.id,
            isFavorite: true,
          ),
          existing: own,
        );
        await repo.reorderCategories(
          (await repo.categories())
              .where((c) => c.parentId.isEmpty)
              .map((c) => c.id)
              .toList()
              .reversed
              .toList(),
        );
        await capture('01-web-desktop');
        final search = find.widgetWithText(TextField, '搜索网站、网址、标签或分类');
        await tester.enterText(search, '修改后');
        await settle();
        expect(
          find.byWidgetPredicate((w) => w is Text && w.data == '修改后的网站'),
          findsOneWidget,
        );
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await capture('02-web-mobile-layout');
        await repo.removeCategory(child, moveTo: root.id, confirmed: true);
        expect(WebsiteBookmark((await store.get(own.id))!).categoryId, root.id);
        final bytes = await container.read(webTransferProvider).export('json');
        expect((jsonDecode(utf8.decode(bytes)) as Map)['schemaVersion'], 2);
        final policy = await const MethodChannel(
          'com.linkstam.links_toolbox/platform',
        ).invokeMethod<bool>('allowsDirectMetadata');
        expect(policy, isA<bool>());
        await File('${artifact.path}/web-native-result.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'legacyUuidPreserved': true,
            'twoLevelCategoryCrud': true,
            'websiteEditsPersisted': true,
            'reorderPersisted': true,
            'categoryDeleteMovesWebsite': true,
            'jsonExportVersion': 2,
            'nativeNetworkPolicyBoolean': policy,
            'networkRequested': false,
            'nativeBrowserOpen':
                'UNVERIFIED; UI launch path is checked separately',
            'iosDevice': 'UNVERIFIED',
            'mobileScreenshotScope':
                'Windows Flutter constrained layout, not Android device',
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
        await container.read(utilityJobsProvider).dispose();
        container.dispose();
        await db.close();
        await tester.binding.setSurfaceSize(null);
        await temp.delete(recursive: true);
      }
    },
  );
}
