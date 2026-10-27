import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/features/utilities/civil_time.dart';
import 'package:links_toolbox/features/utilities/timeline_recurrence.dart';
import 'package:links_toolbox/features/utilities/timeline_service.dart';
import 'package:links_toolbox/features/utilities/timeline_reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late AppDatabase db;
  late RecordStore store;
  final now = DateTime.utc(2026, 10, 25, 4);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lt-timeline-test-');
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test('Calendar recurrence preserves anchor day, leap year and IANA DST civil time', () {
    final a = CivilTime.parse('2027-01-31 09:00', 'Asia/Shanghai');
    expect(
      CivilTime.format(
        TimelineRecurrence.occurrence(a, 1, 'Asia/Shanghai', 'monthly'),
        'Asia/Shanghai',
      ),
      '2027-02-28 09:00:00',
    );
    expect(
      CivilTime.format(
        TimelineRecurrence.occurrence(a, 2, 'Asia/Shanghai', 'monthly'),
        'Asia/Shanghai',
      ),
      '2027-03-31 09:00:00',
    );
    expect(
      CivilTime.format(
        TimelineRecurrence.occurrence(
          CivilTime.parse('2028-01-31 09:00', 'Asia/Shanghai'),
          1,
          'Asia/Shanghai',
          'monthly',
        ),
        'Asia/Shanghai',
      ),
      '2028-02-29 09:00:00',
    );
    final dst = CivilTime.parse('2026-03-07 02:30', 'America/New_York');
    expect(
      CivilTime.format(
        TimelineRecurrence.occurrence(dst, 1, 'America/New_York', 'daily'),
        'America/New_York',
      ),
      '2026-03-08 03:00:00',
    );
    expect(
      CivilTime.format(
        TimelineRecurrence.occurrence(dst, 2, 'America/New_York', 'daily'),
        'America/New_York',
      ),
      '2026-03-09 02:30:00',
    );
    final fall = CivilTime.parse('2026-10-31 01:30', 'America/New_York');
    final n = TimelineRecurrence.next(
      fall,
      0,
      'America/New_York',
      'daily',
      fall,
    );
    expect(n.index, 1);
    expect(CivilTime.format(n.due, 'America/New_York'), '2026-11-01 01:30:00');
    final skipped = TimelineRecurrence.next(
      a,
      0,
      'Asia/Shanghai',
      'monthly',
      CivilTime.parse('2027-05-31 12:00', 'Asia/Shanghai'),
    );
    expect(skipped.index, 5);
    expect(skipped.skipped, 4);
  });
  test('Completion creates one persistent future occurrence, reopen is idempotent and legacy edits preserve scheduling', () async {
    var clock = now;
    final service = PersonalTimeline(store, now: () => clock);
    final project = await store.create('project', 'Timeline QA project'),
        task = await store.create('studio_task', 'Reference only'),
        operation = await store.create('archive_operation', 'Reference only');
    final due = CivilTime.parse('2026-10-20 09:00', 'Asia/Shanghai');
    final row = await service.save(
      'Weekly QA',
      description: 'private',
      projectId: project.id,
      due: due,
      startAt: due.subtract(const Duration(hours: 2)),
      reminderAt: due.subtract(const Duration(minutes: 30)),
      timeZone: 'Asia/Shanghai',
      recurrenceRule: 'daily',
      tags: ['QA', 'QA'],
      studioTaskId: task.id,
      archiveOperationId: operation.id,
    );
    final edited = await service.save(
      'Weekly QA revised',
      existing: row,
      projectId: project.id,
      due: due,
    );
    expect(edited.text('reminderAt'), row.text('reminderAt'));
    expect(edited.strings('tags'), ['QA']);
    await service.setState(edited, 'done');
    await service.setState(edited, 'done');
    var rows = await service.all();
    expect(rows.length, 2);
    final child = rows.singleWhere((r) => r.id != edited.id),
        parent = (await store.get(edited.id))!;
    expect(
      CivilTime.format(PersonalTimeline.due(child)!, 'Asia/Shanghai'),
      '2026-10-26 09:00:00',
    );
    expect(parent.number('recurrenceSkipped'), 5);
    expect(
      child.text('reminderAt'),
      PersonalTimeline.due(child)!
          .subtract(const Duration(minutes: 30))
          .toUtc()
          .toIso8601String(),
    );
    await service.setState(parent, 'todo');
    clock = now.add(const Duration(days: 4));
    await service.setState((await store.get(parent.id))!, 'done');
    expect((await service.all()).length, 2);
    expect((await store.get(task.id))!.revision, task.revision);
    expect((await store.get(operation.id))!.revision, operation.revision);
    final cleared = await service.save(
      child.title,
      existing: child,
      due: PersonalTimeline.due(child),
      recurrenceRule: 'none',
      replaceScheduling: true,
    );
    expect(cleared.text('reminderAt'), '');
    expect(cleared.text('startAt'), '');
    await db.close();
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    expect((await PersonalTimeline(store).all()).length, 2);
    final legacy = await store.create(
      'personal_todo',
      'Old version',
      data: {'due': '2026-10-25T10:00:00.000Z', 'status': 'todo'},
    );
    expect(
      PersonalTimeline.due(legacy)!.toUtc(),
      DateTime.utc(2026, 10, 25, 10),
    );
    expect(
      () => PersonalTimeline(store).save('Bad reference', projectId: task.id),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('Local reminders opt in, persist, acknowledge once and hide deleted/completed/rescheduled tasks', () async {
    final service = PersonalTimeline(store),
        reminders = TimelineReminderService(store);
    final tasks = <ToolRecord>[];
    for (var i = 0; i < 10; i++) {
      tasks.add(
        await service.save(
          'Reminder QA $i',
          due: now,
          reminderAt: now.subtract(const Duration(minutes: 1)),
        ),
      );
    }
    await service.save(
      'Future QA',
      due: now.add(const Duration(days: 1)),
      reminderAt: now.add(const Duration(minutes: 10)),
    );
    expect(await reminders.poll(now), isEmpty);
    await store.setSetting(reminderSetting, 'true');
    expect((await reminders.poll(now)).length, 10);
    expect(await reminders.poll(now), isEmpty);
    var pending = await reminders.watchPending().first;
    expect(pending.length, 10);
    await reminders.acknowledge(pending.first);
    expect((await reminders.watchPending().first).length, 9);
    final ackId = pending.first.text('taskId'),
        others = tasks.where((t) => t.id != ackId).toList();
    await service.setState(others[0], 'done');
    await service.remove(others[1], confirmed: true);
    await service.save(
      others[2].title,
      existing: others[2],
      due: now.add(const Duration(days: 1)),
      reminderAt: now.add(const Duration(hours: 1)),
      replaceScheduling: true,
    );
    expect((await reminders.watchPending().first).length, 6);
    await db.close();
    db = AppDatabase.file(File('${temp.path}/links_toolbox.sqlite'));
    await db.initialize();
    store = RecordStore(db);
    final reopened = TimelineReminderService(store);
    expect(await reopened.poll(now), isEmpty);
    expect((await reopened.watchPending().first).length, 6);
    expect((await reopened.poll(now.add(const Duration(hours: 2)))).length, 2);
    await store.setSetting(reminderSetting, 'false');
    expect(await reopened.poll(now.add(const Duration(days: 1))), isEmpty);
  });
}
