import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../memory/memory_repository.dart';
import 'office_domain.dart';
import '../utilities/timeline_service.dart';
import 'utility_draft.dart';

class StudioRepository {
  StudioRepository(this.store);
  final RecordStore store;
  Future<void>? _initializing;
  Future<void> initialize() => _initializing ??= store.transaction(() async {
    for (var i = 0; i < agentNames.length; i++) {
      final id = agentNames[i];
      if (await store.find('studio_agent', 'agentId', id) == null) {
        await store.create(
          'studio_agent',
          id == 'links' ? 'Links' : '${id[0].toUpperCase()}${id.substring(1)}',
          data: {
            'payloadVersion': 1,
            'agentId': id,
            'role': agentRoles[i],
            'spriteId': id,
            'providerId': '',
            'modelId': '',
            'executorType': id == 'links' ? 'user' : 'local',
            'allowedTools': localTools.keys
                .where((id) => id != 'timeline.create')
                .toList(),
            'workspace': '',
            'systemInstructions': '',
            'enabled': true,
            'timeout': 120,
            'maxSteps': 8,
            'retryLimit': 1,
            'connectionStatus': 'local',
          },
        );
      }
    }
    if ((await store.list('studio_layout')).isEmpty) {
      final layout = OfficeLayout.defaults()..validate();
      await store.create('studio_layout', 'Links 夜间工作室', data: layout.toJson());
    }
  });
  Future<OfficeLayout> layout() async {
    await initialize();
    return OfficeLayout.fromJson(
      (await store.list('studio_layout')).first.data,
    );
  }

  Future<void> saveLayout(OfficeLayout layout) async {
    layout.validate();
    final record = (await store.list('studio_layout')).first;
    await store.save(
      record.copyWith(data: {...record.data, ...layout.toJson()}),
    );
  }

  Future<void> saveAgent(ToolRecord agent, Map<String, dynamic> fields) async {
    if (agent.kind != 'studio_agent') throw const ToolFailure('角色记录无效。');
    final displayName = (fields['displayName'] as String? ?? agent.title)
        .trim();
    final data = {...agent.data, ...fields}..remove('displayName');
    if (displayName.isEmpty ||
        displayName.length > 40 ||
        '${data['role']}'.length > 80 ||
        '${data['roleDescription'] ?? ''}'.length > 4000 ||
        '${data['systemInstructions'] ?? ''}'.length > 16000 ||
        data['agentId'] != agent.text('agentId')) {
      throw const ToolFailure('角色名称、岗位或说明过长，或尝试修改固定角色ID。');
    }
    if (!{'user', 'local', 'llm'}.contains(data['executorType'])) {
      throw const ToolFailure('执行器尚不支持。');
    }
    final allowed = (data['allowedTools'] as List).cast<String>();
    if (allowed.any((t) => !localTools.containsKey(t))) {
      throw const ToolFailure('角色包含未知工具权限。');
    }
    if (data.keys.any(
      (k) => {'apiKey', 'key', 'secret', 'password'}.contains(k),
    )) {
      throw const ToolFailure('角色配置不得包含密钥。');
    }
    await store.save(agent.copyWith(title: displayName, data: data));
  }

  Future<ToolRecord> agent(String id) async {
    final record = await store.find('studio_agent', 'agentId', id);
    if (record == null || !record.flag('enabled') || id == 'links') {
      throw const ToolFailure('请选择已启用的员工；Links 是用户角色。');
    }
    return record;
  }

  Future<ToolRecord> createTask({
    required String title,
    required String type,
    required String agentId,
    required Map<String, dynamic> input,
    required String submissionId,
    String parentTaskId = '',
  }) => store.transaction(() async {
    if (title.trim().isEmpty ||
        title.length > 180 ||
        !allTaskTypes.containsKey(type)) {
      throw const ToolFailure('任务标题或类型无效。');
    }
    final existing = await store.find(
      'studio_task',
      'submissionId',
      submissionId,
    );
    if (existing != null) return existing;
    final profile = await agent(agentId);
    if (type.startsWith('ai.') &&
        (profile.text('executorType') != 'llm' ||
            profile.text('providerId').isEmpty)) {
      throw const ToolFailure('该角色未配置真实 LLM 执行器。请先设置模型。');
    }
    if (!type.startsWith('ai.') &&
        !profile.strings('allowedTools').contains(type)) {
      throw const ToolFailure('角色没有此工具的权限。');
    }
    final task = await store.create(
      'studio_task',
      title,
      body: '',
      data: {
        'payloadVersion': 1,
        'type': type,
        'executorId': type.startsWith('ai.') ? 'llm' : 'local',
        'description': input['query'] as String? ?? '',
        'assignedAgentId': agentId,
        'projectId': input['projectId'] ?? '',
        'status': TaskState.queued.name,
        'executionMode': type.startsWith('ai.')
            ? 'realAgent'
            : 'interactiveLocal',
        'providerId': profile.text('providerId'),
        'modelId': profile.text('modelId'),
        'inputReferences': input,
        'outputReferences': <String>[],
        'submissionId': submissionId,
        'progress': 0,
        'eventSequence': 0,
        'requiresApproval': true,
        'approvalPolicy': 'reviewOutput',
        'maxAttempts': 2,
        'parentTaskId': parentTaskId,
        'errorCode': '',
        'errorMessage': '',
        'priority': 0,
      },
    );
    return _writeEvent(task, 'created', '任务已入队；尚未执行。', {});
  });
  Future<ToolRecord> _writeEvent(
    ToolRecord task,
    String type,
    String message,
    Map<String, dynamic> extra,
  ) async {
    final sequence = task.number('eventSequence') + 1;
    final saved = await store.save(
      task.copyWith(data: {...task.data, 'eventSequence': sequence}),
    );
    await store.create(
      'studio_event',
      message,
      data: {
        'payloadVersion': 1,
        'taskId': task.id,
        'sequence': sequence,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'eventType': type,
        'payload': extra,
        'source': 'runtime',
        'origin': 'runtime',
        'isDemo': false,
        'isSimulated': false,
      },
    );
    return saved;
  }

