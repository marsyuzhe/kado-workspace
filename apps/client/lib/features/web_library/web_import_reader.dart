import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../core/data/tool_record.dart';
import 'web_models.dart';

class WebImportCategory {
  const WebImportCategory(
    this.id,
    this.input, {
    this.originalPath = const [],
    this.isSystemPreset = false,
    this.userModified = false,
  });
  final bool isSystemPreset, userModified;
  final String id;
  final WebsiteCategoryInput input;
  final List<String> originalPath;
}

class WebImportSite {
  const WebImportSite(
    this.id,
    this.input, {
    this.order = 0,
    this.createdAt,
    this.lastVisitedAt,
    this.visitCount = 0,
    this.isSeeded = false,
    this.userModified = false,
    this.sourceType = "IMPORTED",
    this.iconBytes,
    this.originalPath = const [],
  });
  final String id;
  final WebsiteInput input;
  final int order, visitCount;
  final DateTime? createdAt, lastVisitedAt;
  final bool isSeeded, userModified;
  final String sourceType;
  final Uint8List? iconBytes;
  final List<String> originalPath;
}

class WebImportDraft {
  const WebImportDraft(
    this.categories,
    this.sites,
    this.errors,
    this.warnings, {
    this.fullSnapshot = false,
    this.duplicates = 0,
  });
  final List<WebImportCategory> categories;
  final List<WebImportSite> sites;
  final List<String> errors, warnings;
  final bool fullSnapshot;
  final int duplicates;
}

/// 只解析主动选择的本地文件；HTML不执行脚本、不请求图标或网页。
class WebImportReader {
  static const byteLimit = 20 * 1024 * 1024;
  static Future<WebImportDraft> read(Uint8List bytes, String format) async {
    if (bytes.isEmpty ||
        bytes.length > byteLimit ||
        !{'json', 'html', 'csv'}.contains(format)) {
      throw const ToolFailure('请选择非空JSON/HTML/CSV书签文件，最多20MiB。');
    }
    return Isolate.run(_ReadWebFile(bytes, format).call);
  }
}

class _ReadWebFile {
  _ReadWebFile(this.bytes, this.format);
  final Uint8List bytes;
  final String format;
  WebImportDraft call() {
    late String text;
    try {
      text = utf8.decode(bytes);
      if (text.startsWith('\ufeff')) text = text.substring(1);
    } on FormatException {
      throw const ToolFailure('书签文件需要UTF-8编码，请在浏览器重新导出。');
    }
    final builder = _ImportBuilder();
    try {
      switch (format) {
        case 'json':
          builder.json(text);
        case 'html':
          builder.htmlFile(text);
        case 'csv':
          builder.csvFile(text);
      }
      return builder.finish();
    } on ToolFailure {
      rethrow;
    } catch (_) {
      throw const ToolFailure('书签文件结构无效；原有网站未改变。');
    }
  }
}

