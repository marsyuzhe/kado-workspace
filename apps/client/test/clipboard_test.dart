import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/platform/system_actions.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/clipboard/clipboard_service.dart';

class FakeClipboard extends NativePlatformAdapter {
  final events = StreamController<void>.broadcast();
  Map<String, dynamic>? snapshot;
  bool active = false;
  String? copied;
  @override
  bool get windows => true;
  @override
  Stream<void> get clipboardChanges => events.stream;
  @override
  Future<void> startClipboard() async {
    active = true;
  }

  @override
  Future<void> stopClipboard() async {
    active = false;
  }

  @override
  Future<Map<String, dynamic>?> clipboardSnapshot() async => snapshot;
  @override
  Future<void> copyText(String value) async {
    copied = value;
    snapshot = {'type': 'text', 'text': value};
    if (active) events.add(null);
  }

  Future<void> emit(String text) async {
    snapshot = {'type': 'text', 'text': text};
    if (active) events.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void dispose() {
    events.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late RecordStore store;
  late ClipboardRepository repo;
  late ClipboardService service;
  late FakeClipboard native;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('links-clipboard-');
    db = AppDatabase(NativeDatabase(File('${root.path}/db.sqlite')));
    await db.initialize();
    store = RecordStore(db);
    repo = ClipboardRepository(store, () async => OwnedFileStore(root));
    native = FakeClipboard();
    service = ClipboardService(repo, native);
    await service.initialize();
  });
  tearDown(() async {
    await service.dispose();
    native.dispose();
    await db.close();
    await root.delete(recursive: true);
  });
  test(
    'three contents persist, search, deduplicate and own copy does not loop',
    () async {
      await service.configure(const ClipConfig(enabled: true));
      for (final text in ['第一段测试文字', 'https://example.com', 'print("hello")']) {
        await native.emit(text);
        await service.drain();
      }
      expect((await repo.history()).length, 3);
      expect((await store.search('第一段')).length, 1);
      final item = (await repo.history()).last;
      await repo.pin(item, true);
      final rows = await repo.history();
      await service.copy(rows.first);
      await Future<void>.delayed(Duration.zero);
      await service.drain();
      expect((await repo.history()).length, 3);
      await service.capture({'type': 'text', 'text': '第一段测试文字'});
      expect((await repo.history()).length, 3);
      await db.close();
      db = AppDatabase(NativeDatabase(File('${root.path}/db.sqlite')));
      store = RecordStore(db);
      repo = ClipboardRepository(store, () async => OwnedFileStore(root));
      expect((await repo.history()).length, 3);
    },
  );
  test('pause/disable and private mode prevent automatic capture', () async {
    await service.configure(const ClipConfig(enabled: true));
    await native.emit('记录1');
    await service.drain();
    await service.configure(service.config.copyWith(paused: true));
    await native.emit('不记录2');
    await service.drain();
    expect((await repo.history()).length, 1);
    await service.configure(
      service.config.copyWith(paused: false, privateMode: true),
    );
    await native.emit('不记录3');
    await service.drain();
    expect((await repo.history()).length, 1);
    final private = await service.capture({'type': 'text', 'text': '主动私密文本'});
    expect(private!.flag('isSensitive'), isTrue);
    await expectLater(
      repo.setSyncAllowed(private, true),
      throwsA(isA<ToolFailure>()),
    );
    await service.configure(service.config.copyWith(enabled: false));
    expect(native.active, isFalse);
  });
  test('limits retain pinned history and reject malformed content', () async {
    await service.configure(const ClipConfig(maxItems: 2));
    final first = (await service.capture({'type': 'text', 'text': '保留的收藏'}))!;
    await repo.pin(first, true);
    await service.capture({'type': 'text', 'text': '被替换的旧条目'});
    await service.capture({'type': 'text', 'text': '新的条目'});
    expect((await repo.history()).length, 2);
    expect((await store.search('保留')).length, 1);
    expect(await store.search('被替换'), isEmpty);
    await expectLater(
      service.capture({
        'type': 'text',
        'text': 'a' * (ClipConfig.maxTextBytes + 1),
      }),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      service.capture({'type': 'image', 'bytes': base64Decode('aGVsbG8=')}),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      service.capture({'type': 'text', 'text': 5}),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('image bytes are owned files, referenced by metadata, deduplicated and deleted', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNomLDgPwAF9AKw7aBF7QAAAABJRU5ErkJggg==',
    );
    final image = (await service.capture({'type': 'image', 'bytes': png}))!;
    final file = OwnedFileStore(root).resolve(image.text('attachment'));
    expect(await file.exists(), isTrue);
    expect(image.body, isEmpty);
    await service.capture({'type': 'image', 'bytes': png});
    expect((await repo.history()).length, 1);
    final current = (await repo.history()).single;
    await repo.remove(current);
    expect(await file.exists(), isFalse);
    expect(
      () => OwnedFileStore(root).resolve('../private.txt'),
      throwsA(isA<ToolFailure>()),
    );
  });
  test(
    'concurrent same-content submissions have only one stable record',
    () async {
      final records = await Future.wait(
        List.generate(
          5,
          (_) => service.capture({'type': 'text', 'text': '相同文本'}),
        ),
      );
      expect(records.map((r) => r!.id).toSet().length, 1);
      expect((await repo.history()).length, 1);
    },
  );
}
