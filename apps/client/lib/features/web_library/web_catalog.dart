import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/data/tool_record.dart';
import 'web_models.dart';

/// 版本化推荐目录。加载只读本地JSON，不访问网站，不把推荐标成个人常用。
class WebCatalog {
  const WebCatalog(this.version, this.categories, this.sites);
  final int version;
  final List<Map<String, dynamic>> categories, sites;
  static Future<WebCatalog> bundled() async =>
      parse(await rootBundle.loadString('assets/data/website_catalog.json'));
  static WebCatalog parse(String source) {
    if (utf8.encode(source).length > 2 * 1024 * 1024) {
      throw const ToolFailure('推荐目录超过2MiB。');
    }
    try {
      final json = jsonDecode(source) as Map;
      if (json['schemaVersion'] != 1 || json['catalogVersion'] is! int) {
        throw const FormatException();
      }
      final categories = (json['categories'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      final sites = (json['sites'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (categories.length > 256 || sites.length > 1000) {
        throw const FormatException();
      }
      final ids = <String>{};
      for (final row in categories) {
        if (!ids.add(row['id'] as String)) throw const FormatException();
        WebsiteCategoryInput(
          row['name'] as String,
          iconKey: row['iconKey'] as String,
          sortOrder: row['sortOrder'] as int,
          color: row['color'] as String,
        ).validate();
      }
      if (!ids.contains(uncategorizedId)) throw const FormatException();
      final categoryIds = ids.toSet();
      final urls = <String>{};
      for (final row in sites) {
        final url = WebsiteInput(
          row['title'] as String,
          row['url'] as String,
        ).validate();
        if (!urls.add(url) ||
            !categoryIds.contains(row['categoryId']) ||
            row['sourceType'] != 'RECOMMENDED') {
          throw const FormatException();
        }
        if (!ids.add(row['id'] as String)) throw const FormatException();
      }
      return WebCatalog(json['catalogVersion'] as int, categories, sites);
    } on ToolFailure {
      rethrow;
    } catch (_) {
      throw const ToolFailure('推荐目录版本、分类关系或网址无效，未改动收藏。');
    }
  }
}