class _ImportBuilder {
  final categories = <String, WebImportCategory>{};
  final paths = <String, String>{};
  final rawSites = <Map<String, dynamic>>[];
  final errors = <String>[], warnings = <String>[];
  bool fullSnapshot = false;
  static bool validId(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(value);
  static int integer(dynamic value, {int max = 1000000000}) {
    if (value == null || value == '') return 0;
    final result = value is int ? value : int.tryParse('$value');
    if (result == null || result < 0 || result > max) {
      throw const ToolFailure('顺序或访问次数需为有效非负整数。');
    }
    return result;
  }

  static bool flag(dynamic value) {
    if (value == null ||
        value == '' ||
        value == false ||
        value == 'false' ||
        value == '0') {
      return false;
    }
    if (value == true || value == 'true' || value == '1') return true;
    throw const ToolFailure('收藏或固定状态格式无效。');
  }

  static DateTime? date(dynamic value) {
    if (value == null || value == '') return null;
    if (value is! String) throw const ToolFailure('日期需为ISO时间文字。');
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
    ).firstMatch(value);
    if (match == null) throw const ToolFailure('日期需包含明确UTC或时区偏移。');
    final p = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)],
        civil = DateTime.utc(
          int.parse(match[1]!),
          int.parse(match[2]!),
          int.parse(match[3]!),
          int.parse(match[4]!),
          int.parse(match[5]!),
          int.parse(match[6]!),
        );
    final actual = [
      civil.year,
      civil.month,
      civil.day,
      civil.hour,
      civil.minute,
      civil.second,
    ];
    if (p[0] < 1900 ||
        p[0] > 2200 ||
        List.generate(6, (i) => p[i] == actual[i]).contains(false)) {
      throw const ToolFailure('日期不存在或超出支持范围。');
    }
    return DateTime.parse(value).toUtc();
  }

  String ensurePath(
    List<String> original, {
    String? id,
    String icon = 'folder',
    String color = '#8196BE',
    bool hidden = false,
    String description = '',
  }) {
    if (original.isEmpty) return uncategorizedId;
    final normalized = original.length <= 2
        ? original
        : [original.first, original.skip(1).join(' / ')];
    final pathKey = jsonEncode(normalized);
    if (paths.containsKey(pathKey)) return paths[pathKey]!;
    if (categories.length >= 16384) throw const ToolFailure('分类超过16384个上限。');
    final parent = normalized.length == 1 ? '' : ensurePath([normalized.first]);
    var label = normalized.last;
    if (label.length > 300) {
      label =
          '${label.substring(0, 285)}…${stableWebId('path-label', pathKey).substring(0, 8)}';
      warnings.add('过长分类名称使用短标签，完整来源路径已保留。');
    }
    if (original.length > 2) {
      warnings.add('深层目录在第二层合并显示，原始路径保留：${original.take(3).join(' / ')}');
    }
    final categoryId = id != null && validId(id)
        ? id.toLowerCase()
        : stableWebId('import-category', pathKey);
    final input = WebsiteCategoryInput(
      label,
      parentId: parent,
      iconKey: icon,
      color: color,
      isHidden: hidden,
      description: description,
      sortOrder: categories.length,
    );
    input.validate();
    if (categories.containsKey(categoryId)) {
      throw const ToolFailure('导入分类ID重复。');
    }
    categories[categoryId] = WebImportCategory(
      categoryId,
      input,
      originalPath: original,
    );
    paths[pathKey] = categoryId;
    return categoryId;
  }

  void addSite(Map<String, dynamic> row) {
    if (rawSites.length >= 10000) {
      throw const ToolFailure('单次最多10000个网站，请分批导入。');
    }
    rawSites.add(row);
  }

  void json(String source) {
    final decoded = jsonDecode(source);
    if (decoded is Map && decoded['schemaVersion'] == 2) {
      fullSnapshot = decoded['scope'] == 'all';
      final rows = decoded['categories'] as List;
      if (rows.length > 16384) throw const ToolFailure('分类超过16384个安全上限。');
      for (var i = 0; i < rows.length; i++) {
        try {
          final r = Map<String, dynamic>.from(rows[i] as Map),
              id = (r['id'] as String).toLowerCase(),
              parent = (r['parentId'] as String? ?? '').toLowerCase();
          if (!validId(id) ||
              parent.isNotEmpty && !validId(parent) ||
              categories.containsKey(id)) {
            throw const ToolFailure('分类UUID无效或重复。');
          }
          final input = WebsiteCategoryInput(
            r['name'] as String,
            description: r['description'] as String? ?? '',
            iconKey: r['iconKey'] as String? ?? 'folder',
            parentId: parent,
            color: r['color'] as String? ?? '#8196BE',
            isHidden: flag(r['isHidden']),
            sortOrder: integer(r['sortOrder'], max: 1000000),
          );
          input.validate();
          categories[id] = WebImportCategory(
            id,
            input,
            isSystemPreset: flag(r['isSystemPreset']),
            userModified: flag(r['userModified']),
          );
        } catch (_) {
          errors.add('分类第${i + 1}条无效，请检查名称、UUID和上级。');
        }
      }
      for (final r in decoded['websites'] as List) {
        addSite(Map<String, dynamic>.from(r as Map));
      }
    } else {
      final rows = decoded is List
          ? decoded
          : (decoded as Map)['bookmarks'] as List;
      for (final item in rows) {
        final r = Map<String, dynamic>.from(item as Map);
        r['categoryId'] = ensurePath([(r['category'] as String? ?? '未分类')]);
        r['isFavorite'] = r['favorite'];
        r['isPinned'] = r['pinned'];
        addSite(r);
      }
    }
  }

  void csvFile(String source) {
    final table = csv.decode(source);
    if (table.isEmpty) throw const ToolFailure('CSV没有表头。');
    final header = table.first.map((v) => '$v'.trim()).toList();
    if (!header.contains('title') || !header.contains('url')) {
      throw const ToolFailure('CSV需要title与url列，可从本应用导出模板。');
    }
    for (final values in table.skip(1)) {
      String field(String key) {
        final i = header.indexOf(key);
        return i < 0 || i >= values.length ? '' : '${values[i]}';
      }

      final pathText = field('categoryPath'),
          path = pathText.isEmpty
              ? [field('category').isEmpty ? '未分类' : field('category')]
              : (jsonDecode(pathText) as List).cast<String>();
      final tags = field('tags');
      addSite({
        'title': field('title'),
        'url': field('url'),
        'description': field('description'),
        'categoryId': ensurePath(path),
        'tags': tags.startsWith('[')
            ? jsonDecode(tags)
            : tags.split('|').where((s) => s.isNotEmpty).toList(),
        'isFavorite': field('isFavorite').isEmpty
            ? field('favorite')
            : field('isFavorite'),
        'isPinned': field('isPinned'),
        'sortOrder': rawSites.length,
      });
    }
  }

  void htmlFile(String source) {
    final doc = html.parse(source);
    final root = doc.querySelector('dl');
    if (root == null) {
      throw const ToolFailure('HTML未找到浏览器书签目录DL，请导出Netscape书签格式。');
    }
    _walk(root, []);
  }

  Map<String, dynamic>? _walk(
    Element parent,
    List<String> path, {
    Element? ignoredHeading,
  }) {
    List<String>? nextPath;
    Map<String, dynamic>? last;
    for (final child in parent.children) {
      final tag = child.localName;
      if (tag == 'dt') {
        final heading = child.children
            .where((e) => e.localName == 'h3')
            .firstOrNull;
        if (heading != null) {
          final folder = [...path, heading.text.trim()];
          ensurePath(folder, id: heading.attributes['data-kado-id']);
          _walk(child, folder, ignoredHeading: heading);
          nextPath = folder;
        } else {
          last = _walk(child, path) ?? last;
        }
      } else if (tag == 'dl') {
        _walk(child, nextPath ?? path);
        nextPath = null;
      } else if (tag == 'h3' && child != ignoredHeading) {
        nextPath = [...path, child.text.trim()];
        ensurePath(nextPath, id: child.attributes['data-kado-id']);
      } else if (tag == 'a') {
        final attrs = child.attributes;
        final categoryId = ensurePath(path);
        dynamic tags;
        try {
          tags = attrs['data-kado-tags'] == null
              ? (attrs['tags'] ?? '')
                    .split(',')
                    .where((v) => v.isNotEmpty)
                    .toList()
              : jsonDecode(attrs['data-kado-tags']!);
        } catch (_) {
          tags = [];
          warnings.add('有网站标签格式无法读取，已保留网址供核对。');
        }
        final row = <String, dynamic>{
          'id': attrs['data-kado-id'],
          'title': child.text.trim(),
          'url': attrs['href'] ?? '',
          'description': attrs['data-kado-description'] ?? '',
          'categoryId': categoryId,
          'tags': tags,
          'isFavorite': attrs['data-kado-favorite'],
          'isPinned': attrs['data-kado-pinned'],
          'sortOrder': rawSites.length,
          'originalPath': path,
        };
        addSite(row);
        last = row;
      } else if (tag == 'dd') {
        if (last != null) last['description'] = child.text.trim();
      } else if (tag != 'h3') {
        last = _walk(child, path) ?? last;
      }
    }
    return last;
  }

  WebImportDraft finish() {
    final invalidCategories = <String>{};
    for (final category in categories.values) {
      final parent = category.input.parentId;
      if (parent.isNotEmpty &&
          (parent == category.id ||
              !categories.containsKey(parent) ||
              categories[parent]!.input.parentId.isNotEmpty)) {
        errors.add('分类“${category.input.name}”存在循环、缺失上级或超过两层。');
        invalidCategories.add(category.id);
      }
    }
    categories.removeWhere((id, _) => invalidCategories.contains(id));
    final sites = <WebImportSite>[], ids = <String, String>{};
    var duplicates = 0;
    for (var i = 0; i < rawSites.length; i++) {
      try {
        final r = rawSites[i],
            url = normalizeWebsiteUrl(r['url'] as String),
            rawId = r['id'] as String?;
        final id = rawId == null || rawId.isEmpty
            ? stableWebId('import-site', url)
            : rawId.toLowerCase();
        if (!validId(id)) throw const ToolFailure('网站UUID无效。');
        if (ids.containsKey(id)) {
          if (ids[id] == url) {
            duplicates++;
            continue;
          }
          throw const ToolFailure('同一UUID对应不同网址。');
        }
        final category = (r['categoryId'] as String? ?? uncategorizedId)
            .toLowerCase();
        if (category != uncategorizedId && !categories.containsKey(category)) {
          throw const ToolFailure('网站关联的分类不在文件中。');
        }
        final input = WebsiteInput(
          r['title'] as String,
          url,
          description: r['description'] as String? ?? '',
          categoryId: category,
          tags: (r['tags'] as List? ?? []).cast<String>(),
          isFavorite: flag(r['isFavorite']),
          isPinned: flag(r['isPinned']),
          alternateUrl: r['alternateUrl'] as String? ?? '',
        );
        input.validate();
        Uint8List? icon;
        if (r['customIcon'] is Map) {
          final encoded = (r['customIcon'] as Map)['base64'] as String;
          if (encoded.length > 350000) {
            throw const ToolFailure('单个自定义图标超过256KiB。');
          }
          icon = base64.decode(encoded);
          if (icon.length > 256 * 1024) throw const ToolFailure('图标超过256KiB。');
        }
        ids[id] = url;
        sites.add(
          WebImportSite(
            id,
            input,
            order: integer(r['sortOrder'], max: 1000000),
            createdAt: date(r['createdAt']),
            lastVisitedAt: date(r['lastVisitedAt']),
            visitCount: integer(r['visitCount']),
            isSeeded: flag(r['isSeeded']),
            userModified: flag(r['userModified']),
            sourceType:
                {
                  'RECOMMENDED',
                  'USER_CONFIRMED',
                  'IMPORTED',
                }.contains(r['sourceType'])
                ? r['sourceType'] as String
                : 'IMPORTED',
            iconBytes: icon,
            originalPath: (r['originalPath'] as List? ?? []).cast<String>(),
          ),
        );
      } on ToolFailure catch (e) {
        errors.add('网站第${i + 1}条：${e.message}');
      } catch (_) {
        errors.add('网站第${i + 1}条字段格式无效。');
      }
    }
    return WebImportDraft(
      categories.values.toList(),
      sites,
      errors,
      warnings.toSet().toList(),
      fullSnapshot: fullSnapshot,
      duplicates: duplicates,
    );
  }
}
