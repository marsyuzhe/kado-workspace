import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/ui/app_theme.dart';
import 'package:links_toolbox/features/web_library/web_library_page.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_providers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native website button opens actual default browser and counts a successful visit',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
          arrived = Completer<String>();
      final path = '/kado-browser-${DateTime.now().microsecondsSinceEpoch}',
          url = 'http://127.0.0.1:${server.port}$path';
      final listener = server.listen((request) async {
        final expected = request.uri.path == path;
        if (expected && !arrived.isCompleted) {
          arrived.complete(
            request.headers.value(HttpHeaders.userAgentHeader) ?? '',
          );
        }
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; style-src 'unsafe-inline'",
        );
        request.response.write(
          expected
              ? '<!doctype html><title>KADO Local Browser QA</title><h1>KADO browser check completed</h1><p>This is a temporary local test page. You can close this tab.</p>'
              : '',
        );
        await request.response.close();
      });
      final temp = await Directory.systemTemp.createTemp('kado-browser-ui-'),
          db = AppDatabase.file(File('${temp.path}/test.sqlite'));
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
      );
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
      }

      try {
        final repo = container.read(webRepositoryProvider);
        await repo.initialize();
        final site = await repo.saveWebsite(WebsiteInput('本机浏览器验收', url));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const Scaffold(body: WebLibraryPage()),
            ),
          ),
        );
        await settle();
        await tester.enterText(
          find.widgetWithText(TextField, '搜索网站、网址、标签或分类'),
          '本机浏览器验收',
        );
        await settle();
        await tester.tap(find.widgetWithText(TextButton, '本机浏览器验收'));
        await settle();
        final agent = await arrived.future.timeout(const Duration(seconds: 15));
        expect(
          agent,
          isNotEmpty,
          reason: 'Must receive a real browser request, not a mocked launch result.',
        );
        for (var i = 0; i < 30; i++) {
          if ((await repo.store.get(site.id))!.number('visitCount') == 1) break;
          await settle();
        }
        expect((await repo.store.get(site.id))!.number('visitCount'), 1);
        final file = File(
          '${Directory.current.path}/../../artifacts/v23-native/browser-open.json',
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'systemBrowserOpen': true,
            'actualHttpRequestReceived': true,
            'visitCount': 1,
            'targetScope': 'temporary owned loopback HTTP page; no external site or personal data',
            'testTabUrl': url,
            'browserUserAgent': agent,
          }),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
        container.dispose();
        await db.close();
        await temp.delete(recursive: true);
        await listener.cancel();
        await server.close(force: true);
      }
    },
  );
}