  Future<ToolRecord> transition(
    String id,
    TaskState next, {
    String message = '',
    String errorCode = '',
  }) => store.transaction(() async {
    final task = await requireTask(id), old = taskState(task);
    if (old == next) return task;
    if (!(taskTransitions[old]?.contains(next) ?? false)) {
      throw ToolFailure('不允许 ${old.label} → ${next.label}。');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final saved = await store.save(
      task.copyWith(
        data: {
          ...task.data,
          'status': next.name,
          if (next == TaskState.working) 'startedAt': now,
          if (next.terminal) 'completedAt': now,
          if (next.terminal) 'finishedAt': now,
          'progress':
              next == TaskState.waitingApproval || next == TaskState.completed
              ? 1
              : 0,
          'errorCode': errorCode,
          'errorMessage': next == TaskState.failed ? message : '',
        },
      ),
    );
    return _writeEvent(
      saved,
      next.name,
      message.isEmpty ? next.label : message,
      {},
    );
  });
  Future<ToolRecord> approveTimeline(String id) => store.transaction(() async {
    final task = await requireTask(id);
    if (task.text('type') != 'timeline.create') {
      throw const ToolFailure('任务类型无效。');
    }
    if (taskState(task) == TaskState.completed) return task;
    if (taskState(task) != TaskState.waitingApproval) {
      throw const ToolFailure('此待办草稿没有处于待审核状态。');
    }
    final profile = await agent(task.text('assignedAgentId'));
    if (!profile.strings('allowedTools').contains('timeline.create')) {
      throw const ToolFailure('创建个人待办的权限已撤销。');
    }
    final draft = StudioTimelineDraft.fromTask(task),
        outputs = await artifacts(id);
    if (outputs.length != 1 ||
        jsonEncode(
              (outputs.single.data['metadata'] as Map?)?['timelineDraft'],
            ) !=
            jsonEncode(draft.json)) {
      throw const ToolFailure('待办草稿与原始输入不一致，请取消并重新生成。');
    }
    var todo = await store.find('personal_todo', 'originStudioTaskId', id);
    if (todo == null) {
      todo = await PersonalTimeline(store).save(
        draft.title,
        description: draft.description,
        due: draft.due,
        timeZone: draft.zone,
        projectId: draft.projectId,
        tags: draft.tags,
        studioTaskId: id,
      );
      todo = await store.save(
        todo.copyWith(data: {...todo.data, 'originStudioTaskId': id}),
      );
    }
    final latest = await requireTask(id);
    await store.save(
      latest.copyWith(data: {...latest.data, 'personalTodoId': todo.id}),
    );
    return transition(
      id,
      TaskState.completed,
      message: '用户确认后已创建一条个人待办；未执行关联任务。',
    );
  });

  Future<ToolRecord> requireTask(String id) async {
    final task = await store.get(id);
    if (task == null || task.kind != 'studio_task') {
      throw const ToolFailure('任务已不存在。');
    }
    return task;
  }

  Future<void> setPriority(String id, int priority) => store.transaction(
    () async {
      if (priority < 0 || priority > 3) throw const ToolFailure('优先级必须在0–3之间。');
      final task = await requireTask(id);
      if (taskState(task) != TaskState.queued) {
        throw const ToolFailure('仅排队任务可调整执行优先级。');
      }
      final saved = await store.save(
        task.copyWith(data: {...task.data, 'priority': priority}),
      );
      await _writeEvent(saved, 'priority', '用户调整优先级为 P$priority。', {
        'priority': priority,
      });
    },
  );

  Future<void> event(
    String id,
    String type,
    String message,
    Map<String, dynamic> payload,
  ) => store.transaction(() async {
    await _writeEvent(await requireTask(id), type, message, payload);
  });
  Future<ToolRecord> artifact(
    String taskId,
    String markdown, {
    Map<String, dynamic> metadata = const {},
  }) => store.transaction(() async {
    final task = await requireTask(taskId);
    if (taskState(task) != TaskState.working) {
      throw const ToolFailure('任务已停止，拒绝迟到产物。');
    }
    if (utf8.encode(markdown).length > MemoryRepository.maxNoteBytes) {
      throw const ToolFailure('任务产物超过1MB。');
    }
    final artifact = await store.create(
      'studio_artifact',
      '${task.title} · 草稿',
      body: markdown,
      data: {
        'payloadVersion': 1,
        'taskId': taskId,
        'type': 'markdown',
        'checksum': sha256.convert(utf8.encode(markdown)).toString(),
        'metadata': metadata,
        'localPath': '',
        'isSensitive': true,
        'syncAllowed': false,
      },
    );
    await store.save(
      task.copyWith(
        data: {
          ...task.data,
          'outputReferences': [
            ...task.strings('outputReferences'),
            artifact.id,
          ],
        },
      ),
    );
    await _writeEvent(await requireTask(taskId), 'artifact', '实际产物已保存，等待审核。', {
      'artifactId': artifact.id,
    });
    return artifact;
  });
  Future<ToolRecord> saveToMemory(String taskId, MemoryRepository memory) =>
      store.transaction(() async {
        final task = await requireTask(taskId);
        if (taskState(task) != TaskState.completed) {
          throw const ToolFailure('请先审核通过产物。');
        }
        if (task.text('memoryNoteId').isNotEmpty) {
          final existing = await store.get(task.text('memoryNoteId'));
          if (existing != null) return existing;
        }
        final outputs = await artifacts(taskId);
        if (outputs.isEmpty) throw const ToolFailure('没有可保存产物。');
        final note = await memory.createNote(
          task.title,
          body: outputs.map((a) => a.body).join('\n\n---\n\n'),
          sensitive: true,
          source: 'Studio task ${task.id}',
        );
        await store.save(
          task.copyWith(data: {...task.data, 'memoryNoteId': note.id}),
        );
        await _writeEvent(
          await requireTask(taskId),
          'savedToMemory',
          '用户已将审核结果保存至 Memory。',
          {'noteId': note.id},
        );
        return note;
      });
  Future<List<ToolRecord>> events(String id) async =>
      (await store.list(
          'studio_event',
          limit: 10000,
        )).where((e) => e.text('taskId') == id).toList()
        ..sort((a, b) => a.number('sequence').compareTo(b.number('sequence')));
  Future<List<ToolRecord>> artifacts(String id) async => (await store.list(
    'studio_artifact',
    limit: 10000,
  )).where((e) => e.text('taskId') == id).toList();
  Future<String> exportHistory() async {
    final tasks = await store.list('studio_task', limit: 100);
    final ids = tasks.map((t) => t.id).toSet();
    final events = await store.list('studio_event', limit: 10000);
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final e in events.where((e) => ids.contains(e.text('taskId')))) {
      grouped.putIfAbsent(e.text('taskId'), () => []).add({
        'id': e.id,
        'message': e.title,
        'data': e.data,
      });
    }
    for (final group in grouped.values) {
      group.sort(
        (a, b) => ((a['data'] as Map)['sequence'] as num).compareTo(
          (b['data'] as Map)['sequence'] as num,
        ),
      );
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'scope': 'latest 100 tasks; artifact references only, export Markdown separately',
      'eventWindowLimit': 10000,
      'logsMayBeTruncated': events.length >= 10000,
      'tasks': [
        for (final t in tasks)
          {
            'id': t.id,
            'title': t.title,
            'createdAt': t.createdAt.toIso8601String(),
            'data': t.data,
            'events': grouped[t.id] ?? [],
          },
      ],
    });
    if (utf8.encode(json).length > 10 * 1024 * 1024) {
      throw const ToolFailure('历史导出超过10MB，请单独导出所需产物。');
    }
    return json;
  }

  Future<void> recoverInterrupted() async {
    for (final task in await store.list('studio_task', limit: 10000)) {
      if ({
        TaskState.queued,
        TaskState.walking,
        TaskState.working,
      }.contains(taskState(task))) {
        await transition(
          task.id,
          TaskState.failed,
          message: '上次应用关闭时任务未完成；请检查日志后手动重试。',
          errorCode: 'interrupted',
        );
      }
    }
  }
}

const localTools = {
  'memory.search': '搜索知识库笔记',
  'memory.tags': '笔记标签建议（本地规则）',
  'archive.scan': '授权目录扫描报告',
  'archive.duplicates': '检测重复文件',
  'memory.context': '项目 Markdown 上下文预览',
  'server.http': '已配置网站 HTTP 检查',
  'archive.types': '目录文件类型统计',
  'studio.history': '汇总本地任务历史',
  'image.suggest': '授权目录图片批量处理建议',
  'bookmarks.search': '搜索本地网页收藏',
  'timeline.create': '个人待办草稿（审核后创建）',
};
const allTaskTypes = {
  ...localTools,
  'ai.summary': 'AI 总结指定笔记',
  'ai.rewrite': 'AI 改写文字',
  'ai.draft': 'AI Markdown 草稿',
  'ai.plan': 'AI 项目计划',
  'ai.todos': 'AI 整理任务列表',
};
