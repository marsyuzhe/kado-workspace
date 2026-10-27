import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';

const snippetLanguages = [
  'Shell',
  'PowerShell',
  'Python',
  'JavaScript',
  'TypeScript',
  'Dart',
  'Rust',
  'SQL',
  'Markdown',
  'Text',
];

/// Shares RecordStore/backup/FTS with Memory and Clipboard. Snippets are text
/// records only: there is deliberately no process executor or script permission.
class SnippetRepository {
  SnippetRepository(this.store);
  final RecordStore store;
  Future<ToolRecord> save(
    String name,
    String code, {
    String language = 'Text',
    String category = '',
    List<String> tags = const [],
    bool favorite = false,
    String sourceId = '',
    ToolRecord? existing,
  }) async {
    if (name.trim().isEmpty ||
        name.length > 200 ||
        code.length > 200000 ||
        code.isEmpty ||
        category.length > 100 ||
        tags.length > 30 ||
        tags.any((t) => t.length > 100) ||
        !snippetLanguages.contains(language) ||
        existing != null && existing.kind != 'dev_snippet') {
      throw const ToolFailure('片段名称、代码、语言或分类超过限制。');
    }
    final data = {
      'language': language,
      'category': category,
      'tags': tags.toSet().toList(),
      'favorite': favorite,
      'sourceId': sourceId,
      'syncAllowed': false,
      'isSensitive': true,
    };
    return existing == null
        ? store.create('dev_snippet', name, body: code, data: data)
        : store.save(existing.copyWith(title: name, body: code, data: data));
  }

  Future<List<ToolRecord>> search(
    String query, {
    bool favorites = false,
  }) async {
    final escaped = query
            .replaceAll('\\', '\\\\')
            .replaceAll('%', r'\%')
            .replaceAll('_', r'\_'),
        pattern = '%$escaped%';
    final rows = await store.db
        .customSelect(
          "SELECT * FROM local_records WHERE kind='dev_snippet' AND deleted_at IS NULL "
          "AND (?=0 OR json_extract(data,'\$.favorite')=1) AND (title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\' OR data LIKE ? ESCAPE '\\') ORDER BY updated_at DESC LIMIT 200",
          variables: [
            Variable(favorites ? 1 : 0),
            Variable(pattern),
            Variable(pattern),
            Variable(pattern),
          ],
          readsFrom: {store.db.localRecords},
        )
        .get();
    return rows
        .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
        .toList();
  }

  Future<int> importJson(String text) async {
    if (text.length > 2 * 1024 * 1024) throw const ToolFailure('导入超过2MiB。');
    final root = jsonDecode(text) as Map;
    if (root['format'] != 'kado-snippets' ||
        root['version'] != 1 ||
        root['items'] is! List ||
        (root['items'] as List).length > 1000) {
      throw const ToolFailure('片段文件格式无效。');
    }
    final items = (root['items'] as List).cast<Map>();
    return store.transaction(() async {
      for (final row in items) {
        await save(
          row['name'] as String,
          row['code'] as String,
          language: row['language'] as String? ?? 'Text',
          category: row['category'] as String? ?? '',
          tags: (row['tags'] as List? ?? []).cast<String>(),
          favorite: row['favorite'] == true,
        );
      }
      return items.length;
    });
  }

  Future<String> exportAll() => store.transaction(() async {
    final stats = await store.db
        .customSelect(
          "SELECT COUNT(*) AS n,COALESCE(SUM(length(CAST(body AS BLOB))+length(CAST(title AS BLOB))+length(CAST(data AS BLOB))),0) AS bytes FROM local_records WHERE kind='dev_snippet' AND deleted_at IS NULL",
        )
        .getSingle();
    if (stats.read<int>('n') > 1000 ||
        stats.read<int>('bytes') > 2 * 1024 * 1024) {
      throw const ToolFailure('全部导出超过1000条或2MiB，请筛选后导出当前结果。');
    }
    return exportJson(await store.list('dev_snippet', limit: 1000));
  });
  String exportJson(List<ToolRecord> records) {
    if (records.length > 1000 ||
        records.fold<int>(0, (n, r) => n + r.body.length + r.title.length) >
            2 * 1024 * 1024) {
      throw const ToolFailure('导出超过1000条或2MiB。');
    }
    final result = const JsonEncoder.withIndent('  ').convert({
      'format': 'kado-snippets',
      'version': 1,
      'items': [
        for (final r in records)
          {
            'name': r.title,
            'code': r.body,
            'language': r.text('language'),
            'category': r.text('category'),
            'tags': r.strings('tags'),
            'favorite': r.flag('favorite'),
          },
      ],
    });
    if (utf8.encode(result).length > 2 * 1024 * 1024) {
      throw const ToolFailure('导出JSON超过2MiB，请减少范围。');
    }
    return result;
  }
}
