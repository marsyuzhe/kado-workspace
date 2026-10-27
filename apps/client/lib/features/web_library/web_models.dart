import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/data/tool_record.dart';
import '../../core/platform/system_actions.dart';

const webNamespace = '8d02d6c2-7697-55c3-bd59-3fdbe277ea83';

/// RFC4122 UUIDv5；种子和旧分类用同一命名空间，跨设备不重复创建。
String stableWebId(String scope, String value) {
  final hex = webNamespace.replaceAll('-', '');
  final bytes = [
    for (var i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  final hash = sha1
      .convert([...bytes, ...utf8.encode('$scope:$value')])
      .bytes
      .take(16)
      .toList();
  hash[6] = (hash[6] & 15) | 80;
  hash[8] = (hash[8] & 63) | 128;
  final h = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

final uncategorizedId = stableWebId('category', 'uncategorized');
const webIconKeys = {
  'globe',
  'spark',
  'code',
  'book',
  'cloud',
  'forum',
  'model',
  'design',
  'media',
  'workflow',
  'game',
  'school',
  'shopping',
  'work',
  'star',
  'folder',
};

/// 只补协议并规范域名/默认端口，查询参数、路径大小写和fragment全部保留。
String normalizeWebsiteUrl(String value) {
  var text = value.trim();
  if (text.length > 4096 || text.contains(RegExp(r'[\x00-\x20\x7f]'))) {
    throw const ToolFailure('网址为空、过长或包含空白/控制字符。');
  }
  if (text.startsWith('//')) text = 'https:$text';
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(text) ||
      RegExp(r'^[^/:?#]+:\d+(?:[/?#]|$)').hasMatch(text)) {
    text = 'https://$text';
  }
  try {
    final uri = Uri.parse(text);
    TargetAction('url', uri.toString()).validate();
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)
          ? uri.port
          : null,
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  } on FormatException {
    throw const ToolFailure('网址格式无效。');
  }
}

/// 分类复用LocalRecords的UUID/revision/deviceId/软删除与同步元数据。
class WebsiteCategory {
  const WebsiteCategory(this.record);
  final ToolRecord record;
  String get id => record.id;
  String get name => record.title;
  String get description => record.body;
  String get parentId => record.text('parentId');
  String get iconKey => record.text('iconKey', 'folder');
  String get color => record.text('color', '#8196BE');
  int get sortOrder => record.number('sortOrder');
  bool get isSystemPreset => record.flag('isSystemPreset');
  bool get isHidden => record.flag('isHidden');
}

class WebsiteCategoryInput {
  const WebsiteCategoryInput(
    this.name, {
    this.description = '',
    this.iconKey = 'folder',
    this.parentId = '',
    this.color = '#8196BE',
    this.sortOrder = 0,
    this.isHidden = false,
  });
  final String name, description, iconKey, parentId, color;
  final int sortOrder;
  final bool isHidden;
  void validate() {
    if (name.trim().isEmpty ||
        name.length > 300 ||
        description.length > 1000 ||
        !webIconKeys.contains(iconKey) ||
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color) ||
        sortOrder < 0 ||
        sortOrder > 1000000) {
      throw const ToolFailure('分类名称必填（最多300字），图标、颜色或顺序无效。');
    }
  }
}

/// 网址仍是Hub的favorite记录，不创建第二套收藏实体。
class WebsiteBookmark {
  const WebsiteBookmark(this.record);
  final ToolRecord record;
  String get id => record.id;
  String get title => record.title;
  String get description => record.body;
  String get url => (record.data['action'] as Map?)?['target'] as String? ?? '';
  String get categoryId => record.text('categoryId').isEmpty
      ? uncategorizedId
      : record.text('categoryId');
  List<String> get tags => record.strings('tags');
  bool get isFavorite => record.flag('favorite');
  bool get isPinned => record.flag('pinned');
  int get sortOrder => record.number('order');
  int get visitCount => record.number('visitCount');
  DateTime? get lastVisitedAt =>
      DateTime.tryParse(record.text('lastVisitedAt'));
  bool get isSeeded => record.flag('isSeeded');
  String get sourceType => record.text('sourceType', 'USER_CONFIRMED');
  String get customIconPath => record.text('customIconPath');
  String get faviconUrl => record.text('faviconUrl');
}

class WebsiteInput {
  const WebsiteInput(
    this.title,
    this.url, {
    this.description = '',
    this.categoryId = '',
    this.tags = const [],
    this.isFavorite = false,
    this.isPinned = false,
    this.alternateUrl = '',
  });
  final String title, url, description, categoryId, alternateUrl;
  final List<String> tags;
  final bool isFavorite, isPinned;
  String validate() {
    if (title.trim().isEmpty ||
        title.length > 300 ||
        description.length > 4000 ||
        tags.length > 30 ||
        tags.any((t) => t.length > 80)) {
      throw const ToolFailure('网站名称必填，名称/描述/标签超出限制。');
    }
    if (alternateUrl.trim().isNotEmpty) normalizeWebsiteUrl(alternateUrl);
    return normalizeWebsiteUrl(url);
  }
}

/// 旧Hub字段与网站字段使用同一编码，避免导入和手动保存产生两套结构。
Map<String, dynamic> websiteRecordData(
  WebsiteInput input,
  String url, {
  required String categoryName,
  required int order,
  Map<String, dynamic> extra = const {},
}) => {
  'payloadVersion': 2,
  'webDataVersion': 1,
  'action': TargetAction('url', url).toJson(),
  'targetKey': TargetAction('url', url).key,
  'normalizedUrl': url,
  'domain': Uri.parse(url).host,
  'categoryId': input.categoryId.isEmpty ? uncategorizedId : input.categoryId,
  'category': categoryName,
  'tags': input.tags
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList(),
  'favorite': input.isFavorite,
  'pinned': input.isPinned,
  'order': order,
  'alternateUrl': input.alternateUrl.isEmpty
      ? ''
      : normalizeWebsiteUrl(input.alternateUrl),
  'source': 'manual',
  'sourceType': 'USER_CONFIRMED',
  'isSeeded': false,
  'visitCount': 0,
  'lastVisitedAt': '',
  'customIconPath': '',
  'faviconUrl': '',
  'syncAllowed': false,
  ...extra,
};
