import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/app/data_providers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows OS hotkey registration, conflict detection and search invocation',
    (tester) async {
      if (!Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('links-native-hub-');
      final db = AppDatabase.file(File('${dir.path}/test.sqlite'));
      await db.initialize();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              SettingsRepository(db),
            ),
          ],
          child: const LinksToolboxApp(),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LinksToolboxApp)),
      );
      await container.read(hotkeyProvider.notifier).initialize();
      final native = container.read(nativePlatformProvider);
      var events = 0;
      final subscription = native.hotkeys.listen((_) {
        events++;
      });
      final user32 = DynamicLibrary.open('user32.dll');
      Future<void> waitFor(bool Function() condition) async {
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (condition()) return;
        }
        fail('Native event did not arrive within the bounded wait');
      }

      final ownWindow = await native.currentWindowHandle();
      expect(ownWindow, isNot(0));

      final register = user32
          .lookupFunction<
            Int32 Function(IntPtr, Int32, Uint32, Uint32),
            int Function(int, int, int, int)
          >('RegisterHotKey');
      final unregister = user32
          .lookupFunction<
            Int32 Function(IntPtr, Int32),
            int Function(int, int)
          >('UnregisterHotKey');
      final kernel = DynamicLibrary.open('kernel32.dll');
      final heap = kernel
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'GetProcessHeap',
          )();
      final allocate = kernel
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
            Pointer<Void> Function(Pointer<Void>, int, int)
          >('HeapAlloc');
      final free = kernel
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
            int Function(Pointer<Void>, int, Pointer<Void>)
          >('HeapFree');
      final sendInput = user32
          .lookupFunction<
            Uint32 Function(Uint32, Pointer<Void>, Int32),
            int Function(int, Pointer<Void>, int)
          >('SendInput');
      var key = 135;
      bool registered = false;
      try {
        for (; key >= 124; key--) {
          try {
            await native.registerHotkey(6, key);
            registered = true;
            break;
          } catch (_) {}
        }
        expect(
          registered,
          isTrue,
          reason: 'At least one Ctrl+Shift+F13–F24 key must be available for native verification.',
        );
        expect(
          register(0, 30101, 6, key),
          0,
          reason: 'OS must reject a second owner of the registered shortcut.',
        );
        for (var attempt = 0; attempt < 3 && events == 0; attempt++) {
          debugPrint('Native keyboard injection attempt: ${attempt + 1}');
          final input = allocate(heap, 8, 6 * 40);
          expect(input.address, isNot(0));
          try {
            final bytes = ByteData.sublistView(
              input.cast<Uint8>().asTypedList(6 * 40),
            );
            final codes = [17, 16, key, key, 16, 17];
            for (var i = 0; i < 6; i++) {
              bytes.setUint32(i * 40, 1, Endian.little); // INPUT_KEYBOARD
              bytes.setUint16(i * 40 + 8, codes[i], Endian.little);
              bytes.setUint32(i * 40 + 12, i < 3 ? 0 : 2, Endian.little);
            }
            expect(
              sendInput(6, input, 40),
              6,
              reason: 'OS must accept all six keyboard INPUT records.',
            );
          } finally {
            free(heap, 0, input);
          }
          for (var i = 0; i < 100 && events == 0; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        final keyboardEvents = events;
        debugPrint('Native hotkey keyboard events: $keyboardEvents');
        if (events == 0) {
          final dispatch = user32
              .lookupFunction<
                Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
                int Function(int, int, int, int)
              >('PostMessageW');
          expect(
            dispatch(ownWindow, 0x0312, 0x4C54, (key << 16) | 6),
            isNot(0),
          );
        }
        await waitFor(() => find.text('应用内搜索').evaluate().isNotEmpty);
        debugPrint('Native hotkey window message events: $events');

        expect(find.text('应用内搜索'), findsOneWidget);
        await native.unregisterHotkey();
        registered = false;
        final released = register(0, 30101, 6, key);
        expect(
          released,
          isNot(0),
          reason: 'Shortcut must be free after unregister.',
        );
        if (released != 0) unregister(0, 30101);
        var closeCalls = 0;
        await native.setCloseGuard(() async {
          closeCalls++;
          return false;
        });
        final post = user32
            .lookupFunction<
              Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
              int Function(int, int, int, int)
            >('PostMessageW');
        expect(post(ownWindow, 0x0010, 0, 0), isNot(0));
        await waitFor(() => closeCalls == 1);
        expect(
          closeCalls,
          1,
          reason: 'Native window close must wait for the Dart save guard.',
        );
        expect(find.text('应用内搜索'), findsOneWidget);
        expect(
          keyboardEvents,
          greaterThan(0),
          reason: 'Native message path passed; injected keyboard did not generate WM_HOTKEY.',
        );
      } finally {
        await subscription.cancel();
        if (registered) await native.unregisterHotkey();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
