import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:csv/csv.dart';

import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';
import '../hub/hub_repository.dart';

export 'timeline_service.dart';

class BookmarkInput {
  const BookmarkInput(
    this.title,
    this.url, {
    this.description = '',
    this.category = '网页',
    this.tags = const [],
    this.favorite = false,
    this.source = 'manual',
  });
  final String title, url, description, category;
  final List<String> tags;
  final bool favorite;
  final String source;
  void validate() {
    TargetAction('url', url).validate();
    if (title.trim().isEmpty ||
        title.length > 300 ||
        description.length > 4000 ||
        tags.length > 30 ||
        tags.any((t) => t.length > 80) ||
        category.length > 100 ||
        source.length > 100) {
      throw const ToolFailure('标题、描述或标签数量超出限制。');
    }
  }
}

class BookmarkService {
  BookmarkService(this.hub);
  final HubRepository hub;
  Future<ToolRecord> save(BookmarkInput input, {ToolRecord? existing}) async {
    input.validate();
    return hub.store.transaction(() async {
      final duplicate = await hub.store.find(
        'favorite',
        'targetKey',
        TargetAction('url', input.url).key,
      );
      if (existing == null && duplicate != null) return duplicate;
      if (existing != null &&
          duplicate != null &&
          duplicate.id != existing.id) {
        throw const ToolFailure('此网址已收藏，请编辑已有记录。');
      }
      final record =
          existing ??
          await hub.addFavorite(
            input.title,
            TargetAction('url', input.url),
            category: input.category,
          );
      final oldAction = Map<String, dynamic>.from(record.data['action'] as Map);
      if (oldAction['type'] != 'url') throw const ToolFailure('只能在网页工具编辑网址收藏。');
      return hub.store.save(
        record.copyWith(
          title: input.title,
          body: input.description,
          data: {
            ...record.data,
            'action': TargetAction('url', input.url).toJson(),
            'targetKey': TargetAction('url', input.url).key,
            'category': input.category,
            'tags': input.tags.toSet().toList(),
            'payloadVersion': 1,
            'favorite': input.favorite,
            'source': input.source,
            ...githubMetadata(input.url),
          },
        ),
      );
    });
  }

  List<BookmarkInput> previewImport(String source) {
    if (utf8.encode(source).length > 2 * 1024 * 1024) {
      throw const ToolFailure('书签文件最多2MB。');
    }
    final document = html.parse(source), result = <BookmarkInput>[];
    for (final link in document.querySelectorAll('a[href]')) {
      if (result.length >= 1000) throw const ToolFailure('单次最多导入1000个书签，请分批。');
      final url = link.attributes['href'] ?? '';
      try {
        TargetAction('url', url).validate();
      } on ToolFailure {
        continue;
      }
      final title = link.text.trim();
      if (title.isEmpty) continue;
      final input = BookmarkInput(
        title,
        url,
        description: link.attributes['data-description'] ?? '',
        category: link.attributes['data-category'] ?? '导入书签',
        tags: (link.attributes['tags'] ?? '')
            .split(',')
            .where((s) => s.trim().isNotEmpty)
            .toList(),
      );
      input.validate();
      result.add(input);
    }
    return result;
  }

  static Map<String, String> githubMetadata(String url) {
    final uri = Uri.parse(url), parts = Uri.parse(url).pathSegments;
    if (uri.host.toLowerCase() != 'github.com' ||
        parts.length < 2 ||
        parts[0].isEmpty ||
        parts[1].isEmpty) {
      return {};
    }
    return {
      'repositoryOwner': parts[0],
      'repositoryName': parts[1].replaceFirst(RegExp(r'\.git$'), ''),
    };
  }

  List<BookmarkInput> previewStructured(String source, String format) {
    if (utf8.encode(source).length > 2 * 1024 * 1024) {
      throw const ToolFailure('导入文件最多2MB。');
    }
    try {
      final List<dynamic> entries;
      if (format == 'json') {
        final decoded = jsonDecode(source);
        entries = decoded is List
            ? decoded
            : (decoded as Map)['bookmarks'] as List;
      } else if (format == 'csv') {
        final rows = csv.decode(source.replaceFirst('\ufeff', ''));
        if (rows.isEmpty) return [];
        final header = rows.first.map((v) => v.toString()).toList();
        if (!header.contains('title') || !header.contains('url')) {
          throw const FormatException();
        }
        entries = [
          for (final row in rows.skip(1))
            if (row.any((v) => v.toString().isNotEmpty))
              {
                for (var i = 0; i < header.length; i++)
                  header[i]: i < row.length ? row[i].toString() : '',
              },
        ];
      } else {
        throw const ToolFailure('仅支持JSON或CSV。');
      }
      if (entries.length > 1000) throw const ToolFailure('单次最多1000个书签。');
      final result = <BookmarkInput>[];
      for (final raw in entries) {
        final row = raw as Map;
        String text(String key) {
          final value = (row[key] ?? '').toString();
          return format == 'csv' &&
                  value.startsWith("'") &&
                  (value.substring(1).startsWith("'") ||
                      RegExp(r'^[\s]*[=+@\-]').hasMatch(value.substring(1)))
              ? value.substring(1)
              : value;
        }

        final tags = row['tags'];
        final input = BookmarkInput(
          text('title'),
          text('url'),
          description: text('description'),
          category: text('category').isEmpty ? '导入书签' : text('category'),
          tags: tags is List
              ? tags.map((v) => v.toString()).toList()
              : text('tags').startsWith('[')
              ? (jsonDecode(text('tags')) as List)
                    .map((v) => v.toString())
                    .toList()
              : text('tags').split('|').where((v) => v.isNotEmpty).toList(),
          favorite: text('favorite') == 'true',
          source: 'import-$format',
        );
        input.validate();
        result.add(input);
      }
      return result;
    } on ToolFailure {
      rethrow;
    } catch (_) {
      throw const ToolFailure('书签格式无效；需要title、url和有效HTTP/HTTPS网址。');
    }
  }

