import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('manual hotkey changes await startup registration and remain the persisted final choice', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    final started = Completer<void>(),
        release = Completer<void>(),
        calls = <int>[];
    const channel = MethodChannel('com.linkstam.links_toolbox/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'registerHotkey') {
            final key = (call.arguments as Map)['key'] as int;
            calls.add(key);
            if (calls.length == 1) {
              started.complete();
              await release.future;
            }
          }
          return null;
        });
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    try {
      final controller = container.read(hotkeyProvider.notifier),
          initial = controller.initialize(),
          change = controller.apply(135, 6, true);
      await started.future.timeout(const Duration(seconds: 3));
      expect(calls, [
        32,
      ]); // A later registration must wait, not race the default.
      release.complete();
      await Future.wait([initial, change]);
      expect(calls, [32, 135]);
      final saved = jsonDecode(
        (await container.read(recordStoreProvider).setting('hub.hotkey'))!,
      ) as Map;
      expect(saved['key'], 135);
      expect(saved['enabled'], true);
      await controller.initialize();
      expect(calls, [32, 135]);
    } finally {
      if (!release.isCompleted) release.complete();
      container.dispose();
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
