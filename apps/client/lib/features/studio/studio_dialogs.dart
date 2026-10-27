import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import 'studio_providers.dart';
import 'studio_repository.dart';

Future<void> showTaskComposer(
  BuildContext context,
  WidgetRef ref, {
  String agentId = 'nova',
}) async {
  final store = ref.read(recordStoreProvider);
  final agents = await store.list('studio_agent'),
      notes = await store.list('note', limit: 2000),
      roots = await store.list('archive_root'),
      projects = await store.list('project'),
      sites = await store.list('website'),
      providers = await store.list('ai_provider');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _TaskComposer(
      agents: agents,
      notes: notes,
      roots: roots,
      projects: projects,
      sites: sites,
      providers: providers,
      initialAgent: agentId,
    ),
  );
}

class _TaskComposer extends ConsumerStatefulWidget {
  const _TaskComposer({
    required this.agents,
    required this.notes,
    required this.roots,
    required this.projects,
    required this.sites,
    required this.providers,
    required this.initialAgent,
  });
  final List<ToolRecord> agents, notes, roots, projects, sites, providers;
  final String initialAgent;
  @override
  ConsumerState<_TaskComposer> createState() => _TaskComposerState();
}

class _TaskComposerState extends ConsumerState<_TaskComposer> {
  late String agent = widget.initialAgent == 'links'
      ? 'nova'
      : widget.initialAgent;
  String type = 'memory.search', reference = '';
  final title = TextEditingController(),
      query = TextEditingController(),
      todoDue = TextEditingController(),
      todoZone = TextEditingController(text: 'Asia/Shanghai'),
      todoTags = TextEditingController();
  final selectedNotes = <String>{};
  final submissionId = newId();
  bool network = false, busy = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    query.dispose();
    todoDue.dispose();
    todoZone.dispose();
    todoTags.dispose();
    super.dispose();
  }

  List<ToolRecord> get references =>
      (type.startsWith('archive.') || type == 'image.suggest')
      ? widget.roots
      : type == 'server.http'
      ? widget.sites
      : (type == 'memory.context' || type == 'timeline.create')
      ? widget.projects
      : type == 'memory.tags' || type == 'ai.summary'
      ? widget.notes
      : [];
  ToolRecord get profile =>
      widget.agents.firstWhere((a) => a.text('agentId') == agent);
  ToolRecord? get provider {
    for (final p in widget.providers) {
      if (p.id == profile.text('providerId')) return p;
    }
    return null;
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (references.isNotEmpty &&
          reference.isEmpty &&
          type != 'timeline.create') {
        throw const ToolFailure('请明确选择资料来源。');
      }
      if (((type.startsWith('archive.') || type == 'image.suggest') ||
              {
                'server.http',
                'memory.tags',
                'memory.context',
                'ai.summary',
              }.contains(type)) &&
          reference.isEmpty) {
        throw const ToolFailure('此类型没有可用资料，请先到相应模块添加。');
      }
      await ref
          .read(agentRuntimeProvider)
          .submit(
            title: title.text.trim().isEmpty
                ? allTaskTypes[type]!
                : title.text.trim(),
            type: type,
            agentId: agent,
            submissionId: submissionId,
            input: {
              'query': query.text,
              if (type == 'timeline.create') ...{
                'todoDue': todoDue.text,
                'timeZone': todoZone.text,
                'tags': todoTags.text.split(RegExp(r'[,，]')),
                'projectId': reference,
              },
              'referenceId': reference,
              'noteIds': selectedNotes.toList(),
              'networkConfirmed': network,
              if (type.startsWith('ai.') && provider != null)
                'approvedOrigin': Uri.parse(provider!.text('baseUrl')).origin,
              if (type == 'server.http' && reference.isNotEmpty)
                'approvedUrl': widget.sites
                    .firstWhere((s) => s.id == reference)
                    .text('url'),
              if (type == 'memory.context') 'projectId': reference,
            },
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ToolFailure ? e.message : '任务未能保存，请检查磁盘或配置。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAi = type.startsWith('ai.'),
        isNetwork = isAi || type == 'server.http';
    return AlertDialog(
      title: const Text('安排真实任务'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('本地任务调用现有工具；AI 任务只生成待审核草稿，不自动修改原始资料。'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: agent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '分配员工'),
                items: [
                  for (final a in widget.agents.where(
                    (a) => a.text('agentId') != 'links' && a.flag('enabled'),
                  ))
                    DropdownMenuItem(
                      value: a.text('agentId'),
                      child: Text('${a.title} · ${a.text('role')}'),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        agent = v!;
                        network = false;
                      }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '任务类型'),
                items: [
                  for (final e in allTaskTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        type = v!;
                        reference = '';
                        network = false;
                        selectedNotes.clear();
                      }),
              ),
              const SizedBox(height: 12),
              LTTextField(controller: title, label: '任务标题（可留空）'),
              const SizedBox(height: 12),
              if (references.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(type),
                  initialValue: reference.isEmpty ? null : reference,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: type == 'timeline.create'
                        ? '关联项目（可空）'
                        : '明确选择资料',
                  ),
                  items: [
                    if (type == 'timeline.create')
                      const DropdownMenuItem(value: '', child: Text('不关联项目')),
                    for (final n in references)
                      DropdownMenuItem(
                        value: n.id,
                        child: Text(
                          n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          reference = v!;
                          selectedNotes.clear();
                          network = false;
                        }),
                ),
                const SizedBox(height: 12),
              ],
              if (type == 'memory.search' ||
                  type == 'bookmarks.search' ||
                  type == 'timeline.create' ||
                  (isAi && type != 'ai.summary'))
                LTTextField(
                  controller: query,
                  label: type == 'memory.search'
                      ? '知识库搜索词'
                      : type == 'bookmarks.search'
                      ? '收藏搜索词'
                      : type == 'timeline.create'
                      ? '待办说明'
                      : '任务输入',
                  maxLines: isAi ? 5 : 1,
                ),
              if (type == 'timeline.create') ...[
                LTTextField(
                  controller: todoDue,
                  label: '待办截止 YYYY-MM-DD HH:MM（可空）',
                ),
                LTTextField(controller: todoZone, label: '待办IANA时区'),
                LTTextField(controller: todoTags, label: '待办标签（逗号分隔）'),
                const Text(
                  '任务标题将作为待办标题。先在角色设置中勾选创建权限，再运行生成草稿，审核后才创建个人待办。项目关联可留空。',
                ),
              ],
              if (type == 'memory.context' && reference.isNotEmpty) ...[
                const Text('只导出勾选的非敏感笔记：'),
                for (final note in widget.notes.where(
                  (n) =>
                      n.text('projectId') == reference &&
                      !n.flag('isSensitive'),
                ))
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(note.title),
                    value: selectedNotes.contains(note.id),
                    onChanged: busy
                        ? null
                        : (v) => setState(() {
                            v == true
                                ? selectedNotes.add(note.id)
                                : selectedNotes.remove(note.id);
                          }),
                  ),
              ],
              if (isAi)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    provider == null
                        ? '未配置执行器：请先在角色面板设置 AI Desk Provider。'
                        : '模型：${provider!.text('model')}\n外发目标：${provider!.text('baseUrl')}\n资料：${type == 'ai.summary' ? '所选笔记全文' : '输入文字'}；密钥由系统安全存储读取。',
                  ),
                ),
              if (type == 'server.http' && reference.isNotEmpty)
                Text(
                  '外发目标：${widget.sites.firstWhere((s) => s.id == reference).text('url')}\n仅发送网站检测请求，不发送笔记。',
                ),
              if (isNetwork)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('确认上述目标及数据范围，允许此任务联网'),
                  value: network,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => network = v ?? false),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        LTButton(label: '加入任务队列', loading: busy, onPressed: submit),
      ],
    );
  }
}