  String exportStructured(List<ToolRecord> records, String format) {
    final rows = <Map<String, dynamic>>[];
    for (final r in records) {
      final action = r.data['action'] as Map;
      if (action['type'] != 'url') continue;
      rows.add({
        'title': r.title,
        'url': action['target'],
        'description': r.body,
        'category': r.text('category'),
        'tags': r.strings('tags'),
        'favorite': r.flag('favorite'),
        'createdAt': r.createdAt.toIso8601String(),
        'updatedAt': r.updatedAt.toIso8601String(),
        'lastOpenedAt': r.text('lastOpenedAt'),
        'source': r.text('source'),
      });
    }
    if (format == 'json') {
      return const JsonEncoder.withIndent('  ')
          .convert({'version': 1, 'bookmarks': rows});
    }
    if (format != 'csv') throw const ToolFailure('仅支持JSON或CSV。');
    final headers = [
      'title',
      'url',
      'description',
      'category',
      'tags',
      'favorite',
      'createdAt',
      'updatedAt',
      'lastOpenedAt',
      'source',
    ];
    // A reversible apostrophe guard prevents spreadsheet formula execution.
    String safe(String value) =>
        value.startsWith("'") || RegExp(r'^[\s]*[=+@\-]').hasMatch(value)
        ? "'$value"
        : value;
    return '\ufeff${csv.encode([
      headers,
      for (final row in rows) [for (final h in headers) safe(h == 'tags' ? jsonEncode(row[h]) : row[h].toString())],
    ])}';
  }

  Future<void> setFavorite(List<String> ids, bool value) =>
      hub.store.transaction(() async {
        for (final id in ids.toSet()) {
          final row = await hub.store.get(id);
          if (row?.kind != 'favorite' ||
              (row!.data['action'] as Map)['type'] != 'url') {
            throw const ToolFailure('网页收藏已变化，请重新选择。');
          }
          await hub.store.save(
            row.copyWith(data: {...row.data, 'favorite': value}),
          );
        }
      });
  Future<void> removeAll(List<String> ids, {required bool confirmed}) async {
    if (!confirmed) throw const ToolFailure('批量删除需要确认。');
    await hub.store.transaction(() async {
      for (final id in ids.toSet()) {
        final row = await hub.store.get(id);
        if (row?.kind != 'favorite' ||
            (row!.data['action'] as Map)['type'] != 'url') {
          throw const ToolFailure('网页收藏已变化，请重新选择。');
        }
        await hub.removeFavorite(row);
      }
    });
  }

  Future<void> recordOpened(String id) async {
    final row = await hub.store.get(id);
    if (row?.kind != 'favorite') return;
    await hub.store.save(
      row!.copyWith(
        data: {
          ...row.data,
          'lastOpenedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<int> importConfirmed(
    List<BookmarkInput> preview, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw const ToolFailure('导入需要预览并确认。');
    if (preview.length > 1000) throw const ToolFailure('单次最多1000个书签。');
    return hub.store.transaction(() async {
      for (final item in preview) {
        await save(item);
      }
      return preview.length;
    });
  }

  String export(List<ToolRecord> records) {
    const esc = HtmlEscape(HtmlEscapeMode.attribute);
    final out = StringBuffer(
      '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">\n<TITLE>Links Bookmarks</TITLE>\n<DL><p>\n',
    );
    for (final record in records) {
      final action = Map<String, dynamic>.from(record.data['action'] as Map);
      if (action['type'] != 'url') continue;
      out.writeln(
        '<DT><A HREF="${esc.convert(action['target'] as String)}" DATA-CATEGORY="${esc.convert(record.text('category'))}" DATA-DESCRIPTION="${esc.convert(record.body)}" TAGS="${esc.convert(record.strings('tags').join(','))}">${esc.convert(record.title)}</A>',
      );
    }
    out.writeln('</DL><p>');
    return out.toString();
  }
}
