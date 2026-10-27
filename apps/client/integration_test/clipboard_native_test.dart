import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/features/clipboard/clipboard_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows clipboard events, image, pause and persistence', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('links-native-clip-');
    var db = AppDatabase.file(File('${root.path}/test.sqlite'));
    await db.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        ],
        child: const LinksToolboxApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LinksToolboxApp)),
    );
    final controller = container.read(clipboardProvider.notifier);
    final native = container.read(nativePlatformProvider);
    final repo = container.read(clipboardRepositoryProvider);
    final errors = <String>[];
    final subscription = container.listen(clipboardProvider, (_, next) {
      if (next.error != null) errors.add(next.error!);
    });
    Future<void> settleEvent() async {
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await controller.service.drain();
    }

    try {
      await controller.configure(const ClipConfig(enabled: true));
      for (final text in [
        'LT原生样本文本甲',
        'https://example.com/lt-native',
        'print("LT native")',
      ]) {
        await native.copyText(text);
        await settleEvent();
      }
      expect((await repo.history()).length, 3);
      expect((await repo.store.search('样本文本')).length, 1);
      final pinned = await repo.pin((await repo.history()).last, true);
      await controller.service.copy(pinned);
      await settleEvent();
      expect((await repo.history()).length, 3);
      await controller.configure(
        controller.service.config.copyWith(paused: true),
      );
      await native.copyText('LT暂停期间样本');
      await settleEvent();
      expect((await repo.history()).length, 3);
      await controller.configure(
        controller.service.config.copyWith(paused: false),
      );
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNomLDgPwAF9AKw7aBF7QAAAABJRU5ErkJggg==',
      );
      await native.copyImage(png);
      await settleEvent();
      final image = (await repo.history()).firstWhere(
        (r) => r.text('contentType') == 'image',
      );
      final file = (await container.read(ownedFilesProvider.future))
          .resolve(image.text('attachment'));
      expect(await file.readAsBytes(), png);
      await controller.service.copy(image);
      await settleEvent();
      expect((await repo.history()).length, 4);
      await controller.configure(
        controller.service.config.copyWith(enabled: false),
      );
      expect(errors, isEmpty);
      subscription.close();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await db.close();
      db = AppDatabase.file(File('${root.path}/test.sqlite'));
      await db.initialize();
      final rows = await db.select(db.localRecords).get();
      expect(
        rows.where((r) => r.kind == 'clipboard' && r.deletedAt == null).length,
        4,
      );
    } finally {
      subscription.close();
      await native.stopClipboard();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
