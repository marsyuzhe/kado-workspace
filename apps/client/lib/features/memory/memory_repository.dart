import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/owned_file_store.dart';

const contextFiles = [
  'CONTEXT.md',
  'PROJECT.md',
  'DECISIONS.md',
  'LESSONS.md',
  'WORKFLOWS.md',
];

class NoteSummary {
  const NoteSummary(
    this.id,
    this.title,
    this.preview,
    this.data,
    this.updatedAt,
  );
  final String id, title, preview;
  final Map<String, dynamic> data;
  final DateTime updatedAt;
  String get projectId => data['projectId'] as String? ?? '';
  List<String> get tags =>
      (data['tags'] as List? ?? []).whereType<String>().toList();
  bool get pinned => data['pinned'] == true;
}

class MemoryRepository {
  MemoryRepository(this.store, this.files);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  static const maxNoteBytes = 1024 * 1024,
      maxAttachmentBytes = 25 * 1024 * 1024;
  Stream<List<NoteSummary>> watchSummaries({
    int limit = 2000,
    String searchQuery = '',
  }) => store.db
      .customSelect(
        "SELECT id,title,substr(body,1,160) AS preview,data,updated_at FROM local_records WHERE kind IN ('note','memory_prompt') AND deleted_at IS NULL AND instr(lower(title || char(10) || body),lower(?))>0 ORDER BY updated_at DESC,rowid DESC LIMIT ?",
        variables: [Variable(searchQuery), Variable(limit.clamp(1, 10000))],
        readsFrom: {store.db.localRecords},
      )
      .watch()
      .map(
        (rows) => rows
            .map(
              (r) => NoteSummary(
                r.read<String>('id'),
                r.read<String>('title'),
                r.read<String>('preview'),
                Map<String, dynamic>.from(
                  jsonDecode(r.read<String>('data')) as Map,
                ),
                DateTime.fromMillisecondsSinceEpoch(
                  r.read<int>('updated_at') * 1000,
                  isUtc: true,
                ),
              ),
            )
            .toList(),
      );
  Future<ToolRecord> project(
    String title, {
    String description = '',
    String stack = '',
    String progress = '',
    ToolRecord? existing,
  }) async {
    if (title.trim().isEmpty) throw const ToolFailure('项目名称不能为空。');
    final data = {
      ...existing?.data ?? {},
      'stack': stack,
      'progress': progress,
    };
    return existing == null
        ? store.create('project', title, body: description, data: data)
        : store.save(
            existing.copyWith(title: title, body: description, data: data),
          );
  }

  Future<void> deleteProject(ToolRecord project) async {
    final notes = await store.list('note', limit: 10000);
    await store.transaction(() async {
      for (final note in notes.where(
        (n) => n.text('projectId') == project.id,
      )) {
        await store.save(note.copyWith(data: {...note.data, 'projectId': ''}));
      }
      await store.delete(project);
    });
  }

  Future<ToolRecord> createNote(
    String title, {
    String body = '',
    String projectId = '',
    List<String> tags = const [],
    String category = 'CONTEXT.md',
    bool sensitive = false,
    String source = '',
  }) async {
    if (utf8.encode(body).length > maxNoteBytes) {
      throw const ToolFailure('单篇笔记正文上限1MB。');
    }
    if (!contextFiles.contains(category)) throw const ToolFailure('上下文类型无效。');
    final note = await store.create(
      'note',
      title.trim().isEmpty ? '未命名笔记' : title,
      body: body,
      data: {
        'projectId': projectId,
        'tags': tags,
        'category': category,
        'pinned': false,
        'isSensitive': sensitive,
        'source': source,
        'syncAllowed': false,
      },
    );
    return note;
  }

  Future<ToolRecord> saveNote(
    ToolRecord note, {
    required String title,
    required String body,
    Map<String, dynamic>? metadata,
  }) async {
    if (utf8.encode(body).length > maxNoteBytes) {
      throw const ToolFailure('单篇笔记正文上限1MB，草稿仍保留在编辑器中。');
    }
    final data = metadata ?? note.data;
    if (!contextFiles.contains(data['category'])) {
      throw const ToolFailure('上下文类型无效。');
    }
    return store.transaction(() async {
      final saved = await store.save(
        note.copyWith(
          title: title.trim().isEmpty ? '未命名笔记' : title,
          body: body,
          data: data,
        ),
      );
      for (final tag
          in saved
              .strings('tags')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet()) {
        if (await store.find('tag', 'name', tag) == null) {
          await store.create('tag', tag, data: {'name': tag});
        }
      }
      return saved;
    });
  }

  Future<void> removeNote(ToolRecord note) async {
    await store.transaction(() async {
      final links = await store.list('note_link', limit: 10000);
      for (final link in links.where(
        (r) => r.text('from') == note.id || r.text('to') == note.id,
      )) {
        await store.delete(link);
      }
      await store.delete(note);
    });
    for (final attachment in (await store.list(
      'attachment',
      limit: 10000,
    )).where((r) => r.text('noteId') == note.id)) {
      await removeAttachment(attachment);
    }
  }

