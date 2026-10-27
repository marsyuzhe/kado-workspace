import '../../core/data/tool_record.dart';
import '../utilities/civil_time.dart';

/// A local, typed proposal. Constructing it never writes a personal todo.
class StudioTimelineDraft {
  StudioTimelineDraft(
    this.title,
    this.description,
    this.zone,
    this.due,
    this.projectId,
    this.tags,
  );
  final String title, description, zone, projectId;
  final DateTime? due;
  final List<String> tags;
  factory StudioTimelineDraft.fromTask(ToolRecord task) {
    final input = Map<String, dynamic>.from(
          task.data['inputReferences'] as Map,
        ),
        title = (input['todoTitle'] as String? ?? task.title).trim(),
        description = (input['query'] as String? ?? '').trim(),
        zone = (input['timeZone'] as String? ?? 'Asia/Shanghai').trim(),
        date = (input['todoDue'] as String? ?? '').trim(),
        project = (input['projectId'] as String? ?? '').trim(),
        tags = (input['tags'] as List? ?? [])
            .cast<String>()
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList();
    if (title.isEmpty ||
        title.length > 300 ||
        description.length > 20000 ||
        tags.length > 30 ||
        tags.any((v) => v.length > 50)) {
      throw const ToolFailure('个人待办草稿的标题、说明或标签超出限制。');
    }
    CivilTime.location(zone);
    return StudioTimelineDraft(
      title,
      description,
      zone,
      date.isEmpty ? null : CivilTime.parse(date, zone),
      project,
      tags,
    );
  }
  Map<String, dynamic> get json => {
    'title': title,
    'description': description,
    'timeZone': zone,
    'dueAt': due?.toIso8601String() ?? '',
    'projectId': projectId,
    'tags': tags,
  };
  String get markdown =>
      '# 待审核的个人待办\n\n标题：$title\n\n截止：${due == null ? '未设置' : CivilTime.format(due!, zone)}\n\n时区：$zone\n\n项目：${projectId.isEmpty ? '不关联' : projectId}\n\n标签：${tags.join(' / ')}\n\n说明：\n$description\n\n点击“通过并创建个人待办”后才写入一条个人计划；不会运行Agent、执行归档操作或修改原始文件。';
}