Future<void> showAgentConfiguration(
  BuildContext context,
  WidgetRef ref,
  ToolRecord agent,
) async {
  if (agent.text('agentId') == 'links') {
    ltMessage(context, 'Links 是你的交互角色，不会执行后台 AI 任务。');
    return;
  }
  final providers = await ref.read(recordStoreProvider).list('ai_provider');
  if (!context.mounted) return;
  var executor = agent.text('executorType', 'local'),
      selected = agent.text('providerId');
  final instructions = TextEditingController(
    text: agent.text('systemInstructions'),
  );
  final displayName = TextEditingController(text: agent.title),
      role = TextEditingController(text: agent.text('role')),
      description = TextEditingController(text: agent.text('roleDescription'));
  bool enabled = agent.flag('enabled');
  final allowed = agent.strings('allowedTools').toSet();
  bool busy = false;
  String? error;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('${agent.title} · 执行器与权限'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LTTextField(controller: displayName, label: '显示名称'),
                  const SizedBox(height: 12),
                  LTTextField(controller: role, label: '岗位'),
                  const SizedBox(height: 12),
                  LTTextField(
                    controller: description,
                    label: '角色描述',
                    maxLines: 2,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用角色接收任务'),
                    value: enabled,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => enabled = value),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: executor,
                    decoration: const InputDecoration(labelText: '执行器'),
                    items: const [
                      DropdownMenuItem(value: 'local', child: Text('本地工具执行器')),
                      DropdownMenuItem(
                        value: 'llm',
                        child: Text('真实 LLM API（复用 AI Desk）'),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() => executor = v!),
                  ),
                  const SizedBox(height: 12),
                  if (executor == 'llm')
                    DropdownButtonFormField<String>(
                      initialValue: providers.any((p) => p.id == selected)
                          ? selected
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'AI Desk Provider / 模型',
                      ),
                      items: [
                        for (final p in providers)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text('${p.title} · ${p.text('model')}'),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setState(() => selected = v!),
                    ),
                  const SizedBox(height: 12),
                  LTTextField(
                    controller: instructions,
                    label: 'System Instructions',
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  const Text('允许使用的本地工具（模型无法自行提升权限）'),
                  for (final tool in localTools.entries)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tool.value),
                      value: allowed.contains(tool.key),
                      onChanged: busy
                          ? null
                          : (v) => setState(
                              () => v == true
                                  ? allowed.add(tool.key)
                                  : allowed.remove(tool.key),
                            ),
                    ),
                  const Text(
                    'CLI、远端、原生 Anthropic/Google 协议尚未接入；此处仅配置已有的 OpenAI/兼容 API。角色配置不含 Key。',
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            LTButton(
              label: '保存配置',
              loading: busy,
              onPressed: () async {
                setState(() => busy = true);
                try {
                  if (executor == 'llm' &&
                      !providers.any((p) => p.id == selected)) {
                    throw const ToolFailure('请先在 AI Desk 配置 Provider。');
                  }
                  final provider = providers
                      .where((p) => p.id == selected)
                      .firstOrNull;
                  await ref.read(studioRepositoryProvider).saveAgent(agent, {
                    'displayName': displayName.text,
                    'role': role.text,
                    'roleDescription': description.text,
                    'enabled': enabled,
                    'executorType': executor,
                    'providerId': executor == 'llm' ? selected : '',
                    'modelId': executor == 'llm' ? provider!.text('model') : '',
                    'systemInstructions': instructions.text,
                    'allowedTools': allowed.toList(),
                    'connectionStatus': executor == 'llm'
                        ? 'notVerified'
                        : 'local',
                  });
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) {
                    setState(
                      () => error = e is ToolFailure ? e.message : '配置未能保存。',
                    );
                  }
                } finally {
                  if (context.mounted) setState(() => busy = false);
                }
              },
            ),
          ],
        ),
      ),
    );
  } finally {
    instructions.dispose();
    displayName.dispose();
    role.dispose();
    description.dispose();
  }
}
