import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/app/app.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/navigation_controller.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_providers.dart';

/// Build an actual DROPFILES HGLOBAL and send it only to our own active view,
/// obtained from the app's native adapter. This tests the native message path;
/// it is not a claim of physical Explorer pointer-drag automation.
void sendOwnedDrop(int window, String path) {
  final kernel = DynamicLibrary.open('kernel32.dll'),
      user = DynamicLibrary.open('user32.dll');
  final alloc = kernel
      .lookupFunction<
        Pointer<Void> Function(Uint32, UintPtr),
        Pointer<Void> Function(int, int)
      >('GlobalAlloc');
  final lock = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GlobalLock');
  final unlock = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('GlobalUnlock');
  final send = user
      .lookupFunction<
        IntPtr Function(IntPtr, Uint32, UintPtr, IntPtr),
        int Function(int, int, int, int)
      >('SendMessageW');
  final units = [...path.codeUnits, 0, 0],
      handle = alloc(0x42, 20 + units.length * 2);
  if (handle == nullptr) throw StateError('Owned DROPFILES allocation failed');
  final pointer = lock(handle);
  pointer.cast<Uint32>().asTypedList(5)
    ..[0] = 20
    ..[4] = 1;
  (pointer.cast<Uint8>() + 20)
      .cast<Uint16>()
      .asTypedList(units.length)
      .setAll(0, units);
  unlock(handle);
  send(window, 0x0233, handle.address, 0); // Native DragFinish owns it.
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'V24 actual Windows sidebar website API and native file-drop hashing',
    (tester) async {
      final temp = await Directory.systemTemp.createTemp('kado-v24-native-'),
          db = AppDatabase.file(File('${temp.path}/db.sqlite'));
      await db.initialize();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
          ownedFilesProvider.overrideWith((ref) async => OwnedFileStore(temp)),
        ],
      );
      await container
          .read(settingsProvider.notifier)
          .setModule('bookmarks', false);
      final capture = GlobalKey(),
          out = Directory(
            Platform.environment['KADO_V24_ARTIFACT_ROOT'] ??
                '${Directory.current.path}/../../artifacts/v24-native',
          );
      await out.create(recursive: true);
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> until(bool Function() predicate) async {
        for (var i = 0; i < 50 && !predicate(); i++) {
          await settle();
        }
        expect(predicate(), true);
      }

      Future<void> shot(String name) async {
        await settle();
        final render =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1),
            bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${out.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      server.listen((r) async {
        received++;
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"native":true,"value":"你好"}');
        await r.response.close();
      });
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: capture,
              child: const LinksToolboxApp(),
            ),
          ),
        );
        await settle();
        await container.read(sidebarControllerProvider.future);
        await shot('01-workspace');
        await tester.tap(find.byKey(const ValueKey('toggle-科技工作空间')));
        await settle();
        expect(
          (await container.read(navigationStateRepositoryProvider).load())
              .workspaceOpen,
          false,
        );
        container.read(routerProvider).go('/modules/archive');
        await settle();
        expect(
          (await container.read(navigationStateRepositoryProvider).load())
              .workspaceOpen,
          true,
        );
        final web = container.read(webRepositoryProvider);
        await web.initialize();
        final category = await web.saveCategory(
              const WebsiteCategoryInput('V24真实分类'),
            ),
            site = await web.saveWebsite(
              WebsiteInput(
                '本机验收网站',
                'https://example.org/v24',
                categoryId: category.id,
              ),
            );
        await web.updateWebsites([site], favorite: true, pinned: true);
        container.read(routerProvider).go('/modules/bookmarks');
        await settle();
        await shot('02-web-library');
        expect((await web.store.get(site.id))!.flag('favorite'), true);
        container.read(routerProvider).go('/modules/api_studio');
        await settle();
        await tester.enterText(
          find.widgetWithText(TextField, '请求URL'),
          'http://127.0.0.1:${server.port}/native',
        );
        await tester.tap(find.widgetWithText(FilledButton, '发送'));
        await until(
          () => find.textContaining('Status 200').evaluate().isNotEmpty,
        );
        expect(received, 1);
        await tester.ensureVisible(find.textContaining('Status 200'));
        await shot('03-api-response');
        container.read(routerProvider).go('/modules/hash_inspector');
        await settle();
        final file = File('${temp.path}/native-drop.txt');
        await file.writeAsString('abc');
        final target = await container
            .read(nativePlatformProvider)
            .fileDropTargetHandle();
        expect(target, greaterThan(0));
        sendOwnedDrop(target, file.path);
        await until(
          () => find
              .textContaining('ba7816bf8f01cfea414140de5dae2223')
              .evaluate()
              .isNotEmpty,
        );
        await shot('04-native-file-drop');
        container.read(routerProvider).go('/modules/memory');
        await settle();
        await expectLater(
          container.read(nativePlatformProvider).fileDropTargetHandle(),
          throwsException,
        );
        await File('${out.path}/acceptance.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'temporaryDataOnly': true,
            'nativeSidebarPersistence': true,
            'routeAutoReveal': true,
            'websiteCategoryAndFavorite': true,
            'actualLoopbackUiRequests': received,
            'actualNativeDropMessage': true,
            'hash': 'SHA256(abc) independent known vector',
            'dropDisabledAfterExit': true,
            'physicalExplorerDrag': 'UNVERIFIED',
            'buildMode': 'native integration / debug',
          }),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
        await server.close(force: true);
        container.dispose();
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
