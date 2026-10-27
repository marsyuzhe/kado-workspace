import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/data_mutation_gate.dart';

const reminderSetting = 'timeline.reminders.enabled';

class TimelineReminderService {
  TimelineReminderService(this.store);
  final RecordStore store;
  Stream<List<ToolRecord>> watchPending() => store.db
      .customSelect(
        "SELECT notice.* FROM local_records notice JOIN local_records task ON task.id=json_extract(notice.data,'\$.taskId') WHERE notice.kind='personal_reminder' AND notice.deleted_at IS NULL AND json_extract(notice.data,'\$.status')='pending' AND task.kind='personal_todo' AND task.deleted_at IS NULL AND json_extract(task.data,'\$.status')!='done' AND json_extract(task.data,'\$.reminderAt')=json_extract(notice.data,'\$.scheduledAt') ORDER BY json_extract(notice.data,'\$.scheduledAt') LIMIT 101",
        readsFrom: {store.db.localRecords},
      )
      .watch()
      .map(
        (rows) => rows
            .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
            .toList(),
      );
  Future<List<ToolRecord>> poll(DateTime now) async {
    if (await store.setting(reminderSetting) != 'true') return [];
    return DataMutationGate.shared.run(
      () => store.transaction(() async {
        final notices = <ToolRecord>[];
        final candidates = await store.db
            .customSelect(
              "SELECT id,title,json_extract(data,'\$.reminderAt') AS scheduled FROM local_records WHERE kind='personal_todo' AND deleted_at IS NULL AND json_extract(data,'\$.status')!='done' AND json_extract(data,'\$.reminderAt') IS NOT NULL AND json_extract(data,'\$.reminderAt')!='' ORDER BY json_extract(data,'\$.reminderAt') LIMIT 10000",
              readsFrom: {store.db.localRecords},
            )
            .get();
        for (final row in candidates) {
          final raw = row.read<String>('scheduled'),
              scheduled = DateTime.tryParse(raw);
          if (scheduled == null || scheduled.isAfter(now)) continue;
          final id = row.read<String>('id'),
              key = '$id|${scheduled.toUtc().toIso8601String()}';
          if (await store.find('personal_reminder', 'reminderKey', key) !=
              null) {
            continue;
          }
          notices.add(
            await store.create(
              'personal_reminder',
              row.read<String>('title'),
              data: {
                'payloadVersion': 1,
                'taskId': id,
                'scheduledAt': raw,
                'reminderKey': key,
                'firedAt': now.toUtc().toIso8601String(),
                'status': 'pending',
                'channel': 'in-app',
                'syncAllowed': false,
                'isSensitive': true,
              },
            ),
          );
          if (notices.length >= 100) break;
        }
        return notices;
      }),
    );
  }

  Future<void> acknowledge(ToolRecord row) async {
    if (row.kind != 'personal_reminder') {
      throw const ToolFailure('提醒记录无效。');
    }
    await DataMutationGate.shared.run(() async {
      final latest = await store.get(row.id);
      if (latest == null || latest.text('status') != 'pending') return;
      await store.save(
        latest.copyWith(
          data: {
            ...latest.data,
            'status': 'acknowledged',
            'acknowledgedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
    });
  }
}
