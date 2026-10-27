import '../web_library/web_search_service.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/data/tool_record.dart';
import '../ai_desk/ai_service.dart';
import '../archive/archive_service.dart';
import '../memory/memory_repository.dart';
import '../server/server_service.dart';
import 'office_domain.dart';
import 'office_presentation.dart';
import 'studio_repository.dart';
import 'utility_draft.dart';

enum ToolRisk {
  readOnly,
  localWrite,
  externalNetwork,
  remoteWrite,
  destructive,
}

class ToolDefinition {
  const ToolDefinition(
    this.id,
    this.name,
    this.risk, {
    this.referenceKind = '',
    this.cancellable = true,
  });
  final String id, name, referenceKind;
  final ToolRisk risk;
  final bool cancellable;
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'referenceKind': referenceKind,
    'additionalProperties': false,
  };
  Map<String, dynamic> get outputSchema => {'type': 'markdown'};
  Set<String> get platforms => {'windows', 'android', 'ios'};
}

class ToolRegistry {
  final Map<String, ToolDefinition> tools = {
    for (final e in localTools.entries)
      e.key: ToolDefinition(
        e.key,
        e.value,
        e.key == 'server.http'
            ? ToolRisk.externalNetwork
            : e.key == 'timeline.create'
            ? ToolRisk.localWrite
            : ToolRisk.readOnly,
        referenceKind: e.key.startsWith('archive.') || e.key == 'image.suggest'
            ? 'archive_root'
            : e.key == 'server.http'
            ? 'website'
            : e.key == 'memory.context'
            ? 'project'
            : e.key == 'memory.tags'
            ? 'note'
            : '',
        cancellable: e.key != 'server.http',
      ),
  };
  ToolDefinition require(String id, ToolRecord profile) {
    final tool = tools[id];
    if (tool == null || !profile.strings('allowedTools').contains(id)) {
      throw const ToolFailure('工具未注册或未授权。');
    }
    return tool;
  }
}

class ExecutionContext {
  ExecutionContext(this.task, this.profile);
  final ToolRecord task, profile;
  final cancellation = TaskCancellation();
  final networkCancel = CancelToken();
  Map<String, dynamic> get input =>
      Map<String, dynamic>.from(task.data['inputReferences'] as Map);
  void check() => cancellation.check();
  void cancel() {
    cancellation.cancel();
    if (!networkCancel.isCancelled) networkCancel.cancel('user/task stop');
  }
}

class ExecutionOutput {
  const ExecutionOutput(this.markdown, {this.metadata = const {}});
  final String markdown;
  final Map<String, dynamic> metadata;
}

abstract class AgentExecutor {
  Future<void> validateConfiguration(ExecutionContext context);
  Future<ExecutionOutput> startTask(ExecutionContext context);
  void cancelTask(ExecutionContext context) => context.cancel();
  bool get supportsPause => false;
}

class ExecutorRegistration {
  const ExecutorRegistration(this.id, this.name, this.executor, this.taskTypes);
  final String id, name;
  final AgentExecutor executor;
  final Set<String> taskTypes;
}

/// Runtime dispatch is explicit and closed: unregistered modes never fall back
/// to a local tool or fabricate a successful external execution.
class ExecutorRegistry {
  final Map<String, ExecutorRegistration> _entries = {};
  Iterable<ExecutorRegistration> get entries => _entries.values;
  void register(ExecutorRegistration entry) {
    if (_entries.containsKey(entry.id)) {
      throw const ToolFailure('执行器 ID 重复。');
    }
    _entries[entry.id] = entry;
  }

  AgentExecutor require(ToolRecord task) {
    final id = task.text(
      'executorId',
      task.text('executionMode') == 'realAgent' ? 'llm' : 'local',
    );
    final entry = _entries[id];
    if (entry == null || !entry.taskTypes.contains(task.text('type'))) {
      throw const ToolFailure('此任务没有已注册且兼容的执行器。');
    }
    return entry.executor;
  }

  factory ExecutorRegistry.standard(
    LocalToolExecutor local,
    LLMApiExecutor llm,
  ) => ExecutorRegistry()
    ..register(
      ExecutorRegistration('local', '本地工具', local, localTools.keys.toSet()),
    )
    ..register(
      ExecutorRegistration(
        'llm',
        'LLM API',
        llm,
        allTaskTypes.keys.where((t) => t.startsWith('ai.')).toSet(),
      ),
    );
  ExecutorRegistry();
}

