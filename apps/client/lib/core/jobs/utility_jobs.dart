import 'dart:async';

import '../data/record_store.dart';
import '../data/tool_record.dart';
import '../../features/archive/archive_service.dart';

enum UtilityJobStatus {
  queued,
  running,
  cancelRequested,
  succeeded,
  failed,
  cancelled,
  interrupted,
}

extension UtilityJobStatusInfo on UtilityJobStatus {
  bool get terminal => {
    UtilityJobStatus.succeeded,
    UtilityJobStatus.failed,
    UtilityJobStatus.cancelled,
    UtilityJobStatus.interrupted,
  }.contains(this);
  String get label => switch (this) {
    UtilityJobStatus.queued => '排队中',
    UtilityJobStatus.running => '处理中',
    UtilityJobStatus.cancelRequested => '正在取消',
    UtilityJobStatus.succeeded => '已完成',
    UtilityJobStatus.failed => '失败',
    UtilityJobStatus.cancelled => '已取消',
    UtilityJobStatus.interrupted => '已中断',
  };
}

UtilityJobStatus utilityJobStatus(ToolRecord record) =>
    UtilityJobStatus.values.byName(record.text('status'));

class JobQueueRepository {
  JobQueueRepository(this.store);
  final RecordStore store;
  Future<ToolRecord> require(String id) async {
    final row = await store.get(id);
    if (row?.kind != 'utility_job') throw const ToolFailure('工具任务已不存在。');
    return row!;
  }

  Future<ToolRecord> create(
    String module,
    String type,
    String title,
    Map<String, dynamic> input, {
    required String submissionId,
  }) => store.transaction(() async {
    final existing = await store.find(
      'utility_job',
      'submissionId',
      submissionId,
    );
    if (existing != null) return existing;
    if (title.trim().isEmpty || title.length > 300) {
      throw const ToolFailure('任务标题无效。');
    }
    return store.create(
      'utility_job',
      title,
      data: {
        'payloadVersion': 1,
        'moduleId': module,
        'type': type,
        'inputReferences': input,
        'outputReferences': <String>[],
        'status': UtilityJobStatus.queued.name,
        'submissionId': submissionId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'progress': null,
        'processedItems': 0,
        'totalItems': 0,
        'currentFile': '',
        'errorCode': '',
        'errorMessage': '',
        'cancelRequested': false,
        'syncAllowed': false,
        'isSensitive': true,
      },
    );
  });
  Future<ToolRecord> update(String id, Map<String, dynamic> values) =>
      store.transaction(() async {
        final row = await require(id);
        if (values['status'] case final String status) {
          final next = UtilityJobStatus.values.byName(status),
              old = utilityJobStatus(row);
          const transitions = {
            UtilityJobStatus.queued: {
              UtilityJobStatus.running,
              UtilityJobStatus.cancelled,
              UtilityJobStatus.cancelRequested,
              UtilityJobStatus.interrupted,
            },
            UtilityJobStatus.running: {
              UtilityJobStatus.succeeded,
              UtilityJobStatus.failed,
              UtilityJobStatus.cancelRequested,
              UtilityJobStatus.cancelled,
              UtilityJobStatus.interrupted,
            },
            UtilityJobStatus.cancelRequested: {
              UtilityJobStatus.cancelled,
              UtilityJobStatus.interrupted,
            },
          };
          if (old != next && !(transitions[old]?.contains(next) ?? false)) {
            throw const ToolFailure('工具任务状态转换无效。');
          }
        }
        return store.save(row.copyWith(data: {...row.data, ...values}));
      });
  Future<bool> start(String id) => store.transaction(() async {
    if (utilityJobStatus(await require(id)) != UtilityJobStatus.queued) {
      return false;
    }
    await update(id, {
      'status': UtilityJobStatus.running.name,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    });
    return true;
  });
  Future<bool> requestCancel(String id, {required bool active}) =>
      store.transaction(() async {
        final row = await require(id);
        if (utilityJobStatus(row).terminal) return false;
        await update(id, {
          'cancelRequested': true,
          'status': active
              ? UtilityJobStatus.cancelRequested.name
              : UtilityJobStatus.cancelled.name,
          if (!active) 'finishedAt': DateTime.now().toUtc().toIso8601String(),
        });
        return true;
      });
  Future<void> recover() async {
    for (final row in await store.list('utility_job', limit: 10000)) {
      if (!utilityJobStatus(row).terminal) {
        await update(row.id, {
          'status': UtilityJobStatus.interrupted.name,
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
          'errorCode': 'interrupted',
          'errorMessage': '应用上次关闭时处理未完成。已有输出保留，请检查后重新创建安全任务。',
        });
      }
    }
  }
}

