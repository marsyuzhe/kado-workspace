import 'package:flutter/material.dart';

import 'module_registry.dart';

/// Visibility describes product placement, not resource installation or deletion.
enum ModuleVisibility { core, optional, legacy, disabled }

const legacyModuleIds = {
  'lan_transfer',
  'home_dashboard',
  'game_saves',
  'finance',
  'collection_cards',
  'software_library',
};

ModuleVisibility moduleVisibility(String id, {bool enabled = true}) =>
    coreModuleIds.contains(id)
    ? ModuleVisibility.core
    : !enabled
    ? ModuleVisibility.disabled
    : legacyModuleIds.contains(id)
    ? ModuleVisibility.legacy
    : ModuleVisibility.optional;

class WorkspaceDestination {
  const WorkspaceDestination(
    this.id,
    this.label,
    this.icon,
    this.moduleId, {
    this.view,
  });
  final String id, label, moduleId;
  final IconData icon;
  final String? view;
  String get route => Uri(
    path: '/modules/$moduleId',
    queryParameters: view == null ? null : {'view': view!},
  ).toString();
  bool matches(Uri uri) =>
      uri.path == '/modules/$moduleId' &&
      (view == null
          ? (!{'studio', 'clipboard'}.contains(moduleId) ||
                !uri.queryParameters.containsKey('view'))
          : uri.queryParameters['view'] == view);
}

class WorkspaceSection {
  const WorkspaceSection(this.id, this.label, this.icon, this.items);
  final String id, label;
  final IconData icon;
  final List<WorkspaceDestination> items;
}

/// Only real, registered modules are rendered. Stable route IDs remain intact.
const workspaceSections = [
  WorkspaceSection('ai', 'AI 与 Agent', Icons.auto_awesome_outlined, [
    WorkspaceDestination('studio', '像素办公室', Icons.apartment_outlined, 'studio'),
    WorkspaceDestination(
      'ai_desk',
      'AI 控制台',
      Icons.chat_bubble_outline,
      'ai_desk',
    ),
    WorkspaceDestination(
      'tasks',
      '任务中心',
      Icons.task_alt,
      'studio',
      view: 'tasks',
    ),
    WorkspaceDestination(
      'prompts',
      '提示词管理',
      Icons.text_snippet_outlined,
      'clipboard',
      view: 'prompts',
    ),
  ]),
  WorkspaceSection('dev', '开发工具', Icons.code, [
    WorkspaceDestination(
      'dependency_inspector',
      '依赖检查',
      Icons.schema_outlined,
      'dependency_inspector',
    ),
    WorkspaceDestination('api_studio', 'API Studio', Icons.api, 'api_studio'),
    WorkspaceDestination(
      'data_formatter',
      'JSON / YAML',
      Icons.data_object,
      'data_formatter',
    ),
    WorkspaceDestination(
      'regex_lab',
      'Regex Lab',
      Icons.manage_search,
      'regex_lab',
    ),
    WorkspaceDestination(
      'snippets',
      '代码片段',
      Icons.integration_instructions_outlined,
      'snippets',
    ),
    WorkspaceDestination(
      'hash_inspector',
      '哈希校验',
      Icons.fingerprint,
      'hash_inspector',
    ),
  ]),
  WorkspaceSection('files', '文件与媒体', Icons.folder_outlined, [
    WorkspaceDestination(
      'archive',
      '文件管理',
      Icons.inventory_2_outlined,
      'archive',
    ),
    WorkspaceDestination('converter', '格式转换', Icons.transform, 'converter'),
    WorkspaceDestination(
      'renamer',
      '批量重命名',
      Icons.drive_file_rename_outline,
      'renamer',
    ),
    WorkspaceDestination(
      'image_studio',
      '图片处理',
      Icons.image_outlined,
      'image_studio',
    ),
    WorkspaceDestination(
      'transcribe',
      '语音转文字',
      Icons.transcribe_outlined,
      'transcribe',
    ),
    WorkspaceDestination(
      'media_library',
      '视频素材',
      Icons.video_library_outlined,
      'media_library',
    ),
    WorkspaceDestination('clipboard', '剪贴板', Icons.content_paste, 'clipboard'),
    WorkspaceDestination(
      'utility_jobs',
      '文件任务',
      Icons.pending_actions,
      'utility_jobs',
    ),
  ]),
  WorkspaceSection('system', '系统与网络', Icons.dns_outlined, [
    WorkspaceDestination(
      'environment_diff',
      '环境差异',
      Icons.difference_outlined,
      'environment_diff',
    ),
    WorkspaceDestination('workflow', '本地工作流', Icons.linear_scale, 'workflow'),
    WorkspaceDestination('server', '服务器与 Docker', Icons.dns_outlined, 'server'),
    WorkspaceDestination(
      'network_inspector',
      '端口诊断',
      Icons.lan_outlined,
      'network_inspector',
    ),
    WorkspaceDestination(
      'environment_snapshot',
      '环境快照',
      Icons.fact_check_outlined,
      'environment_snapshot',
    ),
    WorkspaceDestination(
      'log_viewer',
      '日志分析',
      Icons.article_outlined,
      'log_viewer',
    ),
  ]),
  WorkspaceSection('knowledge', '知识与项目', Icons.book_outlined, [
    WorkspaceDestination(
      'github_projects',
      'GitHub 项目',
      Icons.account_tree_outlined,
      'github_projects',
    ),
    WorkspaceDestination('memory', '知识与项目', Icons.book_outlined, 'memory'),
    WorkspaceDestination('timeline', '待办时间轴', Icons.checklist, 'timeline'),
  ]),
];

bool isRegisteredDestination(WorkspaceDestination item) =>
    moduleById(item.moduleId) != null &&
    implementedModules.contains(item.moduleId);