class LocalToolExecutor extends AgentExecutor {
  LocalToolExecutor(this.repository, this.memory, this.registry);
  final StudioRepository repository;
  final MemoryRepository memory;
  final ToolRegistry registry;
  @override
  Future<void> validateConfiguration(ExecutionContext context) async {
    final tool = registry.require(context.task.text('type'), context.profile);
    if (tool.referenceKind.isNotEmpty) {
      await _reference(context, tool.referenceKind);
    }
    if (tool.risk == ToolRisk.externalNetwork &&
        context.input['networkConfirmed'] != true) {
      throw const ToolFailure('网站检查需要确认外发目标。');
    }
    if (tool.id == 'server.http') {
      final site = await _reference(context, 'website');
      if (context.input['approvedUrl'] != site.text('url')) {
        throw const ToolFailure('网站地址已改变，请重新确认外发目标。');
      }
    }
  }

  Future<ToolRecord> _reference(ExecutionContext context, String kind) async {
    final ref = context.input['referenceId'] as String? ?? '';
    final record = await repository.store.get(ref);
    if (record == null || record.kind != kind) {
      throw const ToolFailure('请选择仍然存在且已授权的资料。');
    }
    return record;
  }

  @override
  Future<ExecutionOutput> startTask(ExecutionContext c) async {
    c.check();
    final type = c.task.text('type');
    switch (type) {
      case 'timeline.create':
        final draft = StudioTimelineDraft.fromTask(c.task);
        if (draft.projectId.isNotEmpty &&
            (await repository.store.get(draft.projectId))?.kind != 'project') {
          throw const ToolFailure('关联项目已不存在。');
        }
        c.check();
        return ExecutionOutput(
          draft.markdown,
          metadata: {
            'timelineDraft': draft.json,
            'method': 'typed local proposal; explicit approval required',
            'writesBeforeApproval': false,
          },
        );
      case 'bookmarks.search':
        final query = (c.input['query'] as String? ?? '').trim();
        if (query.isEmpty || query.length > 300) {
          throw const ToolFailure('收藏搜索词不能为空，最多300字。');
        }
        final result = await WebLibrarySearchService(repository.store)
                .search(query, view: 'personal', limit: 100),
            found = result.items.map((s) => s.record).toList();
        c.check();
        return ExecutionOutput(
          '# 本地网页收藏搜索\n\n关键词：$query\n\n${found.length}条匹配${result.total > 100 ? '（还有更多结果，请缩小关键词）' : ''}，未联网获取网页。\n\n${found.map((r) => '- ${r.title}\n  ${(r.data['action'] as Map)['target']}\n  ${r.strings('tags').join(' / ')}\n  记录ID：${r.id}').join('\n\n')}',
          metadata: {
            'recordIds': found.map((r) => r.id).toList(),
            'method': 'read-only local personal website search',
            'scope': 'personal',
            'catalogInitialized': false,
            'networkUsed': false,
          },
        );
      case 'image.suggest':
        final root = await _reference(c, 'archive_root'),
            scan = await ArchiveScanner().scan(
              root.text('path'),
              c.cancellation,
            );
        c.check();
        if (scan.limited || scan.cancelled) {
          throw const ToolFailure('扫描未完成，未生成完整建议。');
        }
        final images = scan.files.where((f) => f.category == '图片').toList(),
            bytes = images.fold<int>(0, (v, f) => v + f.size);
        return ExecutionOutput(
          '# 图片批量处理建议\n\n授权目录：${root.title}\n\n实际扫描${scan.files.length}个文件，图片扩展名${images.length}个，当前大小$bytes bytes；读取警告${scan.errors.length}条。\n\n本地规则建议：\n- 静态PNG/JPEG/WebP可到图片工具箱预览、按需缩放或去除EXIF，再确认输出到新目录。\n- HEIC/GIF/SVG请先检查转换引擎和格式限制，不直接套用静态图片处理。\n- 保留原始文件，使用独立输出目录。\n\n这里只按扩展名和实际文件大小给出建议，没有解码验证、估算压缩比例或写入图片。',
          metadata: {
            'rootId': root.id,
            'imageCount': images.length,
            'bytes': bytes,
            'method': 'ArchiveScanner extension counts; local suggestions',
            'originalFilesModified': false,
          },
        );
      case 'memory.search':
        final query = (c.input['query'] as String? ?? '').trim();
        if (query.isEmpty) throw const ToolFailure('搜索词不能为空。');
        final notes = (await repository.store.search(
          query,
          kinds: ['note', 'memory_prompt'],
          limit: 30,
        )).where((n) => !n.flag('isSensitive')).toList();
        return ExecutionOutput(
          '# 知识库检索\n\n关键词：$query\n\n找到 ${notes.length} 条非敏感记录。\n\n${notes.map((n) => '## ${n.title}\n记录 ID：${n.id}\n\n${n.body.substring(0, n.body.length.clamp(0, 500))}').join('\n\n')}',
          metadata: {
            'recordIds': notes.map((n) => n.id).toList(),
            'method': 'Memory RecordStore.search',
          },
        );
      case 'memory.tags':
        final note = await _reference(c, 'note');
        final words = RegExp(r'[\u4e00-\u9fff]{2,6}|[a-zA-Z][a-zA-Z0-9_]{2,24}')
            .allMatches('${note.title}\n${note.body}')
            .map((m) => m[0]!)
            .toSet()
            .take(12);
        return ExecutionOutput(
          '# 标签建议\n\n笔记：${note.title}\n\n本地关键词规则提取，不是 AI 推理；未更改原标签。\n\n${words.map((w) => '- $w').join('\n')}',
        );
      case 'archive.scan':
      case 'archive.types':
      case 'archive.duplicates':
        final root = await _reference(c, 'archive_root');
        final result = await ArchiveScanner().scan(
          root.text('path'),
          c.cancellation,
        );
        c.check();
        if (result.limited || result.cancelled) {
          throw const ToolFailure('扫描达到上限或已取消，未生成完整报告。');
        }
        var report =
            '# ${localTools[type]}\n\n授权目录：${root.title}\n\n文件 ${result.files.length} 个，共 ${result.bytes} bytes。\n\n${result.categories.entries.map((e) => '- ${e.key}：${e.value}').join('\n')}\n\n读取警告：${result.errors.length}';
        if (type == 'archive.duplicates') {
          final groups = await DuplicateDetector().find(
            result.files,
            c.cancellation,
          );
          c.check();
          report +=
              '\n\n## SHA-256 内容相同的文件\n${groups.length} 组；未删除或移动文件。\n\n${groups.take(200).map((g) => g.map((f) => '- ${f.path}').join('\n')).join('\n\n')}';
        }
        return ExecutionOutput(
          report,
          metadata: {
            'rootId': root.id,
            'files': result.files.length,
            'errors': result.errors.length,
            'method': 'ArchiveScanner / DuplicateDetector',
          },
        );
      case 'memory.context':
        final project = await _reference(c, 'project');
        final selected = (c.input['noteIds'] as List? ?? []).cast<String>();
        if (selected.isEmpty) throw const ToolFailure('请明确选择要导出的笔记。');
        final preview = await memory.contextPreview(project, selected.toSet());
        return ExecutionOutput(
          '# 项目上下文预览\n\n只生成待审核 Markdown，未写入外部目录。\n\n${preview.entries.map((e) => '## ${e.key}\n\n${e.value}').join('\n\n---\n\n')}',
          metadata: {
            'projectId': project.id,
            'noteIds': selected,
            'files': preview,
          },
        );
      case 'server.http':
        final site = await _reference(c, 'website');
        final result = await WebsiteMonitor().check(site.text('url'));
        c.check();
        if (result.error != null) throw ToolFailure(result.error!);
        return ExecutionOutput(
          '# 网站检测\n\n地址：${site.text('url')}\n\nHTTP ${result.status}\n\n耗时 ${result.elapsed.inMilliseconds} ms\n\n证书到期：${result.certificateExpires ?? 'HTTP 无证书或服务未提供'}',
          metadata: result.toJson(),
        );
      case 'studio.history':
        final tasks = await repository.store.list('studio_task', limit: 1000);
        return ExecutionOutput(
          '# 本地任务历史\n\n${tasks.length} 条真实记录。\n\n${tasks.map((t) => '- ${t.title} · ${taskState(t).label} · ${t.updatedAt.toLocal()}').join('\n')}',
        );
      default:
        throw const ToolFailure('工具尚未实现。');
    }
  }
}