class UtilityJobContext {
  UtilityJobContext(this.id, this.repository);
  final String id;
  final JobQueueRepository repository;
  final cancellation = TaskCancellation();
  final List<Future<void> Function()> _cancelHandlers = [];
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  void check() => cancellation.check();
  void onCancel(Future<void> Function() action) {
    if (cancellation.cancelled) {
      unawaited(action().catchError((Object _) {}));
    } else {
      _cancelHandlers.add(action);
    }
  }

  Future<void> cancel() async {
    cancellation.cancel();
    for (final callback in _cancelHandlers) {
      try {
        await callback();
      } catch (_) {
        /* Continue stopping other owned children. */
      }
    }
  }

  Future<void> progress(
    int processed,
    int total, {
    String currentFile = '',
    double? fraction,
    bool force = false,
  }) async {
    check();
    if (processed < 0 ||
        total < 0 ||
        (total > 0 && processed > total) ||
        (fraction != null &&
            (!fraction.isFinite || fraction < 0 || fraction > 1))) {
      throw const ToolFailure('任务进度无效。');
    }
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastProgress).inMilliseconds < 300 &&
        processed != total) {
      return;
    }
    _lastProgress = now;
    final row = await repository.require(id);
    if (utilityJobStatus(row) != UtilityJobStatus.running) {
      check();
      return;
    }
    await repository.update(id, {
      'processedItems': processed,
      'totalItems': total,
      'currentFile': currentFile,
      'progress': fraction ?? (total > 0 ? processed / total : null),
    });
  }

  Future<void> output(String reference) async {
    check();
    await repository.store.transaction(() async {
      final row = await repository.require(id);
      if (utilityJobStatus(row) != UtilityJobStatus.running) {
        throw const ToolFailure('任务已停止，拒绝迟到输出引用。');
      }
      await repository.update(id, {
        'outputReferences': {
          ...row.strings('outputReferences'),
          reference,
        }.toList(),
      });
    });
  }
}

typedef UtilityJobHandler = Future<String?> Function(
  UtilityJobContext context,
  Map<String, dynamic> input,
);

class UtilityJobDefinition {
  const UtilityJobDefinition(
    this.moduleId,
    this.type,
    this.handler, {
    this.requiresConfirmation = true,
  });
  final String moduleId, type;
  final UtilityJobHandler handler;
  final bool requiresConfirmation;
  String get key => '$moduleId/$type';
}

/// One persistent queue for expensive utility work. The scene and page only
/// observe SQLite. No fake pause or automatic replay of file side effects.
class UtilityJobEngine {
  UtilityJobEngine(this.repository);
  final JobQueueRepository repository;
  final Map<String, UtilityJobDefinition> _definitions = {};
  final List<String> _queue = [];
  final Map<String, UtilityJobContext> _active = {};
  final Set<String> _cancelRequests = {};
  final Map<String, UtilityJobHandler> _sessionHandlers = {};
  final Map<String, int> _retained = {};
  int _reservedBytes = 0, _submitting = 0;
  Future<void>? _ready, _draining;
  bool _disposed = false;
  Object? lastStorageError;
  void register(UtilityJobDefinition definition) {
    if (_definitions.containsKey(definition.key)) {
      throw const ToolFailure('工具任务执行器重复注册。');
    }
    _definitions[definition.key] = definition;
  }

  Future<void> initialize() => _ready ??= repository.recover();
  Future<ToolRecord> submit(
    String module,
    String type,
    String title,
    Map<String, dynamic> input, {
    required bool confirmed,
    String? submissionId,
    UtilityJobHandler? run,
    int retainedBytes = 0,
  }) async {
    await initialize();
    if (_disposed || lastStorageError != null) {
      throw const ToolFailure('任务队列已停止，请检查存储后重开应用。');
    }
    final definition = _definitions['$module/$type'];
    if (definition == null && run == null) {
      throw const ToolFailure('此工具任务没有实际执行器。');
    }
    if ((definition?.requiresConfirmation ?? true) && !confirmed) {
      throw const ToolFailure('请先预览并确认输入与输出范围。');
    }
    if (retainedBytes < 0 ||
        retainedBytes + _reservedBytes > 200 * 1024 * 1024) {
      throw const ToolFailure('后台输入总计最多200MB，请等待当前批次完成后再提交。');
    }
    if (_queue.length + _active.length + _submitting >= 20) {
      throw const ToolFailure('等待任务过多，请完成或取消后再添加。');
    }
    _reservedBytes += retainedBytes;
    _submitting++;
    var retained = false;
    try {
      final row = await repository.create(
        module,
        type,
        title,
        input,
        submissionId: submissionId ?? newId(),
      );
      if (utilityJobStatus(row) == UtilityJobStatus.queued &&
          !_queue.contains(row.id) &&
          !_active.containsKey(row.id)) {
        if (run != null) _sessionHandlers[row.id] = run;
        _retained[row.id] = retainedBytes;
        retained = true;
        _queue.add(row.id);
        _start();
      }
      return row;
    } finally {
      _submitting--;
      if (!retained) _reservedBytes -= retainedBytes;
    }
  }

