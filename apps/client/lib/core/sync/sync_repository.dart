import '../data/record_store.dart';
import '../data/tool_record.dart';

class SyncEnvelope {
  const SyncEnvelope({
    required this.entityId,
    required this.kind,
    required this.revision,
    required this.deviceId,
    required this.updatedAt,
    required this.payload,
    this.deletedAt,
  });
  final String entityId, kind, deviceId;
  final int revision;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final Map<String, dynamic> payload;
  Map<String, dynamic> toJson() => {
    'formatVersion': 1,
    'entityId': entityId,
    'kind': kind,
    'revision': revision,
    'deviceId': deviceId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'payload': payload,
  };
}

abstract interface class SyncRepository {
  Future<SyncEnvelope> prepare(
    ToolRecord record, {
    required bool explicitlyAuthorized,
  });
}

class LocalSyncRepository implements SyncRepository {
  @override
  Future<SyncEnvelope> prepare(
    ToolRecord record, {
    required bool explicitlyAuthorized,
  }) async {
    if (!explicitlyAuthorized || record.flag('isSensitive')) {
      throw const ToolFailure('需要明确授权，私密记录不加入同步队列。');
    }
    if (!{
      'favorite',
      'note',
      'project',
      'prompt',
      'memory_prompt',
      'clipboard',
    }.contains(record.kind)) {
      throw const ToolFailure('此类数据当前不允许排队同步。');
    }
    if (record.kind == 'clipboard' &&
        (!record.flag('syncAllowed') ||
            record.text('contentType') == 'image')) {
      throw const ToolFailure('剪贴板文本必须单独授权；附件当前只保存在本机。');
    }
    final fields = switch (record.kind) {
      'favorite' => ['action', 'category', 'pinned', 'order', 'targetKey'],
      'project' => ['stack', 'progress'],
      _ => ['projectId', 'tags', 'category', 'pinned', 'contentType'],
    };
    return SyncEnvelope(
      entityId: record.id,
      kind: record.kind,
      revision: record.revision,
      deviceId: record.deviceId,
      updatedAt: record.updatedAt,
      deletedAt: record.deletedAt,
      payload: {
        'title': record.title,
        'body': record.body,
        'data': {
          for (final field in fields)
            if (record.data.containsKey(field)) field: record.data[field],
        },
      },
    );
  }
}

abstract interface class SyncQueue {
  Future<void> enqueue(SyncEnvelope envelope);
  Future<List<ToolRecord>> pending();
}

class LocalSyncQueue implements SyncQueue {
  LocalSyncQueue(this.store);
  final RecordStore store;
  @override
  Future<void> enqueue(SyncEnvelope envelope) => store.transaction(() async {
    final key = '${envelope.entityId}:${envelope.revision}';
    if (await store.find('sync_queue', 'key', key) != null) return;
    await store.create(
      'sync_queue',
      '待连接服务器',
      data: {'key': key, 'state': 'pending', 'envelope': envelope.toJson()},
    );
  });
  @override
  Future<List<ToolRecord>> pending() => store.list('sync_queue', limit: 10000);
}

enum ConflictChoice { identical, localOnly, remoteOnly, preserveBoth }

abstract interface class ConflictResolver {
  ConflictChoice compare(SyncEnvelope local, SyncEnvelope remote);
}

class PreserveConflictResolver implements ConflictResolver {
  @override
  ConflictChoice compare(SyncEnvelope local, SyncEnvelope remote) {
    if (local.entityId != remote.entityId || local.kind != remote.kind) {
      throw const ToolFailure('不能合并不同实体。');
    }
    if (local.revision == remote.revision &&
        local.deviceId == remote.deviceId &&
        local.updatedAt == remote.updatedAt &&
        local.payload.toString() == remote.payload.toString()) {
      return ConflictChoice.identical;
    }
    // A larger version from another device does not prove ancestry. Preserve both.
    if (local.deviceId != remote.deviceId) return ConflictChoice.preserveBoth;
    return local.revision > remote.revision
        ? ConflictChoice.localOnly
        : local.revision < remote.revision
        ? ConflictChoice.remoteOnly
        : ConflictChoice.preserveBoth;
  }
}
