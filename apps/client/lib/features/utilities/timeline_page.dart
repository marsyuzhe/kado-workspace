import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import 'civil_time.dart';
import 'timeline_providers.dart';
import 'timeline_recurrence.dart';
import 'timeline_service.dart';

class TimelineReminderBanner extends ConsumerWidget {
  const TimelineReminderBanner({super.key, required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(timelineReminderControllerProvider).enabled) {
      return const SizedBox.shrink();
    }
    final pending =
        ref.watch(timelinePendingRemindersProvider).asData?.value ?? [];
    if (pending.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.notifications_active_outlined),
          title: Text(
            '个人日程：${pending.length > 100 ? '100+' : pending.length}条应用内提醒',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            pending.first.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onOpen,
        ),
      ),
    );
  }
}

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key});
  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage> {
  String view = '全部待办', query = '', displayZone = 'Asia/Shanghai';
  bool byPriority = false;
  static const statuses = {'todo': '未开始', 'doing': '进行中', 'done': '已完成'};
  Future<void> edit([ToolRecord? row]) async => runUi(context, () async {
    final store = ref.read(recordStoreProvider),
        projects = await store.list('project', limit: 1000),
        tasks = await store.list('studio_task', limit: 1000),
        operations = await store.list('archive_operation', limit: 1000),
        zone = row?.text('timeZone', 'Asia/Shanghai') ?? displayZone;
    String date(String field) {
      final d = field == 'dueAt' && row != null
          ? PersonalTimeline.due(row)
          : DateTime.tryParse(row?.text(field) ?? '');
      return d == null ? '' : CivilTime.format(d, zone, seconds: false);
    }

    Map<String, String> options(List<ToolRecord> rows, String current) => {
      '': '不关联',
      for (final r in rows) r.id: r.title,
      if (current.isNotEmpty && !rows.any((r) => r.id == current))
        current: '原关联（保存时检查是否存在）',
    };
    if (!mounted) return;
    final values = await ltEditForm(
      context,
      title: row == null ? '添加个人待办' : '编辑个人待办',
      description:
          '日期按下方IANA时区解释，留空即清除。重复待办在完成后生成下一次，跳过错过的日次。关联记录只作参考，不会执行Agent或归档操作。',
      fields: [
        LTField('title', '待办标题', initial: row?.title ?? '', required: true),
        LTField(
          'description',
          '待办说明',
          initial: row?.body ?? '',
          multiline: true,
        ),
        LTField('zone', 'IANA时区', initial: zone, required: true),
        LTField('start', '开始时间 YYYY-MM-DD HH:MM', initial: date('startAt')),
        LTField('due', '截止时间 YYYY-MM-DD HH:MM', initial: date('dueAt')),
        LTField(
          'reminder',
          '应用内提醒时间 YYYY-MM-DD HH:MM',
          initial: date('reminderAt'),
        ),
        LTField(
          'rule',
          '重复规则',
          initial: row?.text('recurrenceRule', 'none') ?? 'none',
          options: recurrenceLabels,
        ),
        LTField(
          'priority',
          '优先级',
          initial: '${row?.number('priority') ?? 1}',
          options: const {'0': '低', '1': '普通', '2': '高', '3': '紧急'},
        ),
        LTField(
          'tags',
          '标签（逗号分隔）',
          initial: row?.strings('tags').join(', ') ?? '',
        ),
        LTField(
          'project',
          '关联项目',
          initial: row?.text('projectId') ?? '',
          options: options(projects, row?.text('projectId') ?? ''),
        ),
        LTField(
          'agent',
          '关联Studio任务',
          initial: row?.text('studioTaskId') ?? '',
          options: options(tasks, row?.text('studioTaskId') ?? ''),
        ),
        LTField(
          'archive',
          '关联归档操作',
          initial: row?.text('archiveOperationId') ?? '',
          options: options(operations, row?.text('archiveOperationId') ?? ''),
        ),
      ],
    );
    if (values == null) return;
    DateTime? parse(String key) => values[key]!.trim().isEmpty
        ? null
        : CivilTime.parse(values[key]!, values['zone']!.trim());
    await ref
        .read(timelineServiceProvider)
        .save(
          values['title']!,
          description: values['description']!,
          timeZone: values['zone']!.trim(),
          startAt: parse('start'),
          due: parse('due'),
          reminderAt: parse('reminder'),
          recurrenceRule: values['rule']!,
          priority: int.parse(values['priority']!),
          tags: values['tags']!.split(RegExp(r'[,，]')),
          projectId: values['project']!,
          studioTaskId: values['agent']!,
          archiveOperationId: values['archive']!,
          existing: row,
          replaceScheduling: true,
        );
  });
  Future<void> inbox() async {
    await showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final pending =
              ref.watch(timelinePendingRemindersProvider).asData?.value ?? [];
          return AlertDialog(
            title: const Text('应用内提醒'),
            content: SizedBox(
              width: 500,
              height: 400,
              child: ListView(
                children: [
                  if (pending.isEmpty) const Text('当前没有待确认提醒'),
                  for (final r in pending)
                    ListTile(
                      title: Text(r.title),
                      subtitle: Text(
                        readableTime(DateTime.parse(r.text('scheduledAt'))),
                      ),
                      trailing: TextButton(
                        onPressed: () => runUi(
                          context,
                          () => ref
                              .read(timelineReminderServiceProvider)
                              .acknowledge(r),
                        ),
                        child: const Text('知道了'),
                      ),
                    ),
                  if (pending.length > 100) const Text('单次展示101条，确认后继续加载。'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reminders = ref.watch(timelineReminderControllerProvider);
    return ref
        .watch(timelineRowsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => const Center(child: Text('日程读取失败，请检查本地存储。')),
          data: (rows) {
            final now = DateTime.now(),
                today = CivilTime.format(now, displayZone).substring(0, 10),
                seventh = CivilTime.format(
                  now.add(const Duration(days: 7)),
                  displayZone,
                ).substring(0, 10);
            final items = rows.where((r) {
              final done = r.text('status') == 'done',
                  due = PersonalTimeline.due(r),
                  day = due == null
                      ? ''
                      : CivilTime.format(due, displayZone).substring(0, 10);
              if (view == '已完成' ? !done : done) return false;
              if (view == '今天' && day != today) return false;
              if (view == '未来7天' &&
                  (day.isEmpty ||
                      day.compareTo(today) < 0 ||
                      day.compareTo(seventh) > 0)) {
                return false;
              }
              if (view == '时间线' && day.isEmpty) return false;
              return '${r.title} ${r.body} ${r.strings('tags').join(' ')}'
                  .toLowerCase()
                  .contains(query.toLowerCase());
            }).toList();
            items.sort((a, b) {
              if (byPriority) {
                final p = b.number('priority').compareTo(a.number('priority'));
                if (p != 0) return p;
              }
              return (PersonalTimeline.due(a) ?? DateTime(9999)).compareTo(
                PersonalTimeline.due(b) ?? DateTime(9999),
              );
            });
            return LTScrollPage(
              title: '个人待办与时间线',
              description: '个人计划与Studio执行任务分开保存。提醒只在应用运行时检查（约15秒），程序关闭期间没有系统通知；重新打开后补充到期提醒。',
              header: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('添加个人待办'),
                    ),
                    OutlinedButton(
                      onPressed: inbox,
                      child: const Text('查看提醒收件箱'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启应用内提醒'),
                  subtitle: Text(
                    reminders.error.isEmpty ? '默认关闭，通知只保存在本机' : reminders.error,
                  ),
                  value: reminders.enabled,
                  onChanged: (v) => runUi(
                    context,
                    () => ref
                        .read(timelineReminderControllerProvider.notifier)
                        .enable(v),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final v in ['今天', '未来7天', '全部待办', '已完成', '时间线'])
                      ChoiceChip(
                        label: Text(v),
                        selected: view == v,
                        onSelected: (_) => setState(() => view = v),
                      ),
                  ],
                ),
                LTTextField(
                  label: '搜索待办、说明或标签',
                  onChanged: (v) => setState(() => query = v),
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    SizedBox(
                      width: 210,
                      child: DropdownButtonFormField<String>(
                        initialValue: displayZone,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '查看时区'),
                        items: [
                          for (final z in [
                            'Asia/Shanghai',
                            'UTC',
                            'America/New_York',
                            'Europe/London',
                            'Asia/Tokyo',
                          ])
                            DropdownMenuItem(
                              value: z,
                              child: Text(z, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setState(() => displayZone = v!),
                      ),
                    ),
                    FilterChip(
                      label: const Text('优先级优先'),
                      selected: byPriority,
                      onSelected: (v) => setState(() => byPriority = v),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '显示${items.length}条 · 总计${rows.length}条 · $displayZone',
                  ),
                ),
              ],
              itemCount: items.length,
              empty: const LTEmptyState(
                title: '这里还没有待办',
                message: '添加计划、时间或标签，完成后可以自动生成下一次。',
              ),
              itemBuilder: (context, i) {
                final r = items[i],
                    due = PersonalTimeline.due(r),
                    zone = r.text('timeZone', 'Asia/Shanghai');
                return LTCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${statuses[r.text('status')] ?? '未开始'} · 优先级${r.number('priority')} · ${recurrenceLabels[r.text('recurrenceRule', 'none')]}',
                      ),
                      Text(
                        due == null
                            ? '未设截止时间'
                            : '截止 ${CivilTime.format(due, displayZone, seconds: false)} · $displayZone${PersonalTimeline.overdue(r, now) ? ' · 已到期' : ''}',
                      ),
                      if (r.text('startAt').isNotEmpty)
                        Text(
                          '开始 ${CivilTime.format(DateTime.parse(r.text('startAt')), displayZone, seconds: false)}',
                        ),
                      if (r.text('reminderAt').isNotEmpty)
                        Text(
                          '提醒 ${CivilTime.format(DateTime.parse(r.text('reminderAt')), displayZone, seconds: false)}',
                        ),
                      if (zone != displayZone) Text('任务时区：$zone'),
                      if (r.body.isNotEmpty) Text(r.body),
                      if (r.strings('tags').isNotEmpty)
                        Text('#${r.strings('tags').join(' #')}'),
                      if (r.number('recurrenceSkipped') > 0)
                        Text('上次完成跳过${r.number('recurrenceSkipped')}个过期日次'),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: () => edit(r),
                            child: const Text('编辑待办'),
                          ),
                          for (final s in statuses.entries)
                            if (r.text('status') != s.key)
                              TextButton(
                                onPressed: () => runUi(
                                  context,
                                  () => ref
                                      .read(timelineServiceProvider)
                                      .setState(r, s.key),
                                ),
                                child: Text(s.value),
                              ),
                          if (r.text('projectId').isNotEmpty)
                            TextButton(
                              onPressed: () => context.go(
                                '/modules/memory?id=${r.text('projectId')}',
                              ),
                              child: const Text('关联项目'),
                            ),
                          if (r.text('studioTaskId').isNotEmpty)
                            TextButton(
                              onPressed: () =>
                                  context.go('/modules/studio?view=tasks'),
                              child: const Text('关联Studio任务'),
                            ),
                          if (r.text('archiveOperationId').isNotEmpty)
                            TextButton(
                              onPressed: () => context.go('/modules/archive'),
                              child: const Text('关联归档操作'),
                            ),
                          TextButton(
                            onPressed: () => runUi(context, () async {
                              if (await ltConfirm(
                                context,
                                title: '删除个人待办？',
                                message: '只删除这条个人计划，不执行关联任务或删除其文件。',
                              )) {
                                await ref
                                    .read(timelineServiceProvider)
                                    .remove(r, confirmed: true);
                              }
                            }),
                            child: const Text('删除待办'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
  }
}
