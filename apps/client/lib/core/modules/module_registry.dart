import 'package:flutter/material.dart';

import '../../app/brand_config.dart';

import '../platform/capability_service.dart';

enum AppPlatform { windows, android, ios }

/// Primary destinations stay available even when an older preference disabled them.
const coreModuleIds = {'hub', 'bookmarks'};

const implementedModules = {
  'github_projects',
  'dependency_inspector',
  'environment_diff',
  'workflow',
  'snippets',
  'network_inspector',
  'log_viewer',
  'api_studio',
  'data_formatter',
  'regex_lab',
  'hash_inspector',
  'hub',
  'clipboard',
  'archive',
  'memory',
  'ai_desk',
  'server',
  'studio',
  'utilities',
  'converter',
  'renamer',
  'image_studio',
  'bookmarks',
  'timeline',
  'utility_jobs',
  'transcribe',
  'media_library',
  'software_library',
  'environment_snapshot',
  'home_dashboard',
  'game_saves',
  'finance',
  'collection_cards',
  'lan_transfer',
};

class ModuleDefinition {
  const ModuleDefinition({
    required this.moduleId,
    required this._displayName,
    required this.icon,
    required this.description,
    required this.phase,
    this.version = '1.0.0',
    this.enabled = true,
    this.supportedPlatforms = const {
      AppPlatform.windows,
      AppPlatform.android,
      AppPlatform.ios,
    },
    this.requiredCapabilities = const {},
    this.searchProvider,
    this.settingsEntry,
    this.syncCollections = const [],
  });

  final String moduleId;
  final String _displayName;
  String get displayName =>
      AppBrandConfig.moduleNames[moduleId] ?? _displayName;
  final IconData icon;
  final String description;
  final int phase;
  final String version;
  final bool enabled;
  final Set<AppPlatform> supportedPlatforms;
  final Set<Capability> requiredCapabilities;
  // Future extension references, never dynamically loaded third-party code.
  final String? searchProvider;
  final String? settingsEntry;
  final List<String> syncCollections;
  String get route => '/modules/$moduleId';
}

