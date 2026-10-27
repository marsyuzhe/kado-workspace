enum SyncAvailability { notConfigured, ready }

enum DataPolicy {
  localOnly,
  syncableMetadata,
  sensitiveOptional,
  largeAttachment,
}

class SyncStatus {
  const SyncStatus({required this.availability, required this.message});
  final SyncAvailability availability;
  final String message;
}

abstract interface class SyncService {
  Future<SyncStatus> status();
  Future<void> synchronize();
}

/// No HTTP call, no cursor advancement, and no change to local dirty records.
class UnconfiguredSyncService implements SyncService {
  const UnconfiguredSyncService();
  @override
  Future<SyncStatus> status() async => const SyncStatus(
    availability: SyncAvailability.notConfigured,
    message: '未配置服务器 · 数据仅保存在本机',
  );
  @override
  Future<void> synchronize() async => throw StateError('尚未配置同步服务器');
}

class SyncScope {
  const SyncScope({
    required this.ownerId,
    required this.deviceId,
    required this.collection,
  });
  final String ownerId;
  final String deviceId;
  final String collection;
}
