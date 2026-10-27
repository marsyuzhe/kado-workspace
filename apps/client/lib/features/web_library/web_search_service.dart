import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import 'web_models.dart';

const webViews = {
  'all': '全部网站',
  'personal': '我的网站',
  'favorite': '收藏',
  'pinned': '固定首页',
  'recent': '最近访问',
  'recommended': '已添加的推荐',
};
const webSorts = {
  'manual': '手动顺序',
  'name': '名称',
  'domain': '域名',
  'added': '最近添加',
  'visited': '最近访问',
};

class WebPageResult {
  const WebPageResult(this.items, this.total, this.offset, this.limit);
  final List<WebsiteBookmark> items;
  final int total, offset, limit;
  bool get hasMore => offset + items.length < total;
}

/// 只读本地搜索；不初始化种子、不抓网页。Agent与页面共用字段/权限边界。
class WebLibrarySearchService {
  WebLibrarySearchService(this.store);
  final RecordStore store;
  static const _from =
      "FROM local_records f LEFT JOIN local_records c ON c.id=json_extract(f.data,'\$.categoryId') AND c.kind='website_category' AND c.deleted_at IS NULL LEFT JOIN local_records parent ON parent.id=json_extract(c.data,'\$.parentId') AND parent.kind='website_category' AND parent.deleted_at IS NULL";
  static const _base =
      "f.kind='favorite' AND f.deleted_at IS NULL AND json_extract(f.data,'\$.action.type')='url'";
  ({String where, List<Variable> variables, String order}) _query(
    String text,
    String categoryId,
    String view,
    String sort,
    bool includeHidden,
  ) {
    if (text.length > 300 ||
        !webViews.containsKey(view) ||
        !webSorts.containsKey(sort)) {
      throw const ToolFailure('搜索词过长或筛选/排序方式无效。');
    }
    final clauses = <String>[_base], variables = <Variable>[];
    if (!includeHidden) {
      clauses.add(
        "COALESCE(json_extract(c.data,'\$.isHidden'),0)=0 AND COALESCE(json_extract(parent.data,'\$.isHidden'),0)=0",
      );
    }
    if (categoryId.isNotEmpty) {
      clauses.add(
        "(json_extract(f.data,'\$.categoryId')=? OR json_extract(c.data,'\$.parentId')=?)",
      );
      variables.addAll([Variable(categoryId), Variable(categoryId)]);
    }
    if (text.trim().isNotEmpty) {
      clauses.add(
        "instr(lower(f.title||char(10)||f.body||char(10)||COALESCE(json_extract(f.data,'\$.action.target'),'')||char(10)||COALESCE(json_extract(f.data,'\$.tags'),'')||char(10)||COALESCE(c.title,json_extract(f.data,'\$.category'),'')||char(10)||COALESCE(parent.title,'')||char(10)||COALESCE(json_extract(f.data,'\$.legacyCategoryName'),'')),lower(?))>0",
      );
      variables.add(Variable(text.trim()));
    }
    switch (view) {
      case 'favorite':
        clauses.add("json_extract(f.data,'\$.favorite')=1");
      case 'pinned':
        clauses.add("json_extract(f.data,'\$.pinned')=1");
      case 'recent':
        clauses.add("COALESCE(json_extract(f.data,'\$.lastVisitedAt'),'')!=''");
      case 'recommended':
        clauses.add("json_extract(f.data,'\$.sourceType')='RECOMMENDED'");
      case 'personal':
        clauses.add(
          "(COALESCE(json_extract(f.data,'\$.sourceType'),'USER_CONFIRMED')!='RECOMMENDED' OR json_extract(f.data,'\$.userModified')=1 OR json_extract(f.data,'\$.favorite')=1 OR json_extract(f.data,'\$.pinned')=1)",
        );
    }
    final order = switch (sort) {
      'name' => 'f.title COLLATE NOCASE,f.id',
      'domain' => "COALESCE(json_extract(f.data,'\$.domain'),json_extract(f.data,'\$.normalizedUrl'),json_extract(f.data,'\$.action.target')) COLLATE NOCASE,f.title,f.id",
      'added' => 'f.created_at DESC,f.id',
      'visited' =>
        "COALESCE(json_extract(f.data,'\$.lastVisitedAt'),'') DESC,f.id",
      _ => "COALESCE(json_extract(f.data,'\$.pinned'),0) DESC,COALESCE(json_extract(f.data,'\$.order'),0),f.created_at,f.id",
    };
    return (where: clauses.join(' AND '), variables: variables, order: order);
  }

  Future<WebPageResult> search(
    String text, {
    String categoryId = '',
    String view = 'all',
    String sort = 'manual',
    int offset = 0,
    int limit = 60,
    bool includeHidden = false,
  }) async {
    if (offset < 0 || offset > 10000 || limit < 1 || limit > 200) {
      throw const ToolFailure('网站分页范围无效。');
    }
    final q = _query(text, categoryId, view, sort, includeHidden);
    final rows = await store.db
        .customSelect(
          'SELECT f.*,COUNT(*) OVER() AS total_count $_from WHERE ${q.where} ORDER BY ${q.order} LIMIT ? OFFSET ?',
          variables: [...q.variables, Variable(limit), Variable(offset)],
          readsFrom: {store.db.localRecords},
        )
        .get();
    var total = rows.isEmpty ? 0 : rows.first.read<int>('total_count');
    if (rows.isEmpty && offset > 0) {
      final count = await store.db
          .customSelect(
            'SELECT COUNT(*) AS n $_from WHERE ${q.where}',
            variables: q.variables,
            readsFrom: {store.db.localRecords},
          )
          .getSingle();
      total = count.read<int>('n');
    }
    return WebPageResult(
      rows
          .map(
            (r) => WebsiteBookmark(
              ToolRecord.fromRow(store.db.localRecords.map(r.data)),
            ),
          )
          .toList(),
      total,
      offset,
      limit,
    );
  }
}