const modules = <ModuleDefinition>[
  ModuleDefinition(
    moduleId: 'github_projects',
    displayName: 'GitHub Projects',
    icon: Icons.account_tree_outlined,
    description: '公开仓库收藏、Issue入口、Release记录和本地项目。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'dependency_inspector',
    displayName: 'Dependency Inspector',
    icon: Icons.schema_outlined,
    description: '静态读取四种项目依赖配置，不执行安装脚本。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'environment_diff',
    displayName: 'Environment Diff',
    icon: Icons.difference_outlined,
    description: '对比环境快照、软件版本与变量名称。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'workflow',
    displayName: 'Local Workflow',
    icon: Icons.linear_scale,
    description: '表单式文件处理、哈希校验和新文件导出。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'snippets',
    displayName: 'Snippet Library',
    icon: Icons.integration_instructions_outlined,
    description: '代码片段、分类标签、搜索收藏与复制。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'network_inspector',
    displayName: 'Network Inspector',
    icon: Icons.lan_outlined,
    description: '明确目标的DNS、TCP、HTTP与TLS证书诊断。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'log_viewer',
    displayName: 'Log Viewer',
    icon: Icons.article_outlined,
    description: '大日志流式读取、筛选、分页和脱敏预览。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'api_studio',
    displayName: 'API Studio',
    icon: Icons.api,
    description: '主动HTTP请求、集合、环境变量与安全凭据引用。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'data_formatter',
    displayName: 'Data Formatter',
    icon: Icons.data_object,
    description: 'JSON / YAML格式化、验证与差异比较。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'regex_lab',
    displayName: 'Regex Lab',
    icon: Icons.manage_search,
    description: '有执行预算的正则匹配、分组与替换。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'hash_inspector',
    displayName: 'Hash Inspector',
    icon: Icons.fingerprint,
    description: '流式SHA-256 / SHA-512文件与批量校验。',
    phase: 24,
    version: '2.4.0',
  ),
  ModuleDefinition(
    moduleId: 'collection_cards',
    displayName: 'Links Collection',
    icon: Icons.collections_bookmark_outlined,
    description: '收藏卡结构编数、物料来源、原图与缩略图、手动成本估值和CSV导出。',
    phase: 13,
  ),
  ModuleDefinition(
    moduleId: 'finance',
    displayName: 'Links Finance',
    icon: Icons.account_balance_wallet_outlined,
    description: '主动导入CSV/XLSX、精确金额记账、退款/转账、统计预算和本地导出。',
    phase: 13,
  ),
  ModuleDefinition(
    moduleId: 'lan_transfer',
    displayName: 'Links Transfer',
    icon: Icons.devices_outlined,
    description: 'LocalSend受控外部调用、发送清单与接收后SHA256核验；真机互传待验证。',
    phase: 12,
    supportedPlatforms: {AppPlatform.windows},
  ),
  ModuleDefinition(
    moduleId: 'game_saves',
    displayName: 'Links Game Saves',
    icon: Icons.sports_esports_outlined,
    description: '游戏存档完整ZIP、逐文件SHA256核验、版本保留与新目录恢复。',
    phase: 12,
    supportedPlatforms: {AppPlatform.windows},
  ),
  ModuleDefinition(
    moduleId: 'home_dashboard',
    displayName: 'Links Home Dashboard',
    icon: Icons.home_work_outlined,
    description: '已知家庭设备入口、按需TCP/HTTP/Ping检查和状态历史，不扫描网段。',
    phase: 12,
  ),
  ModuleDefinition(
    moduleId: 'environment_snapshot',
    displayName: 'Links Environment Snapshot',
    icon: Icons.fact_check_outlined,
    description: 'Windows主动只读环境采集、配置隐私预览与四份恢复参考报告。',
    phase: 11,
    supportedPlatforms: {AppPlatform.windows},
  ),
  ModuleDefinition(
    moduleId: 'software_library',
    displayName: 'Links Software Library',
    icon: Icons.install_desktop_outlined,
    description: '安装包登记、流式SHA256、Windows属性与离线签名检查，确认后打开。',
    phase: 11,
    supportedPlatforms: {AppPlatform.windows},
  ),
  ModuleDefinition(
    moduleId: 'media_library',
    displayName: 'Links Media Library',
    icon: Icons.video_library_outlined,
    description: '视频元数据索引、封面缓存、分类评分与项目关联；Windows系统播放器预览。',
    phase: 11,
  ),
  ModuleDefinition(
    moduleId: 'transcribe',
    displayName: 'Links Transcribe',
    icon: Icons.transcribe_outlined,
    description: 'Windows本地录音转写、独立模型、分段处理与字幕修订导出；移动端可编辑已有结果。',
    phase: 11,
  ),
  ModuleDefinition(
    moduleId: 'converter',
    displayName: 'Links Converter',
    icon: Icons.transform,
    description: '图片、音视频与文本格式转换，明确显示已验证组合。',
    phase: 10,
  ),
  ModuleDefinition(
    moduleId: 'renamer',
    displayName: 'Links Renamer',
    icon: Icons.drive_file_rename_outline,
    description: '批量重命名，预览冲突、安全交换和条件撤销。',
    phase: 10,
    supportedPlatforms: {AppPlatform.windows},
  ),
  ModuleDefinition(
    moduleId: 'image_studio',
    displayName: 'Links Image Studio',
    icon: Icons.image_outlined,
    description: '裁剪、缩放、旋转、翻转、压缩和文字图片水印。',
    phase: 10,
  ),
  ModuleDefinition(
    moduleId: 'bookmarks',
    displayName: 'Links Bookmarks',
    icon: Icons.bookmarks_outlined,
    description: '网页、GitHub和视频收藏，分类、批量管理和离线导入导出。',
    phase: 10,
  ),
  ModuleDefinition(
    moduleId: 'timeline',
    displayName: 'Links Timeline',
    icon: Icons.checklist,
    description: '个人待办和截止时间；当前为应用内提示，不含系统通知。',
    phase: 10,
  ),
  ModuleDefinition(
    moduleId: 'utility_jobs',
    displayName: '工具任务',
    icon: Icons.pending_actions,
    description: '查看真实队列、处理进度、取消和中断记录。',
    phase: 10,
  ),
  ModuleDefinition(
    moduleId: 'utilities',
    displayName: '工具中心',
    icon: Icons.construction_outlined,
    description: '网页收藏、静态图片处理与转换、个人任务时间轴。',
    phase: 9,
    version: '1.5.0',
  ),
  ModuleDefinition(
    moduleId: 'studio',
    displayName: 'Links Studio',
    icon: Icons.apartment_outlined,
    description: '像素办公室、真实本地任务、执行日志和结果审核。',
    phase: 8,
    version: '1.4.0',
  ),
  ModuleDefinition(
    moduleId: 'hub',
    displayName: 'Links Hub',
    icon: Icons.grid_view_rounded,
    description: '统一入口、应用内搜索与常用工具。',
    phase: 2,
  ),
  ModuleDefinition(
    moduleId: 'archive',
    displayName: 'Links Archive',
    icon: Icons.inventory_2_outlined,
    description: '整理授权文件，先预览，再执行。',
    phase: 4,
  ),
  ModuleDefinition(
    moduleId: 'clipboard',
    displayName: 'Links Clipboard',
    icon: Icons.content_paste_rounded,
    description: '主动收集、搜索和管理文本片段。',
    phase: 3,
  ),
  ModuleDefinition(
    moduleId: 'ai_desk',
    displayName: 'Links AI Desk',
    icon: Icons.auto_awesome_outlined,
    description: '统一管理模型、提示词与个人 API。',
    phase: 6,
  ),
  ModuleDefinition(
    moduleId: 'server',
    displayName: 'Links Server',
    icon: Icons.dns_outlined,
    description: '核对SSH指纹，读取服务器与网站状态。',
    phase: 7,
  ),
  ModuleDefinition(
    moduleId: 'memory',
    displayName: 'Links Memory',
    icon: Icons.book_outlined,
    description: '记录笔记、项目决策与长期上下文。',
    phase: 5,
  ),
];

ModuleDefinition? moduleById(String id) {
  for (final module in modules) {
    if (module.moduleId == id) return module;
  }
  return null;
}
