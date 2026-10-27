// Native Windows documentation captures using a fresh synthetic database.
// No live credentials, files, providers or user databases are loaded.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/security/credential_store.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/studio/studio_providers.dart';
import 'package:links_toolbox/features/studio/office_game.dart';

class _DemoCredentials implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Seven real native pages for public documentation, synthetic data only',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp(
        'kado-public-showcase-',
      );
      final db = AppDatabase.file(File('${temp.path}/demo.sqlite'));
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
          ownedFilesProvider.overrideWith((ref) async => OwnedFileStore(temp)),
          credentialsProvider.overrideWithValue(_DemoCredentials()),
        ],
      );
      final output = Directory(
        Platform.environment['KADO_SHOWCASE_OUTPUT'] ??
            '${Directory.current.path}/../../artifacts/public-showcase',
      );
      await output.create(recursive: true);
      final capture = GlobalKey();
      final manifest = <Map<String, Object>>[];
      Future<void> frames([int count = 16]) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 60));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> shot(String filename, String route, String caption) async {
        await frames();
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$filename.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        manifest.add({
          'file': '$filename.png',
          'route': route,
          'caption': caption,
          'width': image.width,
          'height': image.height,
        });
        image.dispose();
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'workspace': 'KADO Desk',
            'demo': true,
            'tools': ['format', 'hash', 'regex'],
          }),
        );
        await request.response.close();
      });
      try {
        final memory = container.read(memoryRepositoryProvider);
        final project = await memory.project('KADO Demo · 本地示例');
        await memory.createNote(
          '开始你的工作空间',
          body: '# Demo notes\n\n这些是公开截图的合成内容，没有用户笔记或账号。',
          projectId: project.id,
        );
        await memory.createNote(
          'Release checklist',
          body: 'Review changes, run tests, verify checksums.',
          projectId: project.id,
        );
        await container.read(agentRuntimeProvider).initialize();
        await tester.binding.setSurfaceSize(const Size(1600, 900));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: capture,
              child: const LinksToolboxApp(),
            ),
          ),
        );
        await shot(
          '01_dashboard',
          '/',
          'Real native workspace with synthetic notes/project; no fabricated active jobs.',
        );
        container.read(routerProvider).go('/modules/bookmarks');
        await shot(
          '02_web_library',
          '/modules/bookmarks',
          'Built-in public website catalog; no personal bookmarks.',
        );
        container.read(routerProvider).go('/modules/api_studio');
        await frames();
        await tester.enterText(
          find.widgetWithText(TextField, '请求URL'),
          'http://127.0.0.1:${server.port}/demo',
        );
        await tester.tap(find.widgetWithText(FilledButton, '发送'));
        for (
          var i = 0;
          i < 60 && find.textContaining('Status 200').evaluate().isEmpty;
          i++
        ) {
          await frames(2);
        }
        expect(requests, 1);
        expect(find.textContaining('Status 200'), findsOneWidget);
        await shot(
          '03_developer_tools',
          '/modules/api_studio',
          'Actual HTTP 200 from a synthetic loopback server; no external API credential.',
        );
        container.read(routerProvider).go('/modules/studio');
        await frames(50);
        expect(find.byType(GameWidget<OfficeGame>), findsWidgets);
        await shot(
          '04_pixel_office',
          '/modules/studio',
          'Real Flame office and local characters. No claim that multiple external AI agents are executing.',
        );
        container.read(routerProvider).go('/modules/ai_desk');
        await shot(
          '05_ai_desk',
          '/modules/ai_desk',
          'Real unconfigured AI Desk; no fabricated model response or provider account.',
        );
        container.read(routerProvider).go('/modules/archive');
        await shot(
          '06_file_manager',
          '/modules/archive',
          'Real preview-based file organizer, no folder selected and no private path.',
        );
        container.read(routerProvider).go('/settings');
        await shot(
          '07_settings',
          '/settings',
          'Real settings; secure storage probe and backup not invoked.',
        );
        await File('${output.path}/CAPTURE_MANIFEST.json').writeAsString(
          jsonEncode({
            'platform': 'Windows native Flutter integration / Debug',
            'version': '2.4.0+24',
            'syntheticDataOnly': true,
            'externalAiRequests': 0,
            'actualLoopbackRequests': requests,
            'editedUiPixels': false,
            'captures': manifest,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await frames(2);
        await server.close(force: true);
        await db.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
