import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/database/app_database.dart';
import '../../core/storage/data_mutation_gate.dart';
import 'civil_time.dart';
import 'timeline_recurrence.dart';

class PersonalTimeline {
  PersonalTimeline(this.store, {DateTime Function()? now})
    : clock = now ?? DateTime.now;
  final RecordStore store;
  final DateTime Function() clock;
  static const limit = 10000;
  SimpleSelectStatement<$LocalRecordsTable, LocalRecord> _query() =>
      store.db.select(store.db.localRecords)
        ..where((t) => t.kind.equals('personal_todo') & t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.asc(
            const CustomExpression<String>(
              "COALESCE(NULLIF(json_extract(data,'\$.dueAt'),''),NULLIF(json_extract(data,'\$.due'),''),'9999-12-31')",
            ),
          ),
          (t) => OrderingTerm.desc(t.updatedAt),
        ])
        ..limit(limit + 1);
  List<ToolRecord> _convert(Iterable<LocalRecord> rows) {
    final result = rows.map(ToolRecord.fromRow).toList();
    if (result.length > limit) {
      throw const ToolFailure('待办超过10000条安全上限，请导出或分期清理历史。');
    }
    return result;
  }

  Future<List<ToolRecord>> all() async => _convert(await _query().get());
  Stream<List<ToolRecord>> watch() => _query().watch().map(_convert);
  static DateTime? parseLocalDate(String input) {
    if (input.trim().isEmpty) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$')
        .firstMatch(input.trim());
    if (m == null) {
      throw const ToolFailure('请按 YYYY-MM-DD HH:MM 填写本地截止时间。');
    }
    final p = [for (var i = 1; i <= 5; i++) int.parse(m[i]!)],
        date = DateTime(
          int.parse(m[1]!),
          int.parse(m[2]!),
          int.parse(m[3]!),
          int.parse(m[4]!),
          int.parse(m[5]!),
        );
    if (date.year != p[0] ||
        date.month != p[1] ||
        date.day != p[2] ||
        date.hour != p[3] ||
        date.minute != p[4]) {
      throw const ToolFailure('日期或时间不存在。');
    }
    return date;
  }

  Future<void> _reference(String id, String kind) async {
    if (id.isNotEmpty && (await store.get(id))?.kind != kind) {
      throw const ToolFailure('关联的项目、Agent任务或归档操作已不存在。');
    }
  }

  Future<ToolRecord> save(
    String title, {
    String description = '',
    String projectId = '',
    DateTime? due,
    int priority = 1,
    ToolRecord? existing,
    DateTime? startAt,
    DateTime? reminderAt,
    String? timeZone,
    String? recurrenceRule,
    List<String>? tags,
    String? studioTaskId,
    String? archiveOperationId,
    bool replaceScheduling = false,
  }) async {
    final zone =
            timeZone ??
            existing?.text('timeZone', 'Asia/Shanghai') ??
            'Asia/Shanghai',
        rule =
            recurrenceRule ??
            existing?.text('recurrenceRule', 'none') ??
            'none',
        labels = tags ?? existing?.strings('tags') ?? [];
    final start =
            startAt ??
            (!replaceScheduling
                ? DateTime.tryParse(existing?.text('startAt') ?? '')
                : null),
        reminder =
            reminderAt ??
            (!replaceScheduling
                ? DateTime.tryParse(existing?.text('reminderAt') ?? '')
                : null),
        agent = studioTaskId ?? existing?.text('studioTaskId') ?? '',
        archive =
            archiveOperationId ?? existing?.text('archiveOperationId') ?? '';
    if (title.trim().isEmpty ||
        title.length > 300 ||
        description.length > 20000 ||
        priority < 0 ||
        priority > 3 ||
        labels.length > 30 ||
        labels.any((v) => v.length > 50) ||
        existing != null && existing.kind != 'personal_todo') {
      throw const ToolFailure('个人待办标题、说明、标签或优先级无效。');
    }
    CivilTime.location(zone);
    if (!recurrenceLabels.containsKey(rule) || rule != 'none' && due == null) {
      throw const ToolFailure('重复任务需要截止时间，并明确选择每天、每周或每月。');
    }
    if (due != null && start != null && start.isAfter(due) ||
        due != null && reminder != null && reminder.isAfter(due)) {
      throw const ToolFailure('开始时间和提醒时间不能晚于截止时间。');
    }
    for (final date in [due, start, reminder].whereType<DateTime>()) {
      if (date.year < 1900 || date.year > 2200) {
        throw const ToolFailure('待办日期超出1900–2200支持范围。');
      }
    }
    await _reference(projectId, 'project');
    await _reference(agent, 'studio_task');
    await _reference(archive, 'archive_operation');
    final dueText = due?.toUtc().toIso8601String() ?? '',
        reset =
            existing == null ||
            dueText != _dueText(existing) ||
            zone != existing.text('timeZone', 'Asia/Shanghai') ||
            rule != existing.text('recurrenceRule', 'none') ||
            rule != 'none' && existing.text('recurrenceAnchor').isEmpty;
    final data = {
      ...existing?.data ?? {},
      'payloadVersion': 2,
      'projectId': projectId,
      'due': dueText,
      'dueAt': dueText,
      'startAt': start?.toUtc().toIso8601String() ?? '',
      'reminderAt': reminder?.toUtc().toIso8601String() ?? '',
      'timeZone': zone,
      'recurrenceRule': rule,
      'recurrenceAnchor': reset
          ? dueText
          : existing.text('recurrenceAnchor', dueText),
      'recurrenceRootId': reset
          ? (existing?.id ?? '')
          : existing.text('recurrenceRootId'),
      'recurrenceIndex': reset ? 0 : existing.number('recurrenceIndex'),
      if (reset) 'nextOccurrenceId': '',
      if (reset) 'nextOccurrenceKey': '',
      'priority': priority,
      'tags': labels
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
      'studioTaskId': agent,
      'archiveOperationId': archive,
      'status': existing?.text('status') ?? 'todo',
      'executionMode': 'personal',
      'syncAllowed': false,
      'isSensitive': true,
    };
    return DataMutationGate.shared.run(() async {
      if (existing == null && (await all()).length >= limit) {
        throw const ToolFailure('个人待办已达到10000条上限。');
      }
      return existing == null
          ? store.create('personal_todo', title, body: description, data: data)
          : store.save(
              existing.copyWith(title: title, body: description, data: data),
            );
    });
  }

  Future<void> setState(ToolRecord record, String state) async {
    if (record.kind != 'personal_todo' ||
        !{'todo', 'doing', 'done'}.contains(state)) {
      throw const ToolFailure('个人待办状态无效。');
    }
    await DataMutationGate.shared.run(
      () => store.transaction(() async {
        final current = await store.get(record.id);
        if (current?.kind != 'personal_todo') {
          throw const ToolFailure('个人待办已不存在。');
        }
        if (current!.text('status') == 'done' && state == 'done') return;
        if (current.revision != record.revision) {
          throw const RecordConflict();
        }
        final saved = await store.save(
          current.copyWith(
            data: {
              ...current.data,
              'status': state,
              'completedAt': state == 'done'
                  ? clock().toUtc().toIso8601String()
                  : '',
            },
          ),
        );
        final rule = current.text('recurrenceRule', 'none');
        if (state != 'done' || rule == 'none') return;
        if (current.text('nextOccurrenceId').isNotEmpty &&
            await store.get(current.text('nextOccurrenceId')) != null) {
          return;
        }
        final anchor = DateTime.tryParse(
              current.text('recurrenceAnchor', _dueText(current)),
            ),
            oldDue = due(current)?.toUtc();
        if (anchor == null || oldDue == null) {
          throw const ToolFailure('重复待办缺少有效日期，请编辑修复。');
        }
        final next = TimelineRecurrence.next(
              anchor,
              current.number('recurrenceIndex'),
              current.text('timeZone', 'Asia/Shanghai'),
              rule,
              clock().toUtc(),
            ),
            root = current.text('recurrenceRootId').isEmpty
                ? current.id
                : current.text('recurrenceRootId'),
            key =
                '$root|${anchor.toUtc().toIso8601String()}|$rule|${current.text('timeZone', 'Asia/Shanghai')}|${next.index}';
        if (current.text('nextOccurrenceKey') == key ||
            await store.find('personal_todo', 'occurrenceKey', key) != null) {
          return;
        }
        if ((await all()).length >= limit) {
          throw const ToolFailure('生成下一次待办将超过10000条，请先清理历史或关闭重复规则。');
        }
        String shifted(String field) {
          final old = DateTime.tryParse(current.text(field));
          return old == null
              ? ''
              : next.due
                    .subtract(oldDue.difference(old))
                    .toUtc()
                    .toIso8601String();
        }

        final child = await store.create(
          'personal_todo',
          current.title,
          body: current.body,
          data: {
            ...current.data,
            'payloadVersion': 2,
            'status': 'todo',
            'completedAt': '',
            'due': next.due.toIso8601String(),
            'dueAt': next.due.toIso8601String(),
            'startAt': shifted('startAt'),
            'reminderAt': shifted('reminderAt'),
            'recurrenceAnchor': anchor.toUtc().toIso8601String(),
            'recurrenceRootId': root,
            'recurrenceIndex': next.index,
            'occurrenceKey': key,
            'nextOccurrenceId': '',
            'nextOccurrenceKey': '',
            'parentOccurrenceId': current.id,
          },
        );
        await store.save(
          saved.copyWith(
            data: {
              ...saved.data,
              'nextOccurrenceId': child.id,
              'nextOccurrenceKey': key,
              'recurrenceSkipped': next.skipped,
            },
          ),
        );
      }),
    );
  }

  Future<void> remove(ToolRecord row, {required bool confirmed}) async {
    if (!confirmed || row.kind != 'personal_todo') {
      throw const ToolFailure('删除个人待办需要确认。');
    }
    await store.delete(row);
  }

  static String _dueText(ToolRecord row) =>
      row.text('dueAt').isEmpty ? row.text('due') : row.text('dueAt');
  static DateTime? due(ToolRecord row) =>
      DateTime.tryParse(_dueText(row))?.toLocal();
  static bool overdue(ToolRecord row, DateTime now) =>
      row.text('status') != 'done' && (due(row)?.isBefore(now) ?? false);
}