class LLMApiExecutor extends AgentExecutor {
  LLMApiExecutor(this.repository, this.ai, this.api);
  final StudioRepository repository;
  final AiRepository ai;
  final AiApi api;
  Future<ToolRecord> _provider(ExecutionContext c) async {
    final provider = await repository.store.get(c.task.text('providerId'));
    if (provider == null ||
        provider.kind != 'ai_provider' ||
        c.profile.text('executorType') != 'llm' ||
        c.profile.text('providerId') != provider.id) {
      throw const ToolFailure('Provider 未配置或已改变，请重新安排任务。');
    }
    if (c.task.text('modelId') != provider.text('model')) {
      throw const ToolFailure('模型配置已改变，请重新安排任务。');
    }
    return provider;
  }

  @override
  Future<void> validateConfiguration(ExecutionContext c) async {
    final provider = await _provider(c);
    AiConfig.fromRecord(provider).validate();
    await ai.key(provider);
    if (c.input['networkConfirmed'] != true) {
      throw const ToolFailure('AI 任务需要明确确认资料外发目标。');
    }
    if (c.input['approvedOrigin'] !=
        Uri.parse(provider.text('baseUrl')).origin) {
      throw const ToolFailure('外发服务地址已改变，请重新确认。');
    }
  }

  @override
  Future<ExecutionOutput> startTask(ExecutionContext c) async {
    final provider = await _provider(c),
        config = AiConfig.fromRecord(await _provider(c));
    var text = c.input['query'] as String? ?? '';
    if (c.task.text('type') == 'ai.summary') {
      final note = await repository.store.get(
        c.input['referenceId'] as String? ?? '',
      );
      if (note == null || note.kind != 'note') {
        throw const ToolFailure('请明确选择一篇笔记。');
      }
      text = '标题：${note.title}\n\n${note.body}';
    }
    if (text.trim().isEmpty || utf8.encode(text).length > 128 * 1024) {
      throw const ToolFailure('AI 输入不能为空，且最多128KB。');
    }
    final prompt = switch (c.task.text('type')) {
      'ai.summary' => '总结以下笔记，注明未确定的信息。',
      'ai.rewrite' => '改写以下文字，保留原意。',
      'ai.plan' => '根据以下明确要求生成项目实施计划。',
      'ai.todos' => '从以下文字整理任务列表，不虚构已执行的操作。',
      _ => '根据以下要求生成 Markdown 草稿。',
    };
    final output = StringBuffer();
    Map<String, dynamic>? usage;
    await for (final delta in api.stream(config, await ai.key(provider), [
      {
        'role': 'system',
        'content':
            '你只能生成待审核文字草稿；没有本机文件修改或命令执行能力。${c.profile.text('systemInstructions')}',
      },
      {'role': 'user', 'content': '$prompt\n\n$text'},
    ], c.networkCancel)) {
      c.check();
      output.write(delta.text);
      usage = delta.usage ?? usage;
    }
    c.check();
    if (output.isEmpty) throw const ToolFailure('模型没有返回文字产物。');
    return ExecutionOutput(
      output.toString(),
      metadata: {
        'providerId': provider.id,
        'model': config.model,
        'usage': usage,
        'usageSource': usage == null ? 'notProvided' : 'provider',
        'origin': Uri.parse(config.baseUrl).origin,
      },
    );
  }
}

