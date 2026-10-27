import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/sync/sync_repository.dart';

void main() {
  late AppDatabase db;
  late RecordStore store;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    store = RecordStore(db);
  });
  tearDown(() async {
    await db.close();
  });
  test('queue is versioned, idempotent and local; private data/keys never enter payload', () async {
    final note = await store.create(
      'note',
      '公开笔记',
      body: '正文',
      data: {
        'projectId': 'p',
        'credentialRef': 'must-not-transfer',
        'secret': 'must-not-transfer',
      },
    );
    final envelope = await LocalSyncRepository().prepare(
      note,
      explicitlyAuthorized: true,
    );
    expect(envelope.payload.toString(), isNot(contains('must-not-transfer')));
    final queue = LocalSyncQueue(store);
    await queue.enqueue(envelope);
    await queue.enqueue(envelope);
    expect((await queue.pending()).length, 1);
    expect((await queue.pending()).single.text('state'), 'pending');
    final private = await store.create(
      'note',
      'private',
      data: {'isSensitive': true},
    );
    await expectLater(
      LocalSyncRepository().prepare(private, explicitlyAuthorized: true),
      throwsA(isA<ToolFailure>()),
    );
    final provider = await store.create('ai_provider', 'key metadata');
    await expectLater(
      LocalSyncRepository().prepare(provider, explicitlyAuthorized: true),
      throwsA(isA<ToolFailure>()),
    );
  });
  test(
    'divergent device revisions preserve both versions instead of overwriting',
    () {
      final now = DateTime.now();
      final local = SyncEnvelope(
        entityId: 'stable',
        kind: 'note',
        revision: 2,
        deviceId: 'a',
        updatedAt: now,
        payload: {'body': 'local'},
      );
      final remote = SyncEnvelope(
        entityId: 'stable',
        kind: 'note',
        revision: 3,
        deviceId: 'b',
        updatedAt: now,
        payload: {'body': 'remote'},
      );
      expect(
        PreserveConflictResolver().compare(local, remote),
        ConflictChoice.preserveBoth,
      );
      expect(
        PreserveConflictResolver().compare(local, local),
        ConflictChoice.identical,
      );
    },
  );
}
