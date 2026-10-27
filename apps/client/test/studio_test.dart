import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/ai_desk/ai_service.dart';
import 'package:links_toolbox/features/memory/memory_repository.dart';
import 'package:links_toolbox/features/studio/agent_runtime.dart';
import 'package:links_toolbox/features/studio/office_domain.dart';
import 'package:links_toolbox/features/studio/office_presentation.dart';
import 'package:links_toolbox/features/studio/studio_repository.dart';

import 'ai_test.dart' show TestCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite intentionally tests an actual loopback server, not the widget
  // binding's default HTTP 400 stub. No external network is used.
  HttpOverrides.global = null;
  late AppDatabase db;
  late Directory temp;
  late StudioRepository repo;
  late MemoryRepository memory;
  late AiRepository ai;
  late AiApi api;
  late AgentRuntime runtime;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-studio-test-');
    db = AppDatabase(NativeDatabase.memory());
    await db.initialize();
    final store = RecordStore(db);
    repo = StudioRepository(store);
    memory = MemoryRepository(store, () async => OwnedFileStore(temp));
    ai = AiRepository(store, TestCredentials());
    api = AiApi();
    runtime = AgentRuntime(
      repo,
      memory,
      LocalToolExecutor(repo, memory, ToolRegistry()),
      LLMApiExecutor(repo, ai, api),
      instantMovement: true,
    );
    await runtime.initialize();
  });
  tearDown(() async {
    await runtime.dispose();
    api.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });
  test('utility tools use real files and bookmarks; todo needs explicit permission and atomic approval', () async {
    expect(
      (await repo.agent('nova')).strings('allowedTools'),
      isNot(contains('timeline.create')),
    );
    await expectLater(
      runtime.submit(
        title: 'Denied',
        type: 'timeline.create',
        agentId: 'nova',
        input: {},
      ),
      throwsA(isA<ToolFailure>()),
    );
    final profile = await repo.agent('nova');
    await repo.saveAgent(profile, {
      'allowedTools': [...profile.strings('allowedTools'), 'timeline.create'],
    });
    final project = await repo.store.create(
      'project',
      'Local approval project',
    );
    final todoTask = await runtime.submit(
      title: 'Approval QA',
      type: 'timeline.create',
      agentId: 'nova',
      input: {
        'query': 'Only a personal plan',
        'todoDue': '2026-10-26 09:00',
        'timeZone': 'Asia/Shanghai',
        'projectId': project.id,
        'tags': ['QA'],
      },
    );
    await runtime.waitIdle();
    expect(
      taskState(await repo.requireTask(todoTask.id)),
      TaskState.waitingApproval,
    );
    expect(await repo.store.list('personal_todo'), isEmpty);
    expect(
      (await repo.artifacts(todoTask.id)).single.body,
      contains('通过并创建个人待办'),
    );
    await Future.wait([
      runtime.approve(todoTask.id),
      runtime.approve(todoTask.id),
    ]);
    final todo = (await repo.store.list('personal_todo')).single;
    expect(todo.title, 'Approval QA');
    expect(todo.text('studioTaskId'), todoTask.id);
    expect(todo.text('projectId'), project.id);
    expect(todo.text('executionMode'), 'personal');
    expect(todo.text('dueAt'), '2026-10-26T01:00:00.000Z');
    expect(
      (await repo.requireTask(todoTask.id)).text('personalTodoId'),
      todo.id,
    );
    final cancel = await runtime.submit(
      title: 'Cancelled draft',
      type: 'timeline.create',
      agentId: 'nova',
      input: {},
    );
    await runtime.waitIdle();
    await runtime.cancel(cancel.id);
    await expectLater(runtime.approve(cancel.id), throwsA(isA<ToolFailure>()));
    expect((await repo.store.list('personal_todo')).length, 1);
    final revoked = await runtime.submit(
      title: 'Revoked draft',
      type: 'timeline.create',
      agentId: 'nova',
      input: {},
    );
    await runtime.waitIdle();
    final latest = await repo.agent('nova');
    await repo.saveAgent(latest, {
      'allowedTools': latest
          .strings('allowedTools')
          .where((t) => t != 'timeline.create')
          .toList(),
    });
    await expectLater(runtime.approve(revoked.id), throwsA(isA<ToolFailure>()));
    expect((await repo.store.list('personal_todo')).length, 1);
    await repo.store.create(
      'favorite',
      'Named bookmark',
      data: {
        'action': {'type': 'url', 'target': 'https://example.com/qa'},
        'tags': ['needle-tag'],
      },
    );
    await repo.store.create(
      'favorite',
      'App should not match',
      data: {
        'action': {'type': 'application', 'target': 'needle-tag.exe'},
      },
    );
    final search = await runtime.submit(
      title: 'Bookmark QA',
      type: 'bookmarks.search',
      agentId: 'nova',
      input: {'query': 'needle-tag'},
    );
    await runtime.waitIdle();
    final report = (await repo.artifacts(search.id)).single;
    expect(report.body, contains('Named bookmark'));
    expect(report.body, isNot(contains('App should not match')));
    expect(report.body, contains('https://example.com/qa'));
    final image = await File('${temp.path}/own.png')
        .writeAsString('extension-only, not a decoded image');
    await File('${temp.path}/note.txt').writeAsString('QA');
    final root = await repo.store.create(
      'archive_root',
      'Own fixture directory',
      data: {'path': temp.path},
    );
    final suggested = await runtime.submit(
      title: 'Image advice QA',
      type: 'image.suggest',
      agentId: 'nova',
      input: {'referenceId': root.id},
    );
    await runtime.waitIdle();
    final advice = (await repo.artifacts(suggested.id)).single;
    expect((advice.data['metadata'] as Map)['imageCount'], 1);
    expect(advice.body, contains('没有解码验证'));
    expect(await image.readAsString(), 'extension-only, not a decoded image');
    final bad = await runtime.submit(
      title: 'No authorized root',
      type: 'image.suggest',
      agentId: 'nova',
      input: {},
    );
    await runtime.waitIdle();
    expect(taskState(await repo.requireTask(bad.id)), TaskState.failed);
    expect(await repo.artifacts(bad.id), isEmpty);
  });
  test('original scene assets retain six distinct actors and expand all original actions to 17x8 frames', () async {
    final data = jsonDecode(
      await rootBundle.loadString('assets/pixel_studio/atlases/manifest.json'),
    ) as List;
    expect(data.length, 13);
    final digests = <String>{};
    for (final name in agentNames) {
      final png = await rootBundle.load(
        'assets/pixel_studio/characters/$name.png',
      );
      digests.add(base64Encode(png.buffer.asUint8List()));
      final codec = await ui.instantiateImageCodec(png.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 256);
      expect(frame.image.height, actorAnimationTags.length * 48);
      frame.image.dispose();
      codec.dispose();
      final atlas = jsonDecode(
        await rootBundle.loadString('assets/pixel_studio/atlases/$name.json'),
      ) as Map;
      expect((atlas['frames'] as Map).length, actorAnimationTags.length * 8);
      expect(
        (atlas['animationTags'] as List),
        containsAll([
          'idle',
          'walk_up',
          'walk_down',
          'walk_left',
          'walk_right',
          'sit',
          'typing',
          'reading',
          'thinking',
          'talking',
          'waiting',
          'success',
          'error',
        ]),
      );
      expect(atlas['animationTags'], actorAnimationTags);
    }
    expect(digests.length, 6);
  });
  test('A star reaches all six desks without crossing blocked tiles', () {
    final layout = OfficeLayout.defaults()..validate();
    for (final id in agentNames) {
      final route = layout.grid.path(
        OfficeLayout.entrance,
        layout.desk(id)!.seat,
      )!;
      for (var i = 0; i < route.length; i++) {
        expect(layout.grid.canWalk(route[i]), isTrue);
        if (i > 0) expect(route[i].distance(route[i - 1]), 1);
      }
    }
    expect(layout.grid.path(OfficeLayout.entrance, const Cell(2, 3)), isNull);
    expect(layout.grid.path(OfficeLayout.entrance, const Cell(0, 0)), isNull);
  });
  test('layout rejects obstructed entrance, furniture overlap and duplicate desk assignment', () {
    final defaults = OfficeLayout.defaults();
    expect(
      () => OfficeLayout([
        ...defaults.furniture,
        const Furniture('bad', 'plant', OfficeLayout.entrance),
      ]).validate(),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => OfficeLayout([
        ...defaults.furniture,
        const Furniture('bad', 'plant', Cell(2, 3)),
      ]).validate(),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => OfficeLayout([
        for (final f in defaults.furniture)
          f.id == 'desk-1'
              ? Furniture(f.id, f.type, f.cell, agentId: 'nova')
              : f,
      ]).validate(),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('movement follows a real route, changes facing and ends exactly on the grid', () async {
    final movement = MovementController(OfficeLayout.defaults());
    final future = movement.move('links', const Cell(4, 8));
    var frames = 0;
    while (movement.actors['links']!.walking && frames++ < 2000) {
      movement.update(.016);
      expect(
        movement.layout.grid.canWalk(movement.actors['links']!.cell),
        isTrue,
      );
    }
    await future;
    expect(movement.actors['links']!.cell, const Cell(4, 8));
    expect(frames, greaterThan(20));
    await expectLater(
      movement.move('links', const Cell(2, 3)),
      throwsA(isA<ToolFailure>()),
    );
    movement.dispose();
  });
  test(
    'initialization is idempotent, layout and profiles remain in Schema3',
    () async {
      await StudioRepository(repo.store).initialize();
      expect((await repo.store.list('studio_agent')).length, 6);
      expect((await repo.store.list('studio_layout')).length, 1);
      expect(db.schemaVersion, 3);
      final layout = await repo.layout();
      await repo.saveLayout(layout);
      expect(
        (await StudioRepository(repo.store).layout()).toJson(),
        layout.toJson(),
      );
    },
  );
  test(
    'duplicate submission creates one task and one monotonic event stream',
    () async {
      final first = await repo.createTask(
        title: '历史',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
        submissionId: 'same',
      );
      final second = await repo.createTask(
        title: '重复点击',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
        submissionId: 'same',
      );
      expect(first.id, second.id);
      expect((await repo.events(first.id)).map((e) => e.number('sequence')), [
        1,
      ]);
      await expectLater(
        repo.transition(first.id, TaskState.completed),
        throwsA(isA<ToolFailure>()),
      );
      await repo.transition(first.id, TaskState.cancelled);
      await repo.transition(first.id, TaskState.cancelled);
      expect((await repo.events(first.id)).map((e) => e.number('sequence')), [
        1,
        2,
      ]);
    },
  );
  test('executor registry refuses mismatches and queued priorities persist as events', () async {
    final task = await repo.createTask(
      title: '队列测试',
      type: 'studio.history',
      agentId: 'patch',
      input: {},
      submissionId: 'registry',
    );
    expect(runtime.executors.require(task), isA<LocalToolExecutor>());
    expect(
      () => runtime.executors.require(
        task.copyWith(data: {...task.data, 'executorId': 'codex'}),
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => runtime.executors.require(
        task.copyWith(data: {...task.data, 'executorId': 'llm'}),
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => runtime.executors.register(runtime.executors.entries.first),
      throwsA(isA<ToolFailure>()),
    );
    await repo.setPriority(task.id, 3);
    await repo.saveAgent(await repo.agent('patch'), {
      'displayName': '质量审查员',
      'roleDescription': '按授权范围检查',
    });
    expect((await repo.requireTask(task.id)).text('assignedAgentId'), 'patch');
    expect((await repo.agent('patch')).title, '质量审查员');
    expect((await repo.requireTask(task.id)).number('priority'), 3);
    expect((await repo.events(task.id)).last.text('eventType'), 'priority');
    await expectLater(
      repo.setPriority(task.id, 4),
      throwsA(isA<ToolFailure>()),
    );
    await repo.transition(task.id, TaskState.walking);
    await expectLater(
      repo.setPriority(task.id, 1),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('submit and cancel during priority selection preserve all remaining queued work', () async {
    await runtime.dispose();
    final paused = _PausedSelectionRepository(repo.store);
    runtime = AgentRuntime(
      paused,
      memory,
      LocalToolExecutor(paused, memory, ToolRegistry()),
      LLMApiExecutor(paused, ai, api),
      instantMovement: true,
    );
    await runtime.initialize();
    paused.pauseNextRead = true;
    final first = await runtime.submit(
      title: '并发取消项',
      type: 'studio.history',
      agentId: 'nova',
      input: {},
    );
    try {
      await paused.readStarted.future.timeout(const Duration(seconds: 2));
      final second = await runtime.submit(
        title: '并发新增项',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
      );
      await runtime.cancel(first.id);
      paused.release.complete();
      await runtime.waitIdle().timeout(const Duration(seconds: 3));
      expect(taskState(await repo.requireTask(first.id)), TaskState.cancelled);
      expect(await repo.artifacts(first.id), isEmpty);
      expect(
        taskState(await repo.requireTask(second.id)),
        TaskState.waitingApproval,
      );
      expect((await repo.artifacts(second.id)).single.body, contains('并发新增项'));
    } finally {
      if (!paused.release.isCompleted) paused.release.complete();
    }
  });
  test('real Memory search requires approval and saves a single protected result note', () async {
    await memory.createNote('像素工作计划', body: '办公室审批链验证关键字');
    await memory.createNote('隐私', body: '办公室审批链私密', sensitive: true);
    final task = await runtime.submit(
      title: '检索',
      type: 'memory.search',
      agentId: 'nova',
      input: {'query': '办公室审批链'},
    );
    await runtime.waitIdle();
    expect(
      taskState(await repo.requireTask(task.id)),
      TaskState.waitingApproval,
    );
    final artifact = (await repo.artifacts(task.id)).single;
    expect(artifact.body, contains('像素工作计划'));
    expect(artifact.body, isNot(contains('办公室审批链私密')));
    await expectLater(
      repo.saveToMemory(task.id, memory),
      throwsA(isA<ToolFailure>()),
    );
    await runtime.approve(task.id);
    final note = await repo.saveToMemory(task.id, memory),
        same = await repo.saveToMemory(task.id, memory);
    expect(note.id, same.id);
    expect(note.flag('isSensitive'), isTrue);
    final events = await repo.events(task.id);
    expect(events.every((e) => !e.flag('isSimulated')), isTrue);
    expect(
      events.map((e) => e.number('sequence')),
      List.generate(events.length, (i) => i + 1),
    );
  });
  test('unconfigured LLM and user avatar cannot pretend to run AI', () async {
    await expectLater(
      runtime.submit(
        title: 'AI',
        type: 'ai.summary',
        agentId: 'ink',
        input: {},
      ),
      throwsA(isA<ToolFailure>()),
    );
    await expectLater(
      runtime.submit(
        title: '用户',
        type: 'studio.history',
        agentId: 'links',
        input: {},
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(await repo.store.list('studio_artifact'), isEmpty);
  });
  test('tool permissions and arbitrary ungranted paths are denied', () async {
    final profile = await repo.agent('patch');
    await repo.saveAgent(profile, {
      'allowedTools': ['studio.history'],
    });
    await expectLater(
      runtime.submit(
        title: '未授权',
        type: 'archive.scan',
        agentId: 'patch',
        input: {'path': temp.path},
      ),
      throwsA(isA<ToolFailure>()),
    );
    final task = await runtime.submit(
      title: '未选择目录',
      type: 'archive.scan',
      agentId: 'nova',
      input: {'path': temp.path},
    );
    await runtime.waitIdle();
    expect(taskState(await repo.requireTask(task.id)), TaskState.failed);
    expect(await repo.artifacts(task.id), isEmpty);
  });
  test(
    'restart marks interrupted work failed and preserves waiting approval',
    () async {
      final a = await repo.createTask(
        title: '中断',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
        submissionId: 'interrupted',
      );
      await repo.transition(a.id, TaskState.walking);
      await repo.transition(a.id, TaskState.working);
      final b = await runtime.submit(
        title: '已完成执行',
        type: 'studio.history',
        agentId: 'nova',
        input: {},
      );
      await runtime.waitIdle();
      await StudioRepository(repo.store).recoverInterrupted();
      expect((await repo.requireTask(a.id)).text('errorCode'), 'interrupted');
      expect(taskState(await repo.requireTask(a.id)), TaskState.failed);
      expect(
        taskState(await repo.requireTask(b.id)),
        TaskState.waitingApproval,
      );
    },
  );
  test('retry is bounded, idempotent and links parent without repeating approval side effects', () async {
    final task = await runtime.submit(
      title: '失败目录',
      type: 'archive.scan',
      agentId: 'patch',
      input: {},
    );
    await runtime.waitIdle();
    final retry = await runtime.retry(task.id);
    await runtime.waitIdle();
    final duplicate = await runtime.retry(task.id);
    await runtime.waitIdle();
    expect(retry.id, duplicate.id);
    expect((await repo.requireTask(retry.id)).text('parentTaskId'), task.id);
    await expectLater(runtime.retry(retry.id), throwsA(isA<ToolFailure>()));
  });
  test('real local HTTP SSE task persists actual output and usage; no external credential claim', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    final handlers = <Future<void>>[];
    server.listen((request) {
      handlers.add(() async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], 'fixture-only');
        expect((body['messages'] as List).last['content'], contains('仅供协议验收'));
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '真实本机 SSE 草稿'},
              },
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15},
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
        requestSeen.complete();
      }());
    });
    try {
      final provider = await ai.configure(
        AiConfig(
          name: '协议夹具',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'fixture-only',
        ),
        key: 'fixture-not-a-real-key',
      );
      await repo.saveAgent(await repo.agent('ink'), {
        'executorType': 'llm',
        'providerId': provider.id,
        'modelId': 'fixture-only',
      });
      final task = await runtime.submit(
        title: '协议任务',
        type: 'ai.draft',
        agentId: 'ink',
        input: {
          'query': '仅供协议验收',
          'networkConfirmed': true,
          'approvedOrigin': 'http://127.0.0.1:${server.port}',
        },
      );
      await runtime.waitIdle();
      await requestSeen.future.timeout(const Duration(seconds: 3));
      expect(
        taskState(await repo.requireTask(task.id)),
        TaskState.waitingApproval,
      );
      final artifact = (await repo.artifacts(task.id)).single;
      expect(artifact.body, '真实本机 SSE 草稿');
      expect((artifact.data['metadata'] as Map)['usageSource'], 'provider');
      expect(
        jsonEncode((await repo.agent('ink')).data),
        isNot(contains('fixture-not-a-real-key')),
      );
    } finally {
      await server.close(force: true);
      await Future.wait(handlers);
    }
  });
  test('changed website targets require a fresh user confirmation', () async {
    final site = await repo.store.create(
      'website',
      '网站',
      data: {'url': 'https://example.com'},
    );
    final task = await runtime.submit(
      title: '旧授权',
      type: 'server.http',
      agentId: 'nova',
      input: {
        'referenceId': site.id,
        'networkConfirmed': true,
        'approvedUrl': 'https://different.invalid',
      },
    );
    await runtime.waitIdle();
    expect(taskState(await repo.requireTask(task.id)), TaskState.failed);
    expect(
      (await repo.requireTask(task.id)).text('errorMessage'),
      contains('地址已改变'),
    );
  });
  test(
    'cancelled queued work produces no artifact or false completion',
    () async {
      final task = await repo.createTask(
        title: '取消',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
        submissionId: 'cancel',
      );
      await runtime.cancel(task.id);
      await expectLater(
        repo.artifact(task.id, '迟到输出'),
        throwsA(isA<ToolFailure>()),
      );
      expect(await repo.artifacts(task.id), isEmpty);
      expect(taskState(await repo.requireTask(task.id)), TaskState.cancelled);
    },
  );
  test('cancel during a real HTTP stream stops the request and rejects late output', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>(), release = Completer<void>();
    final handlers = <Future<void>>[];
    server.listen((request) {
      handlers.add(() async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
        );
        await request.response.flush();
        received.complete();
        await release.future;
        try {
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        } on HttpException {
          // Expected when the client cancels the response stream.
        } on SocketException {
          // Expected when cancellation closes the underlying socket.
        }
      }());
    });
    try {
      final provider = await ai.configure(
        AiConfig(
          name: '取消夹具',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'fixture-only',
        ),
        key: 'fixture-not-a-real-key',
      );
      await repo.saveAgent(await repo.agent('ink'), {
        'executorType': 'llm',
        'providerId': provider.id,
        'modelId': 'fixture-only',
      });
      final task = await runtime.submit(
        title: '取消流',
        type: 'ai.draft',
        agentId: 'ink',
        input: {
          'query': '测试输入',
          'networkConfirmed': true,
          'approvedOrigin': 'http://127.0.0.1:${server.port}',
        },
      );
      await received.future.timeout(const Duration(seconds: 5));
      final queued = await runtime.submit(
        title: '同角色排队任务',
        type: 'studio.history',
        agentId: 'ink',
        input: {},
      );
      expect(taskState(await repo.requireTask(queued.id)), TaskState.queued);
      await runtime.cancel(queued.id);
      expect(runtime.activeStates['ink'], TaskState.working);
      expect(await repo.artifacts(queued.id), isEmpty);
      final low = await runtime.submit(
        title: '低优先级',
        type: 'studio.history',
        agentId: 'nova',
        input: {},
      );
      final high = await runtime.submit(
        title: '高优先级',
        type: 'studio.history',
        agentId: 'patch',
        input: {},
      );
      await repo.setPriority(high.id, 3);
      await runtime.cancel(task.id);
      await runtime.waitIdle().timeout(const Duration(seconds: 5));
      release.complete();
      await Future.wait(handlers);
      expect(taskState(await repo.requireTask(task.id)), TaskState.cancelled);
      expect(await repo.artifacts(task.id), isEmpty);
      expect(
        (await repo.artifacts(high.id)).single.body,
        contains('低优先级 · 待处理'),
      );
      expect(
        (await repo.artifacts(low.id)).single.body,
        contains('高优先级 · 待审核'),
      );
      expect(
        (await repo.events(task.id))
            .any((e) => e.text('eventType') == 'completed'),
        isFalse,
      );
    } finally {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    }
  });
}

class _PausedSelectionRepository extends StudioRepository {
  _PausedSelectionRepository(super.store);
  bool pauseNextRead = false;
  final readStarted = Completer<void>(), release = Completer<void>();
  @override
  Future<ToolRecord> requireTask(String id) async {
    final record = await super.requireTask(id);
    if (pauseNextRead) {
      pauseNextRead = false;
      readStarted.complete();
      await release.future;
    }
    return record;
  }
}