class AgentRuntime {
  AgentRuntime(
    this.repository,
    this.memory,
    this.local,
    this.llm, {
    this.instantMovement = false,
    ExecutorRegistry? executors,
  }) : executors = executors ?? ExecutorRegistry.standard(local, llm);
  final StudioRepository repository;
  final MemoryRepository memory;
  final LocalToolExecutor local;
  final LLMApiExecutor llm;
  final bool instantMovement;
  final ExecutorRegistry executors;
  late MovementController movement;
  OfficePresentation presentation = const OfficePresentation();
  final Map<String, TaskState> activeStates = {};
  final Map<String, DateTime> stateChangedAt = {};
  final List<String> _queue = [];
  final Map<String, ExecutionContext> _contexts = {};
  Future<void>? _initialization;
  Future<void>? _draining;
  bool _disposed = false;
  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    await repository.initialize();
    await repository.recoverInterrupted();
    movement = MovementController(
      await repository.layout(),
      instant: instantMovement,
    );
    presentation = OfficePresentation.decode(
      await repository.store.setting('studio.presentation'),
    );
    for (final task in await repository.store.list(
      'studio_task',
      limit: 1000,
    )) {
      activeStates.putIfAbsent(
        task.text('assignedAgentId'),
        () => taskState(task),
      );
      stateChangedAt.putIfAbsent(
        task.text('assignedAgentId'),
        () => task.updatedAt,
      );
    }
    final saved = await repository.store.setting('studio.links.position');
    if (saved != null) {
      final cell = Cell.fromJson(jsonDecode(saved) as Map);
      if (movement.layout.grid.canWalk(cell) &&
          (!movement.layout.seats.contains(cell) ||
              movement.layout.desk('links')?.seat == cell)) {
        movement.actors['links'] = ActorMotion(cell);
      }
    }
  }

  Future<void> moveUser(Cell target) async {
    await initialize();
    await movement.move('links', target);
    await repository.store.setSetting(
      'studio.links.position',
      jsonEncode(target.toJson()),
    );
  }

  Future<void> savePresentation(OfficePresentation value) async {
    await repository.store.setSetting('studio.presentation', value.encode());
    presentation = value;
  }

  Future<ToolRecord> submit({
    required String title,
    required String type,
    required String agentId,
    required Map<String, dynamic> input,
    String? submissionId,
    String parentTaskId = '',
  }) async {
    await initialize();
    final task = await repository.createTask(
      title: title,
      type: type,
      agentId: agentId,
      input: input,
      submissionId: submissionId ?? newId(),
      parentTaskId: parentTaskId,
    );
    if (taskState(task) == TaskState.queued &&
        !_queue.contains(task.id) &&
        !_contexts.containsKey(task.id)) {
      _queue.add(task.id);
      _startDrain();
    }
    return task;
  }

  void _startDrain() {
    if (_draining != null) return;
    _draining = _drain().whenComplete(() {
      _draining = null;
      if (_queue.isNotEmpty && !_disposed) _startDrain();
    });
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_disposed) {
      // Select from persisted priorities at dispatch time. Editing the UI alone
      // cannot reorder an already running task or bypass the serial write gate.
      final pending = <ToolRecord>[];
      final snapshot = List<String>.of(_queue);
      for (final id in snapshot) {
        final task = await repository.requireTask(id);
        if (_queue.contains(id) && taskState(task) == TaskState.queued) {
          pending.add(task);
        }
      }
      pending.sort((a, b) {
        final priority = b.number('priority').compareTo(a.number('priority'));
        return priority != 0 ? priority : a.createdAt.compareTo(b.createdAt);
      });
      if (pending.isEmpty) {
        _queue.removeWhere(snapshot.contains);
        continue;
      }
      // Remove only the selected id. New submissions during the database
      // awaits must remain queued, and a concurrently cancelled id stays out.
      final selected = pending.first.id;
      if (_queue.remove(selected)) await _run(selected);
    }
  }

  Future<void> _phase(String id, TaskState state, {String message = ''}) async {
    final task = await repository.transition(id, state, message: message);
    // Cancelling another queued task must not replace the same agent's
    // currently executing task animation with a false cancelled state.
    if (_contexts.entries.any(
      (e) =>
          e.key != id &&
          e.value.profile.text('agentId') == task.text('assignedAgentId'),
    )) {
      return;
    }
    activeStates[task.text('assignedAgentId')] = state;
    stateChangedAt[task.text('assignedAgentId')] = task.updatedAt;
  }

  Future<void> _run(String id) async {
    ExecutionContext? context;
    try {
      final task = await repository.requireTask(id);
      if (taskState(task) != TaskState.queued) return;
      final profile = await repository.agent(task.text('assignedAgentId'));
      context = ExecutionContext(task, profile);
      _contexts[id] = context;
      final executor = executors.require(task);
      await executor.validateConfiguration(context);
      context.check();
      await _phase(id, TaskState.walking);
      final desk = movement.layout.desk(profile.text('agentId'));
      if (desk == null) throw const ToolFailure('角色没有可用工位。');
      await movement.move(profile.text('agentId'), desk.seat);
      context.check();
      await _phase(
        id,
        TaskState.working,
        message: task.text('executionMode') == 'realAgent'
            ? '真实 API 请求开始。'
            : '本地工具开始实际执行。',
      );
      final output = await executor
          .startTask(context)
          .timeout(
            Duration(seconds: profile.number('timeout', 120)),
            onTimeout: () {
              context!.cancel();
              throw TimeoutException('任务达到超时上限，执行已停止。');
            },
          );
      context.check();
      await repository.artifact(id, output.markdown, metadata: output.metadata);
      context.check();
      await _phase(id, TaskState.waitingApproval);
    } catch (error) {
      final current = await repository.requireTask(id);
      if (!taskState(current).terminal) {
        final cancelled =
            context?.cancellation.cancelled == true &&
            error is! TimeoutException;
        await repository.transition(
          id,
          cancelled ? TaskState.cancelled : TaskState.failed,
          message: cancelled
              ? '任务已停止；没有自动覆盖任何原始资料。'
              : error is TimeoutException
              ? '任务达到超时上限，执行已停止。'
              : error is ToolFailure
              ? error.message
              : '执行失败，请检查授权、配置或磁盘空间。',
          errorCode: cancelled
              ? 'cancelled'
              : error is TimeoutException
              ? 'timeout'
              : error is AiFailure
              ? error.category
              : 'execution',
        );
        activeStates[current.text('assignedAgentId')] = cancelled
            ? TaskState.cancelled
            : TaskState.failed;
        stateChangedAt[current.text('assignedAgentId')] = DateTime.now();
      }
    } finally {
      context?.cancel();
      _contexts.remove(id);
    }
  }

  Future<void> cancel(String id) async {
    final task = await repository.requireTask(id);
    if (taskState(task).terminal) return;
    final context = _contexts[id];
    if (context != null) {
      context.cancel();
      if (movement.actors[task.text('assignedAgentId')]!.walking) {
        movement.stop(task.text('assignedAgentId'));
      }
    }
    if (!taskState(await repository.requireTask(id)).terminal) {
      await _phase(id, TaskState.cancelled, message: '用户取消任务。');
    }
    _queue.remove(id);
  }

  Future<void> approve(String id) async {
    final task = await repository.requireTask(id);
    if (task.text('type') == 'timeline.create') {
      final saved = await repository.approveTimeline(id);
      activeStates[saved.text('assignedAgentId')] = TaskState.completed;
      stateChangedAt[saved.text('assignedAgentId')] = saved.updatedAt;
      return;
    }
    await _phase(id, TaskState.completed, message: '用户审核通过实际产物。');
  }

  Future<ToolRecord> retry(String id) async {
    final task = await repository.requireTask(id);
    if (!{
      TaskState.failed,
      TaskState.cancelled,
      TaskState.waitingApproval,
    }.contains(taskState(task))) {
      throw const ToolFailure('当前任务不能重试。');
    }
    if (task.number('attempt') >= 1) {
      throw const ToolFailure('达到此任务的重试上限；可检查配置后手动新建。');
    }
    if (taskState(task) == TaskState.waitingApproval) await cancel(id);
    final next = await repository.createTask(
      title: '${task.title} · 重试',
      type: task.text('type'),
      agentId: task.text('assignedAgentId'),
      input: Map<String, dynamic>.from(task.data['inputReferences'] as Map),
      parentTaskId: task.id,
      submissionId: 'retry:${task.id}',
    );
    final saved = next.number('attempt') > 0
        ? next
        : await repository.store.save(
            next.copyWith(
              data: {...next.data, 'attempt': task.number('attempt') + 1},
            ),
          );
    if (taskState(saved) == TaskState.queued &&
        !_queue.contains(saved.id) &&
        !_contexts.containsKey(saved.id)) {
      _queue.add(saved.id);
      _startDrain();
    }
    return saved;
  }

  Future<void> waitIdle() async {
    while (_draining != null) {
      await _draining;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final context in _contexts.values) {
      context.cancel();
    }
    if (_initialization != null) {
      await _initialization;
      movement.dispose();
    }
    await waitIdle();
  }
}
