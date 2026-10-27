import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/modules/module_registry.dart';
import '../../core/platform/system_actions.dart';

class SearchResult {
  const SearchResult({
    required this.id,
    required this.sourceModule,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.action,
    required this.score,
  });
  final String id, sourceModule, title, subtitle;
  final IconData icon;
  final TargetAction action;
  final double score;
}

abstract interface class SearchProvider {
  String get source;
  Future<List<SearchResult>> search(String query, {int limit = 200});
}

class ModuleSearchProvider implements SearchProvider {
  ModuleSearchProvider(this.isEnabled);
  final bool Function(ModuleDefinition) isEnabled;
  @override
  String get source => 'modules';
  @override
  Future<List<SearchResult>> search(String query, {int limit = 200}) async => [
    for (final m in modules)
      if (isEnabled(m) &&
          ('${m.displayName} ${m.description} ${_names[m.moduleId]}'
              .toLowerCase()
              .contains(query.toLowerCase())))
        SearchResult(
          id: 'module:${m.moduleId}',
          sourceModule: m.moduleId,
          title: m.displayName,
          subtitle: _names[m.moduleId] ?? m.description,
          icon: m.icon,
          action: TargetAction('module', m.moduleId),
          score: 100,
        ),
  ];
}

const _names = {
  'hub': '首页 工作台 搜索',
  'clipboard': '剪贴板 文本片段',
  'archive': '文件管理 归档',
  'memory': '记忆仓库 笔记',
  'ai_desk': 'AI控制台 模型 聊天',
  'server': '服务器 SSH 网站',
  'converter': '格式转换 图片 音频 视频 文档',
  'renamer': '批量重命名 文件编号 前缀 后缀 撤销',
  'image_studio': '图片处理 压缩 裁剪 水印 旋转',
  'bookmarks': '收藏 书签 GitHub 教程 视频',
  'timeline': '待办 时间轴 个人任务 截止日期',
  'transcribe': '本地语音 录音 转文字 转写 字幕 whisper AMR MP3',
  'media_library': '视频 素材 媒体 封面 时长 分辨率',
  'software_library': '软件 安装包 版本 EXE MSI ZIP 签名 校验',
  'environment_snapshot': 'Windows 环境 备份 快照 开发工具 版本 清单',
  'collection_cards': '收藏卡 球星卡 动漫卡 物料卡 C罗 编数 照片 成本 估值 出售',
  'finance': '记账 消费 账单 微信 支付宝 收入 支出 退款 转账 预算 CSV XLSX',
  'lan_transfer': '局域网 互传 LocalSend 文件 清单 接收 哈希 校验',
  'game_saves': '游戏 存档 Minecraft 备份 ZIP 版本 哈希 恢复',
  'home_dashboard': '家庭 设备 NAS 路由器 电视 TCP Ping 检查',
};

class LocalSearchProvider implements SearchProvider {
  LocalSearchProvider(this.store, {this.isEnabled});
  final RecordStore store;
  final bool Function(String)? isEnabled;
  @override
  String get source => 'local';
  static const mapping = {
    'dev_snippet': 'snippets',
    'favorite': 'hub',
    'clipboard': 'clipboard',
    'note': 'memory',
    'memory_prompt': 'memory',
    'project': 'memory',
    'archive_file': 'archive',
    'prompt': 'clipboard',
    'server': 'server',
    'ai_provider': 'ai_desk',
    'transcript': 'transcribe',
  };
  @override
  Future<List<SearchResult>> search(String query, {int limit = 200}) async => [
    for (final r in await store.search(
      query,
      kinds: mapping.keys.toList(),
      limit: limit,
    ))
      if (isEnabled?.call(mapping[r.kind]!) ?? true)
        SearchResult(
          id: r.id,
          sourceModule: mapping[r.kind]!,
          title: r.title.isEmpty ? '未命名' : r.title,
          subtitle: r.body.length > 120
              ? '${r.body.substring(0, 120)}…'
              : r.body,
          icon: moduleById(mapping[r.kind]!)!.icon,
          action: r.kind == 'favorite'
              ? TargetAction.fromJson(
                  Map<String, dynamic>.from(r.data['action'] as Map),
                )
              : TargetAction('record', r.id, moduleId: mapping[r.kind]!),
          score: r.title.toLowerCase().contains(query.toLowerCase()) ? 90 : 60,
        ),
  ];
}

class SearchPageResult {
  const SearchPageResult(this.results, this.nextCursor);
  final List<SearchResult> results;
  final String? nextCursor;
}

class SearchService {
  SearchService(this.providers);
  final List<SearchProvider> providers;
  Future<SearchPageResult> search(
    String query, {
    Set<String> sourceFilters = const {},
    int limit = 40,
    String? cursor,
  }) async {
    query = query.trim();
    if (query.isEmpty) return const SearchPageResult([], null);
    final scope = '$query|${(sourceFilters.toList()..sort()).join(',')}';
    var offset = 0;
    if (cursor != null) {
      try {
        final data = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        ) as Map;
        if (data['scope'] != scope) throw const FormatException();
        offset = data['offset'] as int;
        if (offset < 0 || offset > 1000) throw const FormatException();
      } catch (_) {
        throw const ToolFailure('搜索游标失效，请重新搜索。');
      }
    }
    final batches = await Future.wait(
      providers.map((p) => p.search(query, limit: 1000)),
    );
    final results =
        batches
            .expand((b) => b)
            .where(
              (r) =>
                  sourceFilters.isEmpty ||
                  sourceFilters.contains(r.sourceModule),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    final page = results.skip(offset).take(limit.clamp(1, 100)).toList();
    final next = offset + page.length < results.length
        ? base64Url.encode(
            utf8.encode(
              jsonEncode({'scope': scope, 'offset': offset + page.length}),
            ),
          )
        : null;
    return SearchPageResult(page, next);
  }
}
