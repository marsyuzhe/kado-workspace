import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/memory/memory_repository.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late MemoryRepository repo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt-memory-');
    db = AppDatabase(NativeDatabase(File('${root.path}/db.sqlite')));
    await db.initialize();
    repo = MemoryRepository(RecordStore(db), () async => OwnedFileStore(root));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  test(
    'projects, Markdown, tags, links, search and reopen use real SQLite',
    () async {
      final project = await repo.project(
        '动画项目',
        description: '介绍',
        stack: 'Flutter',
        progress: '开发',
      );
      final one = await repo.createNote(
        '决策',
        body: '# 标题\n${'长文本' * 200}中文正文关键内容',
        projectId: project.id,
        category: 'DECISIONS.md',
      );
      final two = await repo.createNote(
        '工作流',
        body: '**粗体**\n- 列表',
        projectId: project.id,
      );
      final saved = await repo.saveNote(
        one,
        title: one.title,
        body: one.body,
        metadata: {
          ...one.data,
          'tags': ['动画', '开发'],
          'pinned': true,
        },
      );
      final link = await repo.link(saved, two);
      expect((await repo.link(saved, two)).id, link.id);
      expect((await repo.store.search('正文关键')).single.id, one.id);
      final summaries = await repo.watchSummaries(searchQuery: '正文关键').first;
      expect(summaries.single.id, one.id);
      expect(summaries.single.preview.length, 160);
      expect((await repo.store.list('tag')).length, 2);
      await db.close();
      db = AppDatabase(NativeDatabase(File('${root.path}/db.sqlite')));
      await db.initialize();
      repo = MemoryRepository(
        RecordStore(db),
        () async => OwnedFileStore(root),
      );
      expect((await repo.store.get(one.id))!.body, one.body);
      await repo.deleteProject((await repo.store.get(project.id))!);
      expect((await repo.store.get(one.id))!.text('projectId'), '');
    },
  );
  test(
    'serial saves retain newest content, external conflict does not overwrite',
    () async {
      final n = await repo.createNote('编辑');
      final session = NoteEditorSession(repo, n);
      await Future.wait([
        session.save('A', '一', n.data),
        session.save('B', '二', n.data),
      ]);
      expect(session.record.body, '二');
      expect(session.record.revision, 3);
      await repo.saveNote(session.record, title: '外部', body: '外部保存');
      await expectLater(
        session.save('草稿', '不丢失', n.data),
        throwsA(isA<RecordConflict>()),
      );
      expect((await repo.store.get(n.id))!.body, '外部保存');
    },
  );
  test('context preview excludes sensitive notes; five real files; collisions never overwrite', () async {
    final project = await repo.project('测试项目', description: '项目资料');
    final note = await repo.createNote(
      '决定',
      body: '使用本地数据库',
      projectId: project.id,
      category: 'DECISIONS.md',
    );
    final secret = await repo.createNote(
      '秘密',
      body: '敏感内容',
      projectId: project.id,
      sensitive: true,
    );
    await expectLater(
      repo.contextPreview(project, {secret.id}),
      throwsA(isA<ToolFailure>()),
    );
    final preview = await repo.contextPreview(project, {note.id});
    expect(preview.length, 5);
    expect(preview['DECISIONS.md'], contains('使用本地数据库'));
    expect(preview.values.join(), isNot(contains('敏感内容')));
    final out = await Directory('${root.path}/export').create();
    await repo.exportContext(project, preview, out, confirmed: true);
    for (final f in contextFiles) {
      expect(await File('${out.path}/$f').readAsString(), preview[f]);
    }
    await expectLater(
      repo.exportContext(project, preview, out, confirmed: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File('${out.path}/CONTEXT.md').readAsString(),
      preview['CONTEXT.md'],
    );
    expect((await repo.store.list('context_export')).length, 1);
  });
  test(
    'owned attachments and prompt templates have UUIDs and editable contents',
    () async {
      final n = await repo.createNote('资料', body: '提示词');
      final a = await repo.attach(
        n,
        'sample.txt',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await OwnedFileStore(root).resolve(a.text('attachment')).exists(),
        true,
      );
      final prompt = await repo.prompt(n);
      expect(prompt.id, isNot(n.id));
      final edited = await repo.saveNote(prompt, title: '模板', body: '编辑后的模板');
      expect(edited.body, '编辑后的模板');
      await repo.removeNote(n);
      expect(
        await OwnedFileStore(root).resolve(a.text('attachment')).exists(),
        false,
      );
      expect(await repo.store.get(n.id), null);
    },
  );
  test('oversize create and save cannot silently truncate Markdown', () async {
    await expectLater(
      repo.createNote('大笔记', body: 'x' * (MemoryRepository.maxNoteBytes + 1)),
      throwsA(isA<ToolFailure>()),
    );
    expect(await repo.store.list('note'), isEmpty);
  });
}
