import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/local_markdown.dart';
import '../../shared/record_ui.dart';
import 'office_domain.dart';
import 'office_game.dart';
import 'office_presentation.dart';
import 'codex_diagnostic_dialog.dart';
import 'studio_dialogs.dart';
import 'studio_providers.dart';

class StudioPage extends ConsumerStatefulWidget {
  const StudioPage({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  ConsumerState<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends ConsumerState<StudioPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController tabs;
  bool foreground = true;
  OfficeGame? game;
  String selected = 'byte';
  bool developer = false;
  double gestureZoom = 1;
  @override
  void initState() {
    super.initState();
    tabs = TabController(
      length: 3,
      initialIndex: widget.initialTab,
      vsync: this,
    );
    tabs.addListener(syncRendering);
    WidgetsBinding.instance.addObserver(this);
  }

  void syncRendering() {
    if (tabs.index == 0 && foreground) {
      game?.resumeEngine();
    } else {
      game?.pauseEngine();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    syncRendering();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tabs.removeListener(syncRendering);
    tabs.dispose();
    game?.pauseEngine();
    final ownedGame = game;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ownedGame?.releaseAssets(),
    );
    super.dispose();
  }

  OfficeGame makeGame() => OfficeGame(
    ref.read(agentRuntimeProvider),
    onSelect: (id) {
      if (mounted) {
        setState(() {
          selected = id;
          game?.selectedId = id;
        });
      }
    },
    onGround: (cell) => unawaited(
      runUi(context, () => ref.read(agentRuntimeProvider).moveUser(cell)),
    ),
    onFurniture: (f) => unawaited(furniture(f)),
  )..selectedId = selected;
  void persistView() => unawaited(runUi(context, () => game!.saveView()));
  Future<void> actorMenu(Offset point) async {
    final id = game?.actorAt(point);
    if (id == null) return;
    setState(() {
      selected = id;
      game!.selectedId = id;
    });
    final agent = (await ref.read(recordStoreProvider).list('studio_agent'))
        .firstWhere((a) => a.text('agentId') == id);
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(agent.title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'focus'),
            child: const Text('聚焦角色'),
          ),
          if (id != 'links')
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'task'),
              child: const Text('安排任务'),
            ),
          if (id != 'links')
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'config'),
              child: const Text('模型与工具权限'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'focus') {
      game!.focusActor(id);
      persistView();
    }
    if (action == 'task') await showTaskComposer(context, ref, agentId: id);
    if (action == 'config' && mounted) {
      await showAgentConfiguration(context, ref, agent);
    }
  }

  Future<void> furniture(Furniture f) async {
    if (f.type == 'meeting') {
      await meeting();
      return;
    }
    if (f.type != 'desk') {
      ltMessage(context, switch (f.type) {
        'coffee' => '休息区 · 咖啡机（氛围设施，不代表模型资源消耗）',
        'sofa' => '休息区 · 沙发',
        'shelf' => '办公室资料书架',
        _ => '办公室植物',
      });
      return;
    }
    final runtime = ref.read(agentRuntimeProvider);
    if (runtime.movement.actors.values.any((a) => a.walking) ||
        runtime.activeStates.values.any((s) => s == TaskState.working)) {
      ltMessage(context, '请等待移动或执行结束后调整工位。');
      return;
    }
    final values = await ltEditForm(
      context,
      title: '调整工位 ${f.id}',
      fields: [
        LTField(
          'agent',
          '角色 ID（links/byte/nova/ink/pix/patch，可留空）',
          initial: f.agentId,
        ),
        LTField('x', '网格 X（1–16）', initial: '${f.cell.x}', required: true),
        LTField('y', '网格 Y（2–11）', initial: '${f.cell.y}', required: true),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      final x = int.tryParse(values['x']!), y = int.tryParse(values['y']!);
      if (x == null || y == null) throw const ToolFailure('坐标必须是整数。');
      final assignment = values['agent']!.trim();
      final layout = OfficeLayout([
        for (final item in runtime.movement.layout.furniture)
          item.id == f.id
              ? Furniture(item.id, item.type, Cell(x, y), agentId: assignment)
              : assignment.isNotEmpty && item.agentId == assignment
              ? Furniture(item.id, item.type, item.cell)
              : item,
      ]);
      for (final entry in runtime.movement.actors.entries) {
        final a = entry.value;
        if (!layout.grid.canWalk(a.cell) ||
            (layout.seats.contains(a.cell) &&
                layout.desk(entry.key)?.seat != a.cell)) {
          throw const ToolFailure('家具不能放到角色脚下，请先移动角色。');
        }
      }
      await ref.read(studioRepositoryProvider).saveLayout(layout);
      runtime.movement.layout = layout;
      if (mounted) {
        final previous = game;
        setState(() => game = makeGame());
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => previous?.releaseAssets(),
        );
      }
    }, success: '布局已保存；全部工位仍能从入口到达。');
  }

  Future<void> meeting() async {
    final agents = (await ref.read(recordStoreProvider).list('studio_agent'))
        .where((a) => a.text('agentId') != 'links')
        .toList();
    if (!mounted) return;
    final selectedAgents = <String>{};
    final topic = TextEditingController(), notes = TextEditingController();
    bool saving = false;
    String? error;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('本地会议 · 用户记录'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('离线会议仅保存你填写的议题与纪要，不生成或伪装多模型讨论。'),
                    const SizedBox(height: 12),
                    LTTextField(controller: topic, label: '议题'),
                    const SizedBox(height: 12),
                    LTTextField(
                      controller: notes,
                      label: '用户填写的会议纪要',
                      maxLines: 5,
                    ),
                    for (final a in agents)
                      CheckboxListTile(
                        title: Text(a.title),
                        value: selectedAgents.contains(a.text('agentId')),
                        onChanged: saving
                            ? null
                            : (v) => setState(
                                () => v == true
                                    ? selectedAgents.add(a.text('agentId'))
                                    : selectedAgents.remove(a.text('agentId')),
                              ),
                      ),
                    if (error != null) Text(error!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              LTButton(
                label: '保存纪要并召集',
                loading: saving,
                onPressed: () async {
                  setState(() => saving = true);
                  try {
                    if (topic.text.trim().isEmpty ||
                        notes.text.trim().isEmpty ||
                        selectedAgents.isEmpty) {
                      throw const ToolFailure('请填写议题、纪要并选择参与者。');
                    }
                    final runtime = ref.read(agentRuntimeProvider);
                    if (runtime.movement.actors.values.any((a) => a.walking) ||
                        runtime.activeStates.values.any(
                          (s) => s == TaskState.working,
                        )) {
                      throw const ToolFailure('有角色正在移动或工作，请稍后召集。');
                    }
                    await ref
                        .read(memoryRepositoryProvider)
                        .createNote(
                          '会议：${topic.text}',
                          body:
                              '# ${topic.text}\n\n本地会议；内容由用户填写。\n\n参与角色：${selectedAgents.join(', ')}\n\n${notes.text}',
                          source: 'studio.userMeeting',
                          sensitive: true,
                        );
                    const seats = [
                      Cell(13, 10),
                      Cell(14, 9),
                      Cell(15, 9),
                      Cell(16, 9),
                      Cell(17, 10),
                    ];
                    var index = 0;
                    for (final id in selectedAgents) {
                      final target = seats[index++];
                      unawaited(
                        runtime.movement
                            .move(id, target)
                            .catchError((Object _) {}),
                      );
                    }
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) {
                      setState(
                        () => error = e is ToolFailure
                            ? e.message
                            : '纪要保存失败，输入仍在此处。',
                      );
                    }
                  } finally {
                    if (context.mounted) setState(() => saving = false);
                  }
                },
              ),
            ],
          ),
        ),
      );
    } finally {
      topic.dispose();
      notes.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(studioReadyProvider);
    return ready.when(
      loading: () => const LTLoadingState(),
      error: (_, stack) =>
          const LTErrorState(message: '办公室初始化失败，原数据保留。请检查磁盘与布局版本。'),
      data: (_) {
        game ??= makeGame();
        final profiles =
            ref.watch(recordsProvider('studio_agent')).asData?.value ?? [];
        game!.actorNames
          ..clear()
          ..addEntries(
            profiles.map((a) => MapEntry(a.text('agentId'), a.title)),
          );
        final tasks =
            ref.watch(recordsProvider('studio_task')).asData?.value ?? [];
        final active = tasks
            .where(
              (t) => {
                TaskState.queued,
                TaskState.walking,
                TaskState.working,
              }.contains(taskState(t)),
            )
            .length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LINKS STUDIO',
                        style: TextStyle(fontSize: 10, letterSpacing: 2),
                      ),
                      Text(
                        '像素工作室',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  LTBadge('$active 项活动任务'),
                  const LTBadge('本地互动 / 按任务授权 API'),
                  LTButton(
                    label: '安排任务',
                    icon: Icons.add_task,
                    onPressed: () =>
                        showTaskComposer(context, ref, agentId: selected),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: '办公室'),
                Tab(text: '任务中心'),
                Tab(text: '角色与模型'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [
                  LayoutBuilder(
                    builder: (context, c) {
                      final scene = Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                LTIconButton(
                                  icon: Icons.zoom_out,
                                  tooltip: '缩小',
                                  onPressed: () {
                                    game!.zoomBy(.5);
                                    game!.snapZoom();
                                    persistView();
                                  },
                                ),
                                LTIconButton(
                                  icon: Icons.zoom_in,
                                  tooltip: '放大',
                                  onPressed: () {
                                    game!.zoomBy(2);
                                    game!.snapZoom();
                                    persistView();
                                  },
                                ),
                                LTIconButton(
                                  icon: Icons.fit_screen,
                                  tooltip: '回到全景',
                                  onPressed: () {
                                    game!.overview();
                                    persistView();
                                  },
                                ),
                                LTIconButton(
                                  icon: Icons.center_focus_strong,
                                  tooltip: '聚焦所选角色',
                                  onPressed: () {
                                    game!.focusActor(selected);
                                    persistView();
                                  },
                                ),
                                PopupMenuButton<OfficeEnvironment>(
                                  tooltip: '办公室昼夜环境',
                                  initialValue: ref
                                      .read(agentRuntimeProvider)
                                      .presentation
                                      .environment,
                                  onSelected: (mode) => unawaited(
                                    runUi(context, () async {
                                      await game!.saveView(environment: mode);
                                      if (mounted) setState(() {});
                                    }),
                                  ),
                                  itemBuilder: (_) => [
                                    for (final mode in OfficeEnvironment.values)
                                      PopupMenuItem(
                                        value: mode,
                                        child: Text(mode.label),
                                      ),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      '环境：${ref.read(agentRuntimeProvider).presentation.environment.label}',
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  icon: const Icon(
                                    Icons.groups_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('本地会议'),
                                  onPressed: meeting,
                                ),
                                if (kDebugMode)
                                  IconButton(
                                    tooltip: '开发者网格与寻路（只读）',
                                    icon: Icon(
                                      developer
                                          ? Icons.grid_off
                                          : Icons.grid_on,
                                    ),
                                    onPressed: () => setState(() {
                                      developer = !developer;
                                      game!.showGrid = developer;
                                    }),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ClipRect(
                              child: Listener(
                                onPointerSignal: (event) {
                                  if (event is PointerScrollEvent) {
                                    game!.zoomBy(
                                      event.scrollDelta.dy > 0 ? 0.5 : 2,
                                    );
                                    game!.snapZoom();
                                    persistView();
                                  }
                                },
                                child: GestureDetector(
                                  onDoubleTapDown: (details) {
                                    final id = game!.actorAt(
                                      details.localPosition,
                                    );
                                    if (id != null) {
                                      setState(() {
                                        selected = id;
                                        game!.selectedId = id;
                                      });
                                      game!.focusActor(id);
                                      persistView();
                                    }
                                  },
                                  onDoubleTap: () {},
                                  onSecondaryTapDown: (details) => unawaited(
                                    actorMenu(details.localPosition),
                                  ),
                                  onLongPressStart: (details) => unawaited(
                                    actorMenu(details.localPosition),
                                  ),
                                  onScaleStart: (_) => gestureZoom =
                                      game!.camera.viewfinder.zoom,
                                  onScaleUpdate: (details) {
                                    if (details.scale != 1) {
                                      game!.camera.viewfinder.zoom =
                                          (gestureZoom * details.scale).clamp(
                                            1,
                                            4,
                                          );
                                    } else {
                                      game!.pan(details.focalPointDelta);
                                    }
                                  },
                                  onScaleEnd: (_) {
                                    game!.snapZoom();
                                    persistView();
                                  },
                                  child: GameWidget<OfficeGame>(
                                    key: ObjectKey(game),
                                    game: game!,
                                    loadingBuilder: (_) =>
                                        const LTLoadingState(),
                                    errorBuilder: (_, error) =>
                                        const LTErrorState(
                                          message: '场景资源加载失败，请检查完整安装目录。',
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              developer
                                  ? '调试网格：红色为障碍，蓝色可通行，黄色为实际路径。状态不写入用户任务。'
                                  : '点击角色查看资料 · 点击走道移动 Links · 拖动平移 · 滚轮/双指缩放',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .extension<DesignTokens>()!
                                    .textSecondary,
                              ),
                            ),
                          ),
                        ],
                      );
                      final inspector = _AgentInspector(
                        id: selected,
                        onAssign: () =>
                            showTaskComposer(context, ref, agentId: selected),
                      );
                      return c.maxWidth >= 1000
                          ? Row(
                              children: [
                                Expanded(child: scene),
                                SizedBox(
                                  width: 310,
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.all(16),
                                    child: inspector,
                                  ),
                                ),
                              ],
                            )
                          : SingleChildScrollView(
                              child: Column(
                                children: [
                                  SizedBox(
                                    height: c.maxHeight.clamp(340, 520),
                                    child: scene,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: inspector,
                                  ),
                                ],
                              ),
                            );
                    },
                  ),
                  const TaskCenter(),
                  ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      for (final id in agentNames)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _AgentInspector(
                            id: id,
                            onAssign: () =>
                                showTaskComposer(context, ref, agentId: id),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class PixelPortrait extends StatelessWidget {
  const PixelPortrait(this.id, {super.key, this.scale = 2});
  final String id;
  final double scale;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${id[0].toUpperCase()}${id.substring(1)} 像素形象',
    image: true,
    child: SizedBox(
      width: 32 * scale,
      height: 48 * scale,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 256 * scale,
          maxWidth: 256 * scale,
          minHeight: actorAnimationTags.length * 48 * scale,
          maxHeight: actorAnimationTags.length * 48 * scale,
          child: Image.asset(
            'assets/pixel_studio/characters/$id.png',
            filterQuality: FilterQuality.none,
            fit: BoxFit.fill,
            excludeFromSemantics: true,
          ),
        ),
      ),
    ),
  );
}

class _AgentInspector extends ConsumerWidget {
  const _AgentInspector({required this.id, required this.onAssign});
  final String id;
  final VoidCallback onAssign;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents =
        ref.watch(recordsProvider('studio_agent')).asData?.value ?? [];
    final agent = agents.where((a) => a.text('agentId') == id).firstOrNull;
    if (agent == null) return const LTLoadingState();
    final tasks =
        (ref.watch(recordsProvider('studio_task')).asData?.value ?? [])
            .where((t) => t.text('assignedAgentId') == id)
            .toList();
    final current = tasks.where((t) => !taskState(t).terminal).firstOrNull;
    return LTCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PixelPortrait(id),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      agent.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(agent.text('role')),
                    const SizedBox(height: 8),
                    LTBadge(
                      id == 'links'
                          ? '用户代表'
                          : agent.text('executorType') == 'llm'
                          ? 'API 已选择 · 连接未验证'
                          : '本地互动模式',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          if (agent.text('roleDescription').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(agent.text('roleDescription')),
            ),
          Text('当前任务：${current?.title ?? '无'}'),
          const SizedBox(height: 8),
          Text('任务状态：${current == null ? '空闲' : taskState(current).label}'),
          const SizedBox(height: 8),
          Text(
            '已完成：${tasks.where((t) => taskState(t) == TaskState.completed).length} 项',
          ),
          const SizedBox(height: 8),
          Text(
            '模型：${agent.text('modelId').isEmpty ? '未配置执行器' : agent.text('modelId')}',
          ),
          const SizedBox(height: 8),
          Text(
            '最后配置活动：${readableTime(agent.updatedAt)}',
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 16),
          if (id != 'links')
            LTButton(label: '安排任务', icon: Icons.add_task, onPressed: onAssign),
          TextButton.icon(
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: const Text('本地对话'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text('${agent.title} · 本地预设对话'),
                content: Text(
                  id == 'links'
                      ? '我是你的交互角色。点击空地即可移动；任务由你安排并审核。'
                      : '我是${agent.text('role')}岗位。你可以给我安排真实本地工具任务。模型未连接时，我不会假装完成 AI 工作。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            ),
          ),
          if (id != 'links')
            TextButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('模型与工具权限'),
              onPressed: () => showAgentConfiguration(context, ref, agent),
            ),
          if (id == 'byte')
            TextButton.icon(
              icon: const Icon(Icons.terminal, size: 18),
              label: const Text('Codex 本地诊断'),
              onPressed: () => showCodexDiagnostic(context),
            ),
          if (current?.text('errorMessage').isNotEmpty ?? false)
            Text(current!.text('errorMessage')),
        ],
      ),
    );
  }
}

class TaskCenter extends ConsumerStatefulWidget {
  const TaskCenter({super.key});
  @override
  ConsumerState<TaskCenter> createState() => _TaskCenterState();
}

class _TaskCenterState extends ConsumerState<TaskCenter> {
  final boardScroll = ScrollController();
  @override
  void dispose() {
    boardScroll.dispose();
    super.dispose();
  }

  TaskState? filter;
  String query = '';
  bool board = false, priorityFirst = false;
  Widget taskCard(ToolRecord task) => LTCard(
    padding: EdgeInsets.zero,
    child: ListTile(
      isThreeLine: true,
      leading: PixelPortrait(task.text('assignedAgentId'), scale: 1),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${taskState(task).label} · P${task.number('priority')}\n${readableTime(task.updatedAt)}',
      ),
      trailing: taskState(task) == TaskState.queued
          ? PopupMenuButton<int>(
              tooltip: '调整排队优先级',
              onSelected: (value) => unawaited(
                runUi(
                  context,
                  () => ref
                      .read(studioRepositoryProvider)
                      .setPriority(task.id, value),
                ),
              ),
              itemBuilder: (_) => [
                for (var p = 0; p < 4; p++)
                  PopupMenuItem(
                    value: p,
                    child: Text('P$p${p == 3 ? ' · 最高' : ''}'),
                  ),
              ],
              icon: const Icon(Icons.low_priority),
            )
          : const Icon(Icons.chevron_right),
      onTap: () => showTaskDetails(context, task.id),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(recordsProvider('studio_task'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              labelText: '搜索任务、角色或错误',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) =>
                setState(() => query = value.trim().toLowerCase()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('看板'),
                selected: board,
                onSelected: (v) => setState(() => board = v),
              ),
              FilterChip(
                label: const Text('优先级排序'),
                selected: priorityFirst,
                onSelected: (v) => setState(() => priorityFirst = v),
              ),
              TextButton.icon(
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('导出历史'),
                onPressed: () => runUi(context, () async {
                  if (!await ltConfirm(
                    context,
                    title: '导出任务历史',
                    message: '导出最近100项任务的输入、日志和产物引用，可能含私人资料。产物正文请在任务详情单独导出；日志上限会写入文件说明。',
                  )) {
                    return;
                  }
                  final history = await ref
                      .read(studioRepositoryProvider)
                      .exportHistory();
                  await FilePicker.saveFile(
                    fileName: 'Links-task-history.json',
                    bytes: Uint8List.fromList(utf8.encode(history)),
                    mimeType: 'application/json',
                  );
                }),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: filter == null,
                onSelected: (_) => setState(() => filter = null),
              ),
              for (final s in TaskState.values)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    label: Text(s.label),
                    selected: filter == s,
                    onSelected: (_) => setState(() => filter = s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: tasks.when(
            loading: () => const LTLoadingState(),
            error: (_, stack) => const LTErrorState(),
            data: (all) {
              final shown = all
                  .where(
                    (t) =>
                        (filter == null || taskState(t) == filter) &&
                        '${t.title} ${t.text('assignedAgentId')} ${t.text('errorMessage')}'
                            .toLowerCase()
                            .contains(query),
                  )
                  .toList();
              shown.sort((a, b) {
                final priority = b
                    .number('priority')
                    .compareTo(a.number('priority'));
                return priorityFirst && priority != 0
                    ? priority
                    : b.createdAt.compareTo(a.createdAt);
              });
              if (shown.isEmpty) {
                return const LTEmptyState(
                  title: '没有此状态的任务',
                  message: '安排任务后才会出现真实事件与结果。',
                );
              }
              if (board) {
                final groups = <String, Set<TaskState>>{
                  '待处理': {TaskState.queued},
                  '进行中': {TaskState.walking, TaskState.working},
                  '待审核': {TaskState.waitingApproval},
                  '已完成': {TaskState.completed},
                  '失败与取消': {TaskState.failed, TaskState.cancelled},
                };
                return Scrollbar(
                  controller: boardScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: boardScroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final group in groups.entries)
                          SizedBox(
                            width: 280,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      '${group.key} · ${shown.where((t) => group.value.contains(taskState(t))).length}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: ListView(
                                      children: [
                                        for (final task in shown.where(
                                          (t) => group.value.contains(
                                            taskState(t),
                                          ),
                                        ))
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 8,
                                            ),
                                            child: taskCard(task),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: shown.length,
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) => taskCard(shown[index]),
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<void> showTaskDetails(BuildContext context, String id) =>
    showDialog<void>(context: context, builder: (_) => _TaskDetails(id));

class _TaskDetails extends ConsumerWidget {
  const _TaskDetails(this.id);
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(recordByIdProvider(id)).asData?.value;
    if (task == null) return const AlertDialog(content: LTLoadingState());
    final state = taskState(task), runtime = ref.read(agentRuntimeProvider);
    final events =
        (ref.watch(recordsProvider('studio_event')).asData?.value ?? [])
            .where((e) => e.text('taskId') == id)
            .toList()
          ..sort(
            (a, b) => a.number('sequence').compareTo(b.number('sequence')),
          );
    final artifacts =
        (ref.watch(recordsProvider('studio_artifact')).asData?.value ?? [])
            .where((a) => a.text('taskId') == id)
            .toList();
    return AlertDialog(
      title: Text(task.title),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  LTBadge(state.label),
                  LTBadge(
                    task.text('executionMode') == 'realAgent'
                        ? '真实 API'
                        : '本地服务',
                  ),
                  if (task.text('parentTaskId').isNotEmpty)
                    const LTBadge('关联重试任务'),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '角色：${task.text('assignedAgentId')}\n创建：${readableTime(task.createdAt)}\n暂停：此执行器不支持暂停，可取消。',
              ),
              if (state == TaskState.failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    task.text('errorMessage'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const Text('实际产物', style: TextStyle(fontWeight: FontWeight.w600)),
              if (artifacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('尚无产物。未执行或失败不会显示虚假的结果。'),
                ),
              for (final a in artifacts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(
                        'SHA-256 ${a.text('checksum')}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      LocalMarkdown(text: a.body),
                      TextButton.icon(
                        icon: const Icon(
                          Icons.file_download_outlined,
                          size: 18,
                        ),
                        label: const Text('导出 Markdown'),
                        onPressed: () => runUi(context, () async {
                          await FilePicker.saveFile(
                            fileName: 'Links-task-${task.id}.md',
                            bytes: Uint8List.fromList(utf8.encode(a.body)),
                            mimeType: 'text/markdown',
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              const Text(
                '持久化执行事件',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final e in events)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text('#${e.number('sequence')}'),
                  title: Text(e.title),
                  subtitle: Text(
                    '${e.text('timestamp')} · ${e.text('source')}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (!state.terminal)
          TextButton(
            onPressed: () => runUi(context, () => runtime.cancel(id)),
            child: const Text('取消任务'),
          ),
        if ({
          TaskState.failed,
          TaskState.cancelled,
          TaskState.waitingApproval,
        }.contains(state))
          TextButton(
            onPressed: () => runUi(
              context,
              () => runtime.retry(id),
              success: '已建立有父任务引用的新尝试。',
            ),
            child: Text(state == TaskState.waitingApproval ? '返工' : '安全重试'),
          ),
        if (state == TaskState.waitingApproval)
          LTButton(
            label: task.text('type') == 'timeline.create'
                ? '通过并创建个人待办'
                : '审核通过',
            onPressed: () => runUi(context, () => runtime.approve(id)),
          ),
        if (state == TaskState.completed)
          LTButton(
            label: task.text('memoryNoteId').isEmpty
                ? '存入 Memory'
                : '已保存至 Memory',
            onPressed: () => runUi(
              context,
              () => ref
                  .read(studioRepositoryProvider)
                  .saveToMemory(id, ref.read(memoryRepositoryProvider)),
              success: '产物已保存为敏感笔记。',
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