  void _start() {
    if (_draining != null || _disposed) return;
    _draining = _drain()
        .catchError((Object error) {
          lastStorageError = error;
        })
        .whenComplete(() {
          _draining = null;
          if (_queue.isNotEmpty && !_disposed && lastStorageError == null) {
            _start();
          }
        });
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_disposed) {
      final id = _queue.removeAt(0), row = await repository.require(id);
      if (_disposed ||
          _cancelRequests.contains(id) ||
          utilityJobStatus(row) != UtilityJobStatus.queued) {
        _sessionHandlers.remove(id);
        _release(id);
        continue;
      }
      final context = UtilityJobContext(id, repository);
      _active[id] = context;
      try {
        if (!await repository.start(id)) throw const ToolFailure('任务开始前已取消。');
        context.check();
        final handler =
            _sessionHandlers[id] ??
            _definitions['${row.text('moduleId')}/${row.text('type')}']
                ?.handler;
        if (handler == null) throw const ToolFailure('执行器不可用，请重新选择输入。');
        final result = await handler(
          context,
          Map<String, dynamic>.from(row.data['inputReferences'] as Map),
        );
        context.check();
        final current = await repository.require(id);
        if (utilityJobStatus(current) == UtilityJobStatus.cancelRequested) {
          throw const ToolFailure('任务已取消。');
        }
        await repository.update(id, {
          'status': UtilityJobStatus.succeeded.name,
          'progress': 1.0,
          'resultReference': result ?? '',
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (error) {
        final current = await repository.require(id),
            cancelled =
                context.cancellation.cancelled ||
                (await repository.require(id)).flag('cancelRequested');
        if (!utilityJobStatus(current).terminal) {
          await repository.update(id, {
            'status': cancelled
                ? UtilityJobStatus.cancelled.name
                : UtilityJobStatus.failed.name,
            'errorCode': cancelled ? 'cancelled' : 'processing',
            'errorMessage': cancelled
                ? '用户取消；已完成输出保留。'
                : error is ToolFailure
                ? error.message
                : '处理失败，请检查输入、授权或可用空间。',
            'finishedAt': DateTime.now().toUtc().toIso8601String(),
          });
        }
      } finally {
        _active.remove(id);
        _sessionHandlers.remove(id);
        _release(id);
      }
    }
  }

  Future<void> cancel(String id) async {
    // Mark before the first await: dispatch may be reading SQLite but may not
    // yet have registered its active context. The drain must not start it.
    _cancelRequests.add(id);
    try {
      // Signal an atomic import before waiting for its held SQLite/write gate.
      final active = _active[id];
      await active?.cancel();
      final row = await repository.require(id);
      if (utilityJobStatus(row).terminal) return;
      final currentActive = _active[id];
      if (currentActive != null && currentActive != active) {
        await currentActive.cancel();
      }
      if (!await repository.requestCancel(id, active: currentActive != null)) {
        return;
      }
      _queue.remove(id);
      if (currentActive == null) {
        _sessionHandlers.remove(id);
        _release(id);
      }
    } finally {
      _cancelRequests.remove(id);
    }
  }

  Future<void> waitIdle() async {
    while (_draining != null) {
      await _draining;
    }
  }

  Future<ToolRecord> waitFor(String id) async {
    final current = await repository.require(id);
    if (utilityJobStatus(current).terminal) return current;
    final row = await repository.store
        .watchOne(id)
        .firstWhere((row) => row == null || utilityJobStatus(row).terminal);
    if (row == null) throw const ToolFailure('任务记录已被删除。');
    return row;
  }

  void _release(String id) => _reservedBytes -= _retained.remove(id) ?? 0;

  Future<void> dispose() async {
    _disposed = true;
    _sessionHandlers.removeWhere((id, _) => !_active.containsKey(id));
    for (final id
        in _retained.keys.where((id) => !_active.containsKey(id)).toList()) {
      _release(id);
    }
    for (final context in _active.values.toList()) {
      await context.cancel();
    }
    await waitIdle();
  }
}