  Future<ToolRecord> link(ToolRecord from, ToolRecord to) async {
    if (from.id == to.id) throw const ToolFailure('请选择另一篇笔记。');
    final key = '${from.id}:${to.id}';
    return store.transaction(() async {
      final old = await store.find('note_link', 'key', key);
      return old ??
          await store.create(
            'note_link',
            '${from.title} → ${to.title}',
            data: {'key': key, 'from': from.id, 'to': to.id},
          );
    });
  }

  Future<ToolRecord> attach(
    ToolRecord note,
    String name,
    Uint8List bytes,
  ) async {
    if (bytes.length > maxAttachmentBytes) {
      throw const ToolFailure('单个附件上限25MB。');
    }
    if (await store.get(note.id) == null) throw const ToolFailure('笔记已不存在。');
    final path = await (await files()).write('memory', bytes);
    try {
      return await store.create(
        'attachment',
        p.basename(name),
        data: {
          'noteId': note.id,
          'attachment': path,
          'size': bytes.length,
          'hash': sha256.convert(bytes).toString(),
        },
      );
    } catch (_) {
      await (await files()).remove(path);
      rethrow;
    }
  }

  Future<void> removeAttachment(ToolRecord attachment) async {
    await store.delete(attachment);
    await (await files()).remove(attachment.text('attachment'));
  }

  Future<ToolRecord> prompt(ToolRecord note) => store.create(
    'memory_prompt',
    note.title,
    body: note.body,
    data: {
      'projectId': note.text('projectId'),
      'category': note.text('category', 'CONTEXT.md'),
      'isTemplate': true,
      'tags': note.strings('tags'),
      'isSensitive': note.flag('isSensitive'),
      'syncAllowed': false,
    },
  );
  Future<Map<String, String>> contextPreview(
    ToolRecord project,
    Set<String> selected,
  ) async {
    final all = await store.list('note', limit: 10000);
    final notes = all
        .where(
          (r) =>
              r.text('projectId') == project.id &&
              selected.contains(r.id) &&
              !r.flag('isSensitive'),
        )
        .toList();
    if (notes.length != selected.length) {
      throw const ToolFailure('选择包含敏感、缺失或不属于此项目的笔记，请重新预览。');
    }
    final result = {
      for (final f in contextFiles)
        f: '# ${p.basenameWithoutExtension(f)} — ${project.title}\n\n',
    };
    result['PROJECT.md'] =
        '${result['PROJECT.md']}${project.body}\n\n## 技术栈\n${project.text('stack')}\n\n## 开发进度\n${project.text('progress')}\n\n';
    for (final note in notes) {
      final file = contextFiles.contains(note.text('category'))
          ? note.text('category')
          : 'CONTEXT.md';
      result[file] = '${result[file]}## ${note.title}\n\n${note.body}\n\n';
    }
    return Map.unmodifiable(result);
  }

  Future<ToolRecord> exportContext(
    ToolRecord project,
    Map<String, String> preview,
    Directory destination, {
    required bool confirmed,
  }) async {
    if (!confirmed ||
        preview.length != 5 ||
        !contextFiles.every(preview.containsKey)) {
      throw const ToolFailure('导出需要完整预览和确认。');
    }
    final created = <File>[];
    try {
      for (final entry in preview.entries) {
        final file = File(p.join(destination.path, entry.key));
        await file.create(exclusive: true);
        created.add(file);
        await file.writeAsString(entry.value, flush: true);
      }
      return await store.create(
        'context_export',
        '${project.title} 上下文导出',
        data: {
          'projectId': project.id,
          'directory': destination.path,
          'files': preview.keys.toList(),
          'hashes': {
            for (final e in preview.entries)
              e.key: sha256.convert(utf8.encode(e.value)).toString(),
          },
        },
      );
    } catch (_) {
      // Only newly created export files are rolled back; preexisting files are never touched.
      for (final file in created) {
        if (await file.exists()) await file.delete();
      }
      rethrow;
    }
  }
}

/// Serial autosaves use the latest revision; conflicts retain the UI draft.
class NoteEditorSession {
  NoteEditorSession(this.repository, this.record);
  final MemoryRepository repository;
  ToolRecord record;
  Future<void> _tail = Future.value();
  Future<ToolRecord> save(
    String title,
    String body,
    Map<String, dynamic> metadata,
  ) {
    final completer = Completer<ToolRecord>();
    _tail = _tail.then((_) async {
      try {
        record = await repository.saveNote(
          record,
          title: title,
          body: body,
          metadata: Map.of(metadata),
        );
        completer.complete(record);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> drain() => _tail;
}
